/*
 * cache_query.c — C implementation of agent_query.py
 * 
 * AI-friendly structured query interface for KV Cache.
 * 
 * Usage:
 *   ./cache_query <query> [--repo <namespace>] [--type <type>] [--analysis-dir <dir>]
 *                           [--kind <kind>] [--lang <lang>] [--file <pattern>]
 *                           [--no-boost] [--max-results <n>]
 * 
 * Example:
 *   ./cache_query ngx_palloc --repo /code/nginx --type context
 *   ./cache_query "memory pool" --repo /code/nginx --type search --analysis-dir /opt/code_caches/nginx_cache
 *   ./cache_query "event loop" --repo /code/nginx --type search --analysis-dir /opt/code_caches/nginx_cache --kind function --lang c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <getopt.h>
#include <sys/stat.h>
#include <jansson.h>
#include "cache.h"
#include "vector_engine.h"

static cache_t* g_cache = NULL;
static vector_engine_t* g_ve = NULL;
// 进程内复用：同一项目连续 query（TUI/agent）不再反复加载 2GB KV 和数 GB HNSW。
// 反复 create/destroy ORT session 还会偶发段错误；保持 engine 常驻更稳。
// 但 import 会改写 kv/mem.bin：靠 mem.bin 的 mtime/size 变化判断陈旧，重开一次。
static char g_cache_dir[512] = {0};
static long long g_cache_mtime = 0;
static long long g_cache_size = 0;
static int g_cache_kv_ok = 0;

static int kv_stamp(const char* dir, long long* mtime, long long* size) {
    char p[1024];
    snprintf(p, sizeof(p), "%s/mem.bin", dir);
    struct stat st;
    if (stat(p, &st) != 0) return -1;
    *mtime = (long long)st.st_mtime;
    *size = (long long)st.st_size;
    return 0;
}
static char g_ve_dir[512] = {0};
static char g_ve_model[32] = {0};

static int is_identifier(const char* s) {
    if (!s || !*s) return 0;
    if (!isalpha((unsigned char)s[0]) && s[0] != '_') return 0;
    for (size_t i = 1; s[i]; i++) {
        if (!isalnum((unsigned char)s[i]) && s[i] != '_') return 0;
    }
    return 1;
}

static const char* detect_query_type(const char* query, const char* repo) {
    if (strncmp(query, "/code/", 6) == 0) return "exact";
    if (strchr(query, ' ') == NULL && is_identifier(query) && repo) return "context";
    if (strchr(query, ' ') != NULL) return "search";
    return "symbol";
}

// 查询串像文件路径（含 '/' 或带扩展名），而不是完整 KV key
static int looks_like_path(const char* q) {
    if (!q || !*q) return 0;
    if (strchr(q, '/')) return 1;
    const char* dot = strrchr(q, '.');
    return dot && dot != q && strlen(dot) <= 8;
}

// 洗成 KV key 里出现的形式：去掉 file://、"./"、首尾斜杠
static const char* clean_path(const char* path, char* buf, size_t cap) {
    const char* p = path;
    if (strncmp(p, "file://", 7) == 0) p += 7;
    while (p[0] == '.' && p[1] == '/') p += 2;
    while (*p == '/') p++;
    size_t n = strlen(p);
    while (n > 0 && p[n - 1] == '/') n--;
    if (n >= cap) n = cap - 1;
    memcpy(buf, p, n);
    buf[n] = '\0';
    return buf;
}

// 按文件列 chunk：key 形如 <repo>/chunks/<绝对路径>/<符号>。
// 路径段完整匹配（loop.lua 不命中 xloop.lua），绝对/相对路径都能吃。
static json_t* do_file(const char* path, const char* repo, int max_results);

// Exact query: 完整 key 直取；miss 且像路径时按文件展开成 chunk 列表
static json_t* do_exact(const char* query, const char* repo) {
    const char* value = cache_get(g_cache, query);
    if (!value) {
        if (repo && *repo) {
            char clean[1024];
            const char* ck = strstr(query, "/chunks/");
            if (ck) {
                // 完整 key 没命中（多半符号名写错）→ 用其中的文件路径回退
                char fp[1024];
                snprintf(fp, sizeof(fp), "%s", ck + 8);
                char* last = strrchr(fp, '/');
                if (last) *last = '\0';
                json_t* chunks = do_file(fp, repo, 50);
                if (json_array_size(chunks) > 0) return chunks;
                json_decref(chunks);
            } else if (looks_like_path(query)) {
                clean_path(query, clean, sizeof(clean));
                if (*clean) {
                    json_t* chunks = do_file(clean, repo, 100);
                    if (json_array_size(chunks) > 0) return chunks;
                    json_decref(chunks);
                }
            }
        }
        return json_array();
    }
    
    json_error_t error;
    json_t* data = json_loads(value, 0, &error);
    if (!data) return json_array();
    
    json_t* arr = json_array();
    if (json_is_array(data)) {
        json_t* obj = json_object();
        json_object_set_new(obj, "_key", json_string(query));
        json_object_set_new(obj, "_source", json_string("exact"));
        json_object_set_new(obj, "entries", data);
        json_array_append_new(arr, obj);
    } else {
        json_object_set_new(data, "_key", json_string(query));
        json_object_set_new(data, "_source", json_string("exact"));
        json_array_append_new(arr, data);
    }
    return arr;
}

// 展开一个 /symbols/<name> 键：优先取 chunk 全文，缺 chunk 退回符号条目
static void symbol_entries_into(json_t* arr, const char* repo, const char* name) {
    char key[1024];
    snprintf(key, sizeof(key), "%s/symbols/%s", repo, name);
    const char* value = cache_get(g_cache, key);
    if (!value) return;
    
    json_error_t error;
    json_t* symbols = json_loads(value, 0, &error);
    if (!symbols || !json_is_array(symbols)) {
        if (symbols) json_decref(symbols);
        return;
    }
    
    size_t idx;
    json_t* sym;
    json_array_foreach(symbols, idx, sym) {
        const char* file = json_string_value(json_object_get(sym, "file"));
        if (!file) continue;
        
        // Skip leading '/' to match trim_slash() in cache_import.c
        while (*file == '/') file++;
        
        char ckey[1024];
        snprintf(ckey, sizeof(ckey), "%s/chunks/%s/%s", repo, file, name);
        const char* cvalue = cache_get(g_cache, ckey);
        if (cvalue) {
            json_t* chunk = json_loads(cvalue, 0, &error);
            if (chunk) {
                json_object_set_new(chunk, "_source", json_string("symbol"));
                json_object_set_new(chunk, "_key", json_string(ckey));
                json_array_append_new(arr, chunk);
                continue;
            }
        }
        {
            json_t* obj = json_object();
            json_object_set(obj, "name", json_object_get(sym, "name"));
            json_object_set(obj, "kind", json_object_get(sym, "kind"));
            json_object_set(obj, "file", json_object_get(sym, "file"));
            json_object_set(obj, "line", json_object_get(sym, "line"));
            json_object_set_new(obj, "_source", json_string("symbol"));
            json_object_set_new(obj, "_key", json_string(key));
            json_array_append_new(arr, obj);
        }
    }
    
    json_decref(symbols);
}

// Symbol query：精确全名优先；miss 时按 ".name" / "::name" 后缀回退。
// Lua 的 M.foo、C++ 的 Point::norm 在 KV 里都是全名键，直查名字永远 miss。
static json_t* do_symbol(const char* name, const char* repo, int max_results) {
    json_t* arr = json_array();
    if (!g_cache || !repo || !*repo || !name || !*name) return arr;
    if (max_results <= 0) max_results = 10;

    symbol_entries_into(arr, repo, name);
    if (json_array_size(arr) > 0) return arr;

    char prefix[1024];
    snprintf(prefix, sizeof(prefix), "%s/symbols/", repo);
    size_t plen = strlen(prefix);

    char dot[600], colon[600];
    snprintf(dot, sizeof(dot), ".%s", name);
    snprintf(colon, sizeof(colon), "::%s", name);
    const char* needles[2] = { dot, colon };

    cache_search_options_t opts = cache_search_options_default();
    for (int n = 0; n < 2 && json_array_size(arr) < (size_t)max_results; n++) {
        opts.max_results = max_results - (int)json_array_size(arr);
        cache_result_t* found = NULL;
        size_t count = 0;
        if (cache_search_prefix_match(g_cache, prefix, needles[n], CACHE_MATCH_SUFFIX,
                                      &opts, &found, &count) != 0) {
            continue;
        }
        for (size_t i = 0; i < count; i++) {
            const char* k = found[i].key;
            if (!k || strlen(k) <= plen) continue;
            symbol_entries_into(arr, repo, k + plen);
        }
        cache_results_free(found);
    }
    return arr;
}

// 按文件列 chunk：key 形如 <repo>/chunks/<绝对路径>/<符号>。
// 路径段完整匹配（loop.lua 不命中 xloop.lua），绝对/相对路径都能吃。
static json_t* do_file(const char* path, const char* repo, int max_results) {
    json_t* arr = json_array();
    if (!g_cache || !repo || !*repo || !path || !*path) return arr;

    char clean[1024];
    clean_path(path, clean, sizeof(clean));
    if (!*clean) return arr;

    char prefix[1200];
    snprintf(prefix, sizeof(prefix), "%s/chunks/", repo);

    cache_search_options_t opts = cache_search_options_default();
    int want = max_results > 0 ? max_results : 10;
    // 幽灵条目（sorted 索引有、hash 表没有）和重复 key 都会被过滤掉，
    // 而 max_results 是在 cache 层就截断的，所以这里多要一些再裁剪，
    // 否则一个文件的历史副本就能把窗口占满、返回 0 条。
    int want_scan = want * 8 + 64;

    cache_result_t* found = NULL;
    size_t count = 0;
    opts.max_results = want_scan;
    if (cache_search_prefix_match(g_cache, prefix, clean, CACHE_MATCH_PATH,
                                  &opts, &found, &count) != 0) {
        return arr;
    }

    for (size_t i = 0; i < count; i++) {
        if ((int)json_array_size(arr) >= want) break;
        const char* k = found[i].key;
        const char* v = found[i].value;
        if (!k || !v) continue;
        // KV 里同一个 key 可能有多条历史记录（重复 import），这里按 key 去重，
        // 否则同一个 .on_stop 会返回 5 遍。
        int dup = 0;
        for (size_t j = 0; j < i && !dup; j++) {
            const char* kj = found[j].key;
            if (kj && strcmp(kj, k) == 0) dup = 1;
        }
        if (dup) continue;
        // 幽灵条目：sorted 索引里还留着、hash 表里已经没有（历史 import/淘汰留下的
        // 悬空 offset）。iterator 与前缀搜索都会把它们捞出来，这里按 hash 表校验。
        if (!cache_exists(g_cache, k)) continue;
        json_error_t error;
        json_t* chunk = json_loads(v, 0, &error);
        if (!chunk) continue;
        json_object_set_new(chunk, "_source", json_string("file"));
        json_object_set_new(chunk, "_key", json_string(k));
        json_array_append_new(arr, chunk);
    }
    cache_results_free(found);
    return arr;
}

// Helper: expand call paths upward (who calls X)
static void expand_call_paths(const char* name, const char* repo, int depth,
                               json_t* current_path, json_t* all_paths,
                               json_t* visited, int max_paths) {
    if (json_array_size(all_paths) >= (size_t)max_paths) return;
    
    json_array_append(current_path, json_string(name));
    
    if (depth <= 0) {
        json_array_append_new(all_paths, json_deep_copy(current_path));
        json_array_remove(current_path, json_array_size(current_path) - 1);
        return;
    }
    
    // Check cycle
    if (json_object_get(visited, name)) {
        json_array_append_new(all_paths, json_deep_copy(current_path));
        json_array_remove(current_path, json_array_size(current_path) - 1);
        return;
    }
    json_object_set_new(visited, name, json_true());
    
    char key[512];
    snprintf(key, sizeof(key), "%s/callers/%s", repo, name);
    const char* cvalue = cache_get(g_cache, key);
    int has_callers = 0;
    
    if (cvalue) {
        json_error_t error;
        json_t* data = json_loads(cvalue, 0, &error);
        if (data) {
            json_t* arr = json_object_get(data, "callers");
            if (arr && json_array_size(arr) > 0) {
                has_callers = 1;
                size_t idx;
                json_t* caller;
                json_array_foreach(arr, idx, caller) {
                    const char* caller_name = NULL;
                    if (json_is_string(caller)) {
                        caller_name = json_string_value(caller);
                    } else if (json_is_object(caller)) {
                        caller_name = json_string_value(json_object_get(caller, "name"));
                    }
                    if (caller_name) {
                        expand_call_paths(caller_name, repo, depth - 1,
                                          current_path, all_paths, visited, max_paths);
                        if (json_array_size(all_paths) >= (size_t)max_paths) break;
                    }
                }
            }
            json_decref(data);
        }
    }
    
    if (!has_callers) {
        // Leaf node (no callers, e.g., main())
        json_array_append_new(all_paths, json_deep_copy(current_path));
    }
    
    json_object_del(visited, name);
    json_array_remove(current_path, json_array_size(current_path) - 1);
}

// Context query: symbol + callers + callees + call_sites + dataflow + call_paths
static json_t* do_context(const char* name, const char* repo, int depth) {
    json_t* context = json_object();
    
    // Get symbol（后缀回退也走这里，M.foo 之类能命中）
    json_t* symbol_result = do_symbol(name, repo, 10);
    json_t* symbol = NULL;
    if (json_array_size(symbol_result) > 0) {
        symbol = json_array_get(symbol_result, 0);
        json_incref(symbol);
    }
    json_decref(symbol_result);
    
    // Get callers
    char key[512];
    snprintf(key, sizeof(key), "%s/callers/%s", repo, name);
    const char* cvalue = cache_get(g_cache, key);
    json_t* callers = json_array();
    if (cvalue) {
        json_error_t error;
        json_t* data = json_loads(cvalue, 0, &error);
        if (data) {
            json_t* arr = json_object_get(data, "callers");
            if (arr) {
                json_decref(callers);
                callers = json_incref(arr);
            }
            json_decref(data);
        }
    }
    
    // Get callees
    snprintf(key, sizeof(key), "%s/callees/%s", repo, name);
    cvalue = cache_get(g_cache, key);
    json_t* callees = json_array();
    if (cvalue) {
        json_error_t error;
        json_t* data = json_loads(cvalue, 0, &error);
        if (data) {
            json_t* arr = json_object_get(data, "callees");
            if (arr) {
                json_decref(callees);
                callees = json_incref(arr);
            }
            json_decref(data);
        }
    }
    
    // Get dataflow
    snprintf(key, sizeof(key), "%s/dataflow/vars/%s", repo, name);
    cvalue = cache_get(g_cache, key);
    json_t* dataflow = json_array();
    if (cvalue) {
        json_error_t error;
        json_t* data = json_loads(cvalue, 0, &error);
        if (data) {
            json_t* obj = json_object();
            json_object_set_new(obj, "type", json_string("variable"));
            json_object_set_new(obj, "data", data);
            json_array_append_new(dataflow, obj);
        }
    }
    
    // Expand call paths upward
    json_t* call_paths = json_array();
    if (depth > 0) {
        json_t* current_path = json_array();
        json_t* visited = json_object();
        expand_call_paths(name, repo, depth, current_path, call_paths, visited, 50);
        json_decref(current_path);
        json_decref(visited);
    }
    
    // Build context
    if (symbol) json_object_set_new(context, "symbol", symbol);
    json_object_set_new(context, "callers", callers);
    json_object_set_new(context, "callees", callees);
    json_object_set_new(context, "call_paths", call_paths);
    json_object_set_new(context, "dataflow", dataflow);
    
    // Build stats
    json_t* stats = json_object();
    json_object_set_new(stats, "caller_count", json_integer(json_array_size(callers)));
    json_object_set_new(stats, "callee_count", json_integer(json_array_size(callees)));
    json_object_set_new(stats, "call_path_count", json_integer(json_array_size(call_paths)));
    json_object_set_new(stats, "dataflow_entries", json_integer(json_array_size(dataflow)));
    
    // Build result
    json_t* result = json_object();
    json_object_set_new(result, "results", json_array());
    if (symbol) {
        json_t* arr = json_object_get(result, "results");
        json_array_append(arr, symbol);
    }
    json_object_set_new(result, "context", context);
    json_object_set_new(result, "stats", stats);
    
    return result;
}

// dataflow.json 里混进少量非标识符的"字段名"（分析器把缩进/转义吃进了名字，
// 内核索引里 24/71450，例如 "ntt"、"75nt"）。展示时直接滤掉，别让它们进结果。
static int cs_is_ident(const char* s) {
    if (!s || !*s) return 0;
    if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || *s == '_')) return 0;
    for (const char* p = s + 1; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '_')) return 0;
    }
    return 1;
}

// `dataflow/fields/<field>`：跨结构体聚合的字段访问（import 写）。
// dataflow.json 里字段访问挂在父结构体下（fields: {name: [occ...]}），字段名
// 作为变量只有 0 条 occurrence —— 单独一条键才能让 `dataflow i_pages` 有结果。
static json_t* dataflow_field_entry(const char* repo, const char* field, int max_results) {
    char key[1024];
    json_error_t error;
    snprintf(key, sizeof(key), "%s/dataflow/fields/%s", repo, field);
    const char* value = cache_get(g_cache, key);
    if (!value) return NULL;
    json_t* data = json_loads(value, 0, &error);
    if (!data) return NULL;

    json_t* entry = json_object();
    json_object_set_new(entry, "kind", json_string("field"));
    json_object_set_new(entry, "field", json_string(field));
    json_t* cnt = json_object_get(data, "count");
    if (cnt) json_object_set_new(entry, "occurrence_count", json_incref(cnt));
    json_t* scount = json_object_get(data, "struct_count");
    if (scount) json_object_set_new(entry, "struct_count", json_incref(scount));
    json_t* structs = json_object_get(data, "structs");
    if (structs && json_is_array(structs)) {
        json_t* clean = json_array();
        size_t si;
        json_t* s;
        json_array_foreach(structs, si, s) {
            const char* sn = json_string_value(s);
            if (cs_is_ident(sn)) json_array_append(clean, s);
        }
        json_object_set_new(entry, "structs", clean);
    } else if (structs) {
        json_object_set_new(entry, "structs", json_incref(structs));
    }

    json_t* funcs = json_object_get(data, "funcs");
    json_t* arr = json_array();
    int total = 0;
    if (funcs && json_is_array(funcs)) {
        total = (int)json_array_size(funcs);
        size_t i;
        json_t* f;
        json_array_foreach(funcs, i, f) {
            if (json_array_size(arr) >= (size_t)max_results) break;
            json_array_append(arr, f);
        }
    }
    json_object_set_new(entry, "func_count", json_integer(total));
    json_object_set_new(entry, "funcs", arr);
    json_decref(data);
    return entry;
}

// Dataflow query: 一个函数碰了哪些变量、一个变量流过哪些函数。
// 走 import 写好的 `dataflow/funcs/<func>`（每函数一条，cache_get O(1)）和
// `dataflow/vars/<var>`；都 miss 时用前缀搜索给候选函数名，不去读 _func_index
// 那个整块大 JSON（内核索引能到几百 MB）。
static json_t* do_dataflow(const char* query, const char* repo, int max_results) {
    json_t* results = json_array();
    if (!query || !*query || !repo || !*repo) return results;
    if (max_results <= 0) max_results = 10;

    char key[1024];
    json_error_t error;

    // 1) 函数精确命中：列出它读写的变量，每个变量补前 N 条 occurrence
    snprintf(key, sizeof(key), "%s/dataflow/funcs/%s", repo, query);
    const char* value = cache_get(g_cache, key);
    if (value) {
        json_t* data = json_loads(value, 0, &error);
        if (data) {
            json_t* vars = json_object_get(data, "vars");
            json_t* entry = json_object();
            json_object_set_new(entry, "kind", json_string("function"));
            json_object_set_new(entry, "func", json_string(query));
            json_object_set_new(entry, "var_count",
                                json_integer(vars ? (json_int_t)json_array_size(vars) : 0));
            json_t* out_vars = json_array();
            if (vars) {
                size_t idx;
                json_t* v;
                json_array_foreach(vars, idx, v) {
                    if (json_array_size(out_vars) >= (size_t)max_results) break;
                    const char* var = json_string_value(json_object_get(v, "var"));
                    json_t* item = json_object();
                    if (var) json_object_set_new(item, "var", json_string(var));
                    json_t* line = json_object_get(v, "line");
                    if (line) json_object_set_new(item, "line", json_incref(line));

                    // 变量的流向：occurrences 里只留本函数的那几条，其余给计数
                    if (var) {
                        char vkey[1024];
                        snprintf(vkey, sizeof(vkey), "%s/dataflow/vars/%s", repo, var);
                        const char* vvalue = cache_get(g_cache, vkey);
                        json_t* vdata = vvalue ? json_loads(vvalue, 0, &error) : NULL;
                        if (vdata) {
                            json_t* occ = json_object_get(vdata, "occurrences");
                            json_t* hits = json_array();
                            size_t oi;
                            json_t* o;
                            int same_func = 0;
                            if (occ) json_array_foreach(occ, oi, o) {
                                const char* f = json_string_value(json_object_get(o, "func"));
                                if (!f || strcmp(f, query) != 0) continue;
                                same_func++;
                                if (json_array_size(hits) >= 12) continue;
                                json_array_append(hits, o);
                            }
                            json_object_set_new(item, "occurrences", hits);
                            json_object_set_new(item, "occurrences_in_func",
                                                json_integer(same_func));
                            json_decref(vdata);
                        }
                    }
                    json_array_append_new(out_vars, item);
                }
            }
            json_object_set_new(entry, "vars", out_vars);
            json_array_append_new(results, entry);
            json_decref(data);
        }
        return results;
    }

    // 2) 变量命中：这个变量在哪些函数里出现（按函数聚合，取前 max_results 个）
    snprintf(key, sizeof(key), "%s/dataflow/vars/%s", repo, query);
    value = cache_get(g_cache, key);
    if (value) {
        json_t* data = json_loads(value, 0, &error);
        if (data) {
            json_t* occ = json_object_get(data, "occurrences");
            size_t occ_n = occ ? json_array_size(occ) : 0;
            // 字段名作为变量时 occurrences 常常是 0（访问记在父结构体的 fields
            // 下），这时落到 dataflow/fields/<name> 拿真实访问点。
            if (occ_n == 0) {
                json_t* field_hit = dataflow_field_entry(repo, query, max_results);
                if (field_hit) {
                    json_array_append_new(results, field_hit);
                    json_decref(data);
                    return results;
                }
            }
            json_t* entry = json_object();
            json_object_set_new(entry, "kind", json_string("variable"));
            json_object_set_new(entry, "var", json_string(query));
            json_object_set_new(entry, "occurrence_count", json_integer((json_int_t)occ_n));
            json_t* vtype = json_object_get(data, "type");
            if (vtype) json_object_set_new(entry, "type", json_incref(vtype));
            json_t* vfields = json_object_get(data, "fields");
            if (vfields && json_is_object(vfields) && json_object_size(vfields) > 0) {
                // 字段清单按访问次数降序给前 24 个，方便顺着结构体往下钻
                size_t fsz = json_object_size(vfields);
                const char** fnames = malloc(sizeof(char*) * fsz);
                json_int_t* fcnts = malloc(sizeof(json_int_t) * fsz);
                size_t fn_n = 0;
                if (fnames && fcnts) {
                    const char* fk;
                    json_t* fv;
                    json_object_foreach(vfields, fk, fv) {
                        if (!cs_is_ident(fk)) continue;  // 丢掉缩进吃进名字的脏键
                        fnames[fn_n] = fk;
                        fcnts[fn_n] = json_is_integer(fv) ? json_integer_value(fv) : 0;
                        fn_n++;
                    }
                    size_t cap = fn_n < 24 ? fn_n : 24;
                    for (size_t i = 0; i < cap; i++) {  // 选择前 cap 个，n 很小
                        size_t best = i;
                        for (size_t j = i + 1; j < fn_n; j++)
                            if (fcnts[j] > fcnts[best]) best = j;
                        if (best != i) {
                            json_int_t tc = fcnts[i]; fcnts[i] = fcnts[best]; fcnts[best] = tc;
                            const char* tn = fnames[i]; fnames[i] = fnames[best]; fnames[best] = tn;
                        }
                    }
                    json_t* top = json_array();
                    for (size_t i = 0; i < cap; i++) {
                        json_t* item = json_object();
                        json_object_set_new(item, "field", json_string(fnames[i]));
                        json_object_set_new(item, "count", json_integer(fcnts[i]));
                        json_array_append_new(top, item);
                    }
                    json_object_set_new(entry, "fields", top);
                }
                free(fnames);
                free(fcnts);
                json_object_set_new(entry, "field_count", json_integer((json_int_t)fsz));
            }
            json_t* funcs = json_object();
            json_t* order = json_array();
            if (occ) {
                size_t oi;
                json_t* o;
                json_array_foreach(occ, oi, o) {
                    const char* f = json_string_value(json_object_get(o, "func"));
                    if (!f || !*f) f = "unknown";
                    json_t* agg = json_object_get(funcs, f);
                    if (!agg) {
                        if (json_object_size(funcs) >= (size_t)max_results) continue;
                        agg = json_object();
                        json_object_set_new(agg, "func", json_string(f));
                        json_object_set_new(agg, "count", json_integer(0));
                        json_object_set_new(agg, "lines", json_array());
                        json_object_set_new(funcs, f, agg);
                        json_array_append_new(order, json_string(f));
                    }
                    json_object_set_new(agg, "count",
                        json_integer(json_integer_value(json_object_get(agg, "count")) + 1));
                    json_t* lines = json_object_get(agg, "lines");
                    if (lines && json_array_size(lines) < 8) {
                        json_t* l = json_object_get(o, "line");
                        if (l) json_array_append(lines, l);
                    }
                }
            }
            json_t* arr = json_array();
            size_t fi;
            json_t* fname;
            json_array_foreach(order, fi, fname) {
                json_t* agg = json_object_get(funcs, json_string_value(fname));
                if (agg) json_array_append(arr, agg);
            }
            json_object_set_new(entry, "funcs", arr);
            json_array_append_new(results, entry);
            json_decref(order);
            json_decref(funcs);
            json_decref(data);
        }
        return results;
    }

    // 2b) 结构体字段：`i_pages` 这类字段名不是独立变量，走聚合键
    json_t* field_hit = dataflow_field_entry(repo, query, max_results);
    if (field_hit) {
        json_array_append_new(results, field_hit);
        return results;
    }

    // 3) 都没命中：给候选函数名 / 字段名（前缀搜索，不扫大 JSON）
    const char* prefixes[2] = {"funcs", "fields"};
    const char* labels[2] = {"functions", "fields"};
    for (int pi = 0; pi < 2; pi++) {
        char prefix[1024];
        snprintf(prefix, sizeof(prefix), "%s/dataflow/%s/%s", repo, prefixes[pi], query);
        cache_search_options_t opts = cache_search_options_default();
        opts.max_results = max_results;
        cache_result_t* found = NULL;
        size_t count = 0;
        if (cache_search_prefix(g_cache, prefix, &opts, &found, &count) != 0 || !found) continue;
        json_t* cands = json_array();
        size_t plen = strlen(prefix);
        for (size_t i = 0; i < count && json_array_size(cands) < (size_t)max_results; i++) {
            const char* k = found[i].key;
            if (!k || strlen(k) <= plen) continue;
            json_array_append_new(cands, json_string(k + plen));
        }
        if (json_array_size(cands) > 0) {
            // 只带一部分字段名时提示往哪钻：funcs 的候选就是函数名本身
            json_t* entry = json_object();
            json_object_set_new(entry, "kind", json_string("candidates"));
            json_object_set_new(entry, "query", json_string(query));
            json_object_set_new(entry, labels[pi], cands);
            json_object_set_new(entry, "hint",
                json_string(pi == 0
                    ? "no exact function/variable/field; these functions share the prefix"
                    : "no exact field; these struct fields share the prefix"));
            json_array_append_new(results, entry);
        } else {
            json_decref(cands);
        }
        cache_results_free(found);
    }
    return results;
}

// Search query using vector engine (semantic search) with advanced options
static json_t* do_search(const char* query, const char* repo, 
                         const vector_search_opts_t* opts, int max_results) {
    json_t* arr = json_array();
    
    if (!g_ve) {
        // Vector engine not available - return empty results with a message
        json_t* obj = json_object();
        json_object_set_new(obj, "_note", json_string("Vector engine not initialized. Use --analysis-dir to enable semantic search."));
        json_array_append_new(arr, obj);
        return arr;
    }
    
    vector_result_t* results = malloc(max_results * sizeof(vector_result_t));
    if (!results) return arr;
    
    int n = vector_engine_search_ex(g_ve, query, max_results, repo, opts, results);
    
    for (int i = 0; i < n; i++) {
        json_t* obj = json_object();
        json_object_set_new(obj, "name", json_string(results[i].name));
        json_object_set_new(obj, "file", json_string(results[i].file));
        json_object_set_new(obj, "line_start", json_integer(results[i].line_start));
        json_object_set_new(obj, "line_end", json_integer(results[i].line_end));
        json_object_set_new(obj, "kind", json_string(results[i].kind));
        json_object_set_new(obj, "language", json_string(results[i].language));
        json_object_set_new(obj, "signature", json_string(results[i].signature));
        json_object_set_new(obj, "content", json_string(results[i].content));
        json_object_set_new(obj, "score", json_real(results[i].score));
        json_object_set_new(obj, "_source", json_string("vector"));
        json_array_append_new(arr, obj);
    }
    
    free(results);
    return arr;
}

static void print_usage(const char* prog) {
    printf("Usage: %s <query> [OPTIONS]\n", prog);
    printf("\nQuery types: auto, exact, symbol, context, search, dataflow\n");
    printf("\nOptions:\n");
    printf("  --repo <namespace>       Repository namespace (e.g., /code/nginx)\n");
    printf("  --type <type>            Query type: exact, symbol, context, search, auto\n");
    printf("  --cache-dir <dir>        KV Cache directory (default: /memory)\n");
    printf("  --analysis-dir <dir>     Analysis directory for semantic search (required for search type)\n");
    printf("  --kind <kind>            Filter by symbol kind: function, struct, macro, typedef\n");
    printf("  --lang <lang>            Filter by language: c, cpp, python, javascript, go, rust\n");
    printf("  --file <pattern>        Filter by filename pattern (substring match)\n");
    printf("  --no-boost              Disable TF-IDF keyword boost and caller count boost\n");
    printf("  --max-results <n>       Maximum number of results (default: 10)\n");
    printf("  --model <model>         Model type: jina (default) or mpnet\n");
    printf("  --depth <n>             Call chain expansion depth for context queries (default: 0)\n");
    printf("  --pretty, -p            Pretty-print JSON output\n");
    printf("  --brief, -b             Compact text output (symbol + callers/callees), agent-friendly\n");
    printf("\nExamples:\n");
    printf("  %s ngx_palloc --repo /code/nginx --type context\n", prog);
    printf("  %s ngx_palloc --repo /code/nginx --type context --depth 3\n", prog);
    printf("  %s \"memory pool\" --repo /code/nginx --type search --analysis-dir /opt/code_caches/nginx_cache\n", prog);
    printf("  %s \"event loop\" --repo /code/nginx --type search --analysis-dir /opt/code_caches/nginx_cache --kind function --lang c\n", prog);
    printf("  %s \"GPU kernel\" --repo /code/project --type search --analysis-dir /opt/code_caches/project_cache --file cuda\n", prog);
}

// 简洁文本输出（agent 友好）：只给符号 + caller/callee 名，省 context。
static void print_brief(json_t* response) {
    const char* type = json_string_value(json_object_get(response, "type"));
    json_t* results = json_object_get(response, "results");
    json_t* ctx = json_object_get(response, "context");

    if (type && strcmp(type, "exact") == 0) {
        size_t idx; json_t* r;
        json_array_foreach(results, idx, r) {
            const char* v = json_string_value(json_object_get(r, "value"));
            if (v) printf("%.4000s\n", v);
        }
        return;
    }

    json_t* sym = ctx ? json_object_get(ctx, "symbol") : NULL;
    if ((!sym || json_is_null(sym)) && results && json_array_size(results) > 0)
        sym = json_array_get(results, 0);

    if (sym && json_is_object(sym)) {
        const char* nm = json_string_value(json_object_get(sym, "name"));
        const char* file = json_string_value(json_object_get(sym, "file"));
        const char* kind = json_string_value(json_object_get(sym, "kind"));
        long ln = -1;
        json_t* line = json_object_get(sym, "line");
        if (line && json_is_integer(line)) ln = (long)json_integer_value(line);
        printf("%s  %s:%ld  kind=%s\n", nm ? nm : "?", file ? file : "?", ln, kind ? kind : "");
    }

    if (ctx) {
        json_t* callers = json_object_get(ctx, "callers");
        if (callers && json_array_size(callers)) {
            printf("callers(%zu): ", json_array_size(callers));
            for (size_t i = 0; i < json_array_size(callers); i++) {
                json_t* c = json_array_get(callers, i);
                const char* n = json_string_value(json_object_get(c, "name"));
                const char* via = json_string_value(json_object_get(c, "via"));
                printf("%s%s", i ? ", " : "", n ? n : "?");
                // 间接调用（obj->fn / obj.fn）标注：边只能按裸名解析，可能混入同名直接调用
                if (json_is_true(json_object_get(c, "indirect")))
                    printf("[via %s]", via ? via : "?");
            }
            printf("\n");
        }
        json_t* callees = json_object_get(ctx, "callees");
        if (callees && json_array_size(callees)) {
            printf("callees(%zu): ", json_array_size(callees));
            for (size_t i = 0; i < json_array_size(callees) && i < 30; i++) {
                json_t* c = json_array_get(callees, i);
                const char* n = json_string_value(json_object_get(c, "name"));
                const char* via = json_string_value(json_object_get(c, "via"));
                printf("%s%s", i ? ", " : "", n ? n : "?");
                if (json_is_true(json_object_get(c, "indirect")))
                    printf("[via %s]", via ? via : "?");
            }
            printf("\n");
        }
    }

    // 无语义符号时（如 search 结果），列出 name+file
    if ((!sym || !json_is_object(sym)) && results && json_array_size(results)) {
        size_t idx; json_t* r;
        json_array_foreach(results, idx, r) {
            const char* nm = json_string_value(json_object_get(r, "name"));
            const char* file = json_string_value(json_object_get(r, "file"));
            if (nm) printf("[%zu] %s  %s\n", idx + 1, nm, file ? file : "");
        }
    }
}

int lite_cs_query_main(int argc, char** argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }
    
    const char* query = argv[1];
    const char* repo = NULL;
    const char* type = "auto";
    const char* cache_dir = "/memory";
    const char* analysis_dir = NULL;
    const char* model_type = "jina";
    int pretty = 0;
    int brief = 0;
    int no_boost = 0;
    int max_results = 10;
    int call_depth = 0;
    
    // Search options
    vector_search_opts_t opts = {0};
    opts.use_keyword_boost = 1;
    opts.use_caller_boost = 1;
    
    // Parse arguments
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--repo") == 0 && i + 1 < argc) {
            repo = argv[++i];
        } else if (strcmp(argv[i], "--type") == 0 && i + 1 < argc) {
            type = argv[++i];
        } else if (strcmp(argv[i], "--cache-dir") == 0 && i + 1 < argc) {
            cache_dir = argv[++i];
        } else if (strcmp(argv[i], "--analysis-dir") == 0 && i + 1 < argc) {
            analysis_dir = argv[++i];
        } else if (strcmp(argv[i], "--kind") == 0 && i + 1 < argc) {
            opts.kind_filter = argv[++i];
        } else if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
            opts.lang_filter = argv[++i];
        } else if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) {
            opts.file_filter = argv[++i];
        } else if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
            model_type = argv[++i];
        } else if (strcmp(argv[i], "--max-results") == 0 && i + 1 < argc) {
            max_results = atoi(argv[++i]);
            if (max_results <= 0) max_results = 10;
            if (max_results > 100) max_results = 100;
        } else if (strcmp(argv[i], "--depth") == 0 && i + 1 < argc) {
            call_depth = atoi(argv[++i]);
            if (call_depth < 0) call_depth = 0;
            if (call_depth > 5) call_depth = 5;
        } else if (strcmp(argv[i], "--no-boost") == 0) {
            no_boost = 1;
        } else if (strcmp(argv[i], "--pretty") == 0 || strcmp(argv[i], "-p") == 0) {
            pretty = 1;
        } else if (strcmp(argv[i], "--brief") == 0 || strcmp(argv[i], "-b") == 0) {
            brief = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "[WARN] Unknown option: %s\n", argv[i]);
        }
    }
    
    // Disable boosts if requested
    if (no_boost) {
        opts.use_keyword_boost = 0;
        opts.use_caller_boost = 0;
    }
    
    // Auto-detect type（auto 时记住，用于空结果回退语义搜索）
    int auto_type = 0;
    if (strcmp(type, "auto") == 0) {
        type = detect_query_type(query, repo);
        auto_type = 1;
    }
    
    // Open cache (reuse if same project, reopen when import rewrote the KV)
    long long kv_mtime = 0, kv_size = 0;
    int kv_stamp_ok = kv_stamp(cache_dir, &kv_mtime, &kv_size);
    int kv_changed = (!kv_stamp_ok && g_cache_kv_ok) ||
                     (kv_stamp_ok && g_cache_kv_ok &&
                      (kv_mtime != g_cache_mtime || kv_size != g_cache_size));
    if (!g_cache || strcmp(g_cache_dir, cache_dir) != 0 || kv_changed) {
        if (g_cache) {
            cache_close(g_cache);
            g_cache = NULL;
            g_cache_dir[0] = '\0';
            g_cache_kv_ok = 0;
        }
        // 与 import 使用同一上限；query 若用更小的 max_memory 而 KV 已超过，
        // cache 内部淘汰/索引路径会出问题（内核索引曾因此偶发段错误）。
        unsigned long long max_gb = 8;
        const char* kv_max_env = getenv("LITE_CS_KV_MAX_GB");
        if (kv_max_env && *kv_max_env) {
            long g = atol(kv_max_env);
            if (g > 0 && g <= 64) max_gb = (unsigned long long)g;
        }
        g_cache = cache_open_ex(cache_dir, (size_t)(max_gb * 1024ULL * 1024ULL * 1024ULL),
                                CACHE_OPEN_NO_TAG_INDEX | CACHE_OPEN_NO_VECTOR_INDEX |
                                CACHE_OPEN_FAST_READ);
        if (!g_cache) {
            fprintf(stderr, "[ERROR] Failed to open cache: %s\n", cache_dir);
            return 1;
        }
        snprintf(g_cache_dir, sizeof(g_cache_dir), "%s", cache_dir);
        g_cache_kv_ok = (kv_stamp(cache_dir, &g_cache_mtime, &g_cache_size) == 0);
    }

    // Initialize vector engine for semantic search (reuse if same project/model)
    if (analysis_dir && *analysis_dir) {
        const char* mt = (model_type && *model_type) ? model_type : "jina";
        if (!g_ve || strcmp(g_ve_dir, analysis_dir) != 0 || strcmp(g_ve_model, mt) != 0) {
            if (g_ve) {
                vector_engine_close(g_ve);
                g_ve = NULL;
                g_ve_dir[0] = '\0';
                g_ve_model[0] = '\0';
            }
            g_ve = vector_engine_open(analysis_dir, mt);
            if (!g_ve) {
                fprintf(stderr, "[WARN] Failed to open vector engine: %s\n", vector_engine_error());
            } else {
                snprintf(g_ve_dir, sizeof(g_ve_dir), "%s", analysis_dir);
                snprintf(g_ve_model, sizeof(g_ve_model), "%s", mt);
            }
        }
    }
    
    if (getenv("LITE_CS_DEBUG")) {
        fprintf(stderr, "[query] cache=%s analysis=%s engine=%s\n",
                g_cache ? "hit" : "miss", cache_dir, g_ve ? "hit" : "miss");
    }

    // Build response
    struct timespec ts_start, ts_end;
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    
    json_t* response = json_object();
    json_object_set_new(response, "query", json_string(query));
    json_object_set_new(response, "type", json_string(type));
    json_object_set_new(response, "repo", json_string(repo ? repo : ""));
    
    if (strcmp(type, "exact") == 0) {
        json_t* results = do_exact(query, repo);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else if (strcmp(type, "file") == 0) {
        json_t* results = do_file(query, repo, max_results);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else if (strcmp(type, "symbol") == 0) {
        json_t* results = do_symbol(query, repo, max_results);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else if (strcmp(type, "context") == 0) {
        json_t* result = do_context(query, repo, call_depth);
        json_t* results = json_object_get(result, "results");
        json_t* ctx = json_object_get(result, "context");
        json_t* stats = json_object_get(result, "stats");
        // auto 把单标识符判成 context，但符号不存在时 context 全空；
        // 有向量引擎就退回语义搜索，别让调用方看到空结果。
        if (results) json_object_set(response, "results", results);
        if (ctx) json_object_set(response, "context", ctx);
        if (stats) json_object_set(response, "stats", stats);
        if (auto_type && g_ve && (!results || json_array_size(results) == 0)) {
            json_t* sr = do_search(query, repo, &opts, max_results);
            if (json_array_size(sr) > 0 && !json_object_get(json_array_get(sr, 0), "_note")) {
                json_object_set_new(response, "results", sr);
                json_object_set_new(response, "type", json_string("search"));
            } else {
                json_decref(sr);
            }
        }
        json_decref(result);
    } else if (strcmp(type, "dataflow") == 0) {
        json_t* results = do_dataflow(query, repo, max_results);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else {
        // Search type: use vector engine with advanced options
        json_t* results = do_search(query, repo, &opts, max_results);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    }
    
    clock_gettime(CLOCK_MONOTONIC, &ts_end);
    long elapsed_ms = (ts_end.tv_sec - ts_start.tv_sec) * 1000 + 
                      (ts_end.tv_nsec - ts_start.tv_nsec) / 1000000;
    json_object_set_new(response, "timing_ms", json_integer(elapsed_ms));
    
    // Print output
    if (brief) {
        print_brief(response);
    } else {
        char* output = json_dumps(response, pretty ? JSON_INDENT(2) : JSON_COMPACT);
        if (output) {
            printf("%s\n", output);
            free(output);
        } else {
            fprintf(stderr, "[ERROR] json_dumps failed\n");
        }
    }
    
    json_decref(response);
    // 故意不关闭：g_cache/g_ve 留在进程内给后续 query 复用。
    return 0;
}
