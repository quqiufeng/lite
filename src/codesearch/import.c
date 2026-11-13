/*
 * cache_import.c — C implementation of code_to_memory.py
 * 
 * Imports analysis results into KV Cache using jansson for JSON parsing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>
#include <jansson.h>
#include "cs_compat.h"

#define MAX_LINE (1024 * 1024)
#define SYNC_INTERVAL 25000  /* 减少 sync 频率: 5000→25000，大缓存时每次 sync 成本高 */
#define MAX_VALUE_LEN (1024 * 1024)

// Cache API from libmydb.so
#define CACHE_OPEN_NO_TAG_INDEX (1u << 0)
#define CACHE_OPEN_NO_VECTOR_INDEX (1u << 1)
extern void* cache_open_ex(const char* dir, size_t max_size, unsigned flags);
extern void* cache_open(const char* dir, size_t max_size);
extern void cache_close(void* cache);
extern int cache_sync(void* cache);
extern int cache_set(void* cache, const char* key, const char* value, uint64_t ttl);
extern size_t cache_memory_used(void* cache);
typedef struct {
    const char* key;
    const char* value;
    uint64_t ttl_ms;
} cache_batch_item_t;
extern int cache_batch_set(void* cache, const cache_batch_item_t* items, size_t count);

static void* g_cache = NULL;
static int g_total_keys = 0;

static void log_info(const char* msg) {
    time_t now = time(NULL);
    struct tm* tm = localtime(&now);
    char time_str[32];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
    printf("[%s] %s\n", time_str, msg);
}

static void log_warn(const char* msg) {
    fprintf(stderr, "[WARN] %s\n", msg);
}

// Elapsed time since start (for progress estimates)
static time_t g_start_time = 0;

static void log_progress(const char* phase, int done, int total) {
    if (total <= 0) return;
    time_t now = time(NULL);
    double elapsed = difftime(now, g_start_time);
    int pct = done * 100 / total;
    double rate = elapsed > 0 ? done / elapsed : 0;
    double eta = rate > 0 ? (total - done) / rate : 0;
    char msg[128];
    snprintf(msg, sizeof(msg), "%s: %d/%d (%d%%) %.0f keys/s ETA %.0fs",
             phase, done, total, pct, rate, eta);
    log_info(msg);
}

// Batch buffer: use cache_batch_set (one deferred qsort) instead of
// per-key cache_set (O(n) sorted insert each -> O(n^2) on large caches).
#define IMPORT_BATCH_SIZE 8192
static cache_batch_item_t g_batch[IMPORT_BATCH_SIZE];
static char* g_batch_keys[IMPORT_BATCH_SIZE];
static char* g_batch_vals[IMPORT_BATCH_SIZE];
static int g_batch_n = 0;

static void flush_batch(void) {
    if (g_batch_n == 0) return;
    int ret = cache_batch_set(g_cache, g_batch, (size_t)g_batch_n);
    if (ret != 0) {
        for (int i = 0; i < g_batch_n; i++) {
            cache_set(g_cache, g_batch_keys[i], g_batch_vals[i], 0);
        }
    }
    for (int i = 0; i < g_batch_n; i++) {
        free(g_batch_keys[i]);
        free(g_batch_vals[i]);
    }
    g_batch_n = 0;
}

// Safe cache set with size check; buffers into batches for speed.
static int safe_set_json(const char* key, const char* value) {
    size_t len = strlen(value);
    if (len >= MAX_VALUE_LEN) {
        log_warn("Value too large, skipping");
        return 0;
    }
    char* k = strdup(key);
    char* v = strdup(value);
    if (!k || !v) {
        free(k);
        free(v);
        return 0;
    }
    g_batch_keys[g_batch_n] = k;
    g_batch_vals[g_batch_n] = v;
    g_batch[g_batch_n].key = k;
    g_batch[g_batch_n].value = v;
    g_batch[g_batch_n].ttl_ms = 0;
    g_batch_n++;
    g_total_keys++;
    if (g_batch_n >= IMPORT_BATCH_SIZE) {
        flush_batch();
    }
    return 1;
}

// Import a single chunk into KV Cache (raw JSON, no re-parse)
static int import_chunk_raw(const char* namespace, const char* line) {
    // Extract "name" from raw JSON
    const char* name_p = strstr(line, "\"name\":\"");
    if (!name_p) return 0;
    name_p += 8;
    const char* name_end = strchr(name_p, '"');
    if (!name_end || name_end - name_p > 255) return 0;

    // Extract "file" from raw JSON
    const char* file_p = strstr(line, "\"file\":\"");
    if (!file_p) return 0;
    file_p += 8;
    const char* file_end = strchr(file_p, '"');
    if (!file_end) return 0;

    int name_len = name_end - name_p;
    int file_len = file_end - file_p;

    char name[256], filepath[1024];
    memcpy(name, name_p, name_len); name[name_len] = '\0';
    memcpy(filepath, file_p, file_len); filepath[file_len] = '\0';

    if (!name[0] || !filepath[0]) return 0;

    // 长函数会被切成 "// Part N" 窗口；KV 里只保留首个完整 chunk，
    // 否则同一个 key 被后几个 Part 覆盖，symbol/exact 永远拿到 Part 4/5。
    if (strstr(line, " // Part ")) return 0;

    // cache_query 查 chunk 时会把 file 的前导 '/' 去掉，这里统一键格式，
    // 否则绝对路径会生成 ".../chunks//tmp/..." 与查询侧对不上。
    const char* rel = filepath;
    while (*rel == '/') rel++;

    char key[2048];
    snprintf(key, sizeof(key), "%s/chunks/%s/%s", namespace, rel, name);

    return safe_set_json(key, line);
}

// ---- 陈旧 chunk 清理 --------------------------------------------------------
// import 是纯 upsert：分析目录里已经不存在的文件（例如以前被 index 进来、
// 后来进了 noise 名单的 dist/ 副本）的 chunk key 会永远留在 KV 里，
// file/symbol 查询照样返回这些幽灵结果。这里按 chunks_meta.jsonl 的文件集合
// 反向清理：扫 <ns>/chunks 前缀，file 段不在集合里的 key 全部删掉。
extern int cache_del(void* cache, const char* key);
extern void* cache_iter_create(void* cache);
extern void cache_iter_destroy(void* iter);
extern int cache_iter_ns_next(void* iter, const char* ns_prefix,
                              const char** key_out, const char** value_out);

// 路径集合（开放寻址）。只存 chunks_meta 里出现过的文件，内存与文件数成正比
// 而不是 chunk 数（内核量级 ~90k 文件，几十 MB 以内）。
typedef struct {
    char** slot;
    size_t cap;
    size_t n;
} pathset_t;

static uint64_t pathset_hash(const char* s, size_t len) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static int pathset_has(const pathset_t* p, const char* s, size_t len) {
    if (!p->cap) return 0;
    size_t mask = p->cap - 1;
    size_t i = (size_t)pathset_hash(s, len) & mask;
    while (p->slot[i]) {
        const char* t = p->slot[i];
        if (strlen(t) == len && memcmp(t, s, len) == 0) return 1;
        i = (i + 1) & mask;
    }
    return 0;
}

// 已存在的串直接接管所有权（调用方不再 free）
static void pathset_insert(pathset_t* p, char* s) {
    size_t mask = p->cap - 1;
    size_t i = (size_t)pathset_hash(s, strlen(s)) & mask;
    while (p->slot[i]) i = (i + 1) & mask;
    p->slot[i] = s;
    p->n++;
}

static int pathset_add(pathset_t* p, const char* s, size_t len) {
    if (pathset_has(p, s, len)) return 0;
    if ((p->n + 1) * 10 >= p->cap * 7) {
        size_t ncap = p->cap ? p->cap * 2 : 1024;
        char** nslot = calloc(ncap, sizeof(char*));
        if (!nslot) return -1;
        char** old = p->slot;
        size_t ocap = p->cap;
        p->slot = nslot;
        p->cap = ncap;
        p->n = 0;
        for (size_t i = 0; i < ocap; i++) {
            if (old[i]) pathset_insert(p, old[i]);
        }
        free(old);
    }
    char* copy = malloc(len + 1);
    if (!copy) return -1;
    memcpy(copy, s, len);
    copy[len] = '\0';
    pathset_insert(p, copy);
    return 1;
}

static void pathset_free(pathset_t* p) {
    for (size_t i = 0; i < p->cap; i++) free(p->slot[i]);
    free(p->slot);
    p->slot = NULL;
    p->cap = p->n = 0;
}

static void purge_stale_chunks(const char* analysis_dir, const char* namespace) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/chunks_meta.jsonl", analysis_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) return;

    char* line = malloc(MAX_LINE);
    if (!line) { fclose(fp); return; }

    pathset_t set = {0};
    while (fgets(line, MAX_LINE, fp)) {
        const char* file_p = strstr(line, "\"file\":\"");
        if (!file_p) continue;
        file_p += 8;
        const char* file_end = strchr(file_p, '"');
        if (!file_end) continue;
        const char* rel = file_p;
        while (rel < file_end && *rel == '/') rel++;   // 与 import_chunk_raw 的键格式一致
        if (pathset_add(&set, rel, (size_t)(file_end - rel)) < 0) break;
    }
    free(line);
    fclose(fp);

    char ns_prefix[512];
    snprintf(ns_prefix, sizeof(ns_prefix), "%s/chunks", namespace);
    size_t ns_prefix_len = strlen(ns_prefix);

    char** stale = NULL;
    size_t nstale = 0, capstale = 0;

    void* it = cache_iter_create(g_cache);
    if (it) {
        const char* key = NULL;
        const char* val = NULL;
        while (cache_iter_ns_next(it, ns_prefix, &key, &val) == 1 && key) {
            // key = <ns>/chunks/<rel>/<symbol>；rel 里带 '/'，符号名不带
            const char* rel = key + ns_prefix_len + 1;
            const char* last = strrchr(rel, '/');
            if (!last) continue;                       // 形态不认识就别动
            size_t rel_len = (size_t)(last - rel);
            if (pathset_has(&set, rel, rel_len)) continue;
            if (nstale == capstale) {
                size_t ncap = capstale ? capstale * 2 : 64;
                char** grown = realloc(stale, ncap * sizeof(char*));
                if (!grown) break;
                stale = grown;
                capstale = ncap;
            }
            char* dup = strdup(key);
            if (!dup) break;
            stale[nstale++] = dup;
        }
        cache_iter_destroy(it);
    }

    // 迭代中不能删：迭代器按 sorted 槽位下标走，删 entry 会让槽位移动。
    size_t deleted = 0;
    for (size_t i = 0; i < nstale; i++) {
        if (cache_del(g_cache, stale[i]) == 0) deleted++;
        free(stale[i]);
    }
    free(stale);
    pathset_free(&set);

    if (nstale) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Purged %zu/%zu stale chunk key(s)", deleted, nstale);
        log_info(msg);
    }
}

// Import chunks_meta.jsonl
static void import_chunks(const char* analysis_dir, const char* namespace) {
    char path[512];
    snprintf(path, sizeof(path), "%s/chunks_meta.jsonl", analysis_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) {
        log_warn("chunks_meta.jsonl not found");
        return;
    }
    
    log_info("Phase 1: Importing chunks...");
    
    char* line = malloc(MAX_LINE);
    int line_count = 0;
    int valid = 0;
    int stored = 0;
    
    // Build symbol index while importing chunks
    while (fgets(line, MAX_LINE, fp)) {
        line_count++;
        if (line_count % 10000 == 0) {
            log_progress("Phase 1: chunks", line_count, 100000);
        }

        // Strip trailing newline
        size_t llen = strlen(line);
        if (llen > 0 && line[llen-1] == '\n') line[--llen] = '\0';
        if (llen > 0 && line[llen-1] == '\r') line[--llen] = '\0';

        valid++;
        if (import_chunk_raw(namespace, line)) {
            stored++;
        }
    }

    free(line);
    fclose(fp);

    // Symbol 索引见 import_symbols()（Phase 1b）
    char msg[256];
    snprintf(msg, sizeof(msg), "Stored %d chunks out of %d", stored, valid);
    log_info(msg);

    purge_stale_chunks(analysis_dir, namespace);
}

// 从原始 JSON 行提取字符串字段（简单 strstr，字段顺序保证顶层字段先出现）
static int raw_field(const char* line, const char* key, char* out, int cap) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    const char* p = strstr(line, pat);
    if (!p) { out[0] = '\0'; return 0; }
    p += strlen(pat);
    const char* e = strchr(p, '"');
    if (!e) { out[0] = '\0'; return 0; }
    int len = (int)(e - p);
    if (len >= cap) len = cap - 1;
    memcpy(out, p, len);
    out[len] = '\0';
    return 1;
}

// 同名符号可能有多个定义（内核 arch/* 尤其多）。rank 越小越优先：
// .c 里的 function/method → 浅路径 → 头文件/深路径，避免 start_kernel 先命中 arch/alpha。
static int symbol_rank(const char* file, const char* kind) {
    int depth = 0;
    for (const char* p = file; *p; p++) if (*p == '/') depth++;
    size_t n = file ? strlen(file) : 0;
    int is_header = (n >= 2 && strcmp(file + n - 2, ".h") == 0);
    int is_func = (strcmp(kind, "function") == 0 || strcmp(kind, "method") == 0);
    if (is_func && !is_header) return depth;
    if (!is_header) return 10 + depth;
    return 100 + depth;
}

// 导入 symbol 反向索引：/code/<ns>/symbols/<name> = [{name,kind,file,line}, ...]
// 供 cache_query --type symbol/context 使用（旧版为提速跳过了此步，导致 context 恒空）。
static void import_symbols(const char* analysis_dir, const char* namespace) {
    char path[512];
    snprintf(path, sizeof(path), "%s/chunks_meta.jsonl", analysis_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) { log_warn("chunks_meta.jsonl not found (symbols)"); return; }

    log_info("Phase 1b: Building symbol index...");

    json_t* map = json_object();   // name -> array of {name,kind,file,line}
    char* line = NULL;
    size_t line_cap = 0;
    int added = 0;

    // 用 jansson 解析整行：raw_field 靠 strchr('"') 找结尾，遇转义引号即截断
    // （signature 里带引号/中文正是高危样本）。getline 顺手解决超长行。
    while (getline(&line, &line_cap, fp) != -1) {
        char name[512], kind[64], file[1024];
        json_error_t jerr;
        json_t* rec = json_loads(line, 0, &jerr);
        if (!rec) continue;
        const char* nv = json_string_value(json_object_get(rec, "name"));
        const char* fv = json_string_value(json_object_get(rec, "file"));
        const char* kv = json_string_value(json_object_get(rec, "kind"));
        name[0] = kind[0] = file[0] = '\0';
        if (nv) snprintf(name, sizeof(name), "%s", nv);
        if (fv) snprintf(file, sizeof(file), "%s", fv);
        if (kv) snprintf(kind, sizeof(kind), "%s", kv);
        if (!name[0] || !file[0]) { json_decref(rec); continue; }

        // 过滤低价值 kind（变量/成员/局部等不建符号索引）
        if (strcmp(kind, "variable") == 0 || strcmp(kind, "member") == 0 ||
            strcmp(kind, "field") == 0 || strcmp(kind, "local") == 0 ||
            strcmp(kind, "parameter") == 0) {
            json_decref(rec);
            continue;
        }

        long ln = (long)json_integer_value(json_object_get(rec, "line_start"));

        json_t* arr = json_object_get(map, name);
        if (!arr) {
            arr = json_array();
            json_object_set_new(map, name, arr);
        }
        // 同一 name/file/line/kind 只保留一条（长函数 Part 会重复登记）。
        size_t si;
        json_t* old;
        int duplicate = 0;
        json_array_foreach(arr, si, old) {
            const char* of = json_string_value(json_object_get(old, "file"));
            const char* ok = json_string_value(json_object_get(old, "kind"));
            json_int_t ol = json_integer_value(json_object_get(old, "line"));
            if (of && ok && strcmp(of, file) == 0 && strcmp(ok, kind) == 0 && ol == ln) {
                duplicate = 1;
                break;
            }
        }
        if (duplicate) { json_decref(rec); continue; }

        json_t* obj = json_object();
        json_object_set_new(obj, "name", json_string(name));
        json_object_set_new(obj, "kind", json_string(kind));
        json_object_set_new(obj, "file", json_string(file));
        json_object_set_new(obj, "line", json_integer(ln));

        // 按 symbol_rank 排序插入；do_symbol 取首个，因此 canonical 定义优先。
        int rank = symbol_rank(file, kind);
        size_t pos = json_array_size(arr);
        for (size_t ri = 0; ri < json_array_size(arr); ri++) {
            json_t* old = json_array_get(arr, ri);
            const char* of = json_string_value(json_object_get(old, "file"));
            const char* ok = json_string_value(json_object_get(old, "kind"));
            if (of && ok && rank < symbol_rank(of, ok)) { pos = ri; break; }
        }
        json_array_insert_new(arr, pos, obj);
        added++;
        json_decref(rec);
    }

    free(line);
    fclose(fp);

    const char* nm;
    json_t* arr;
    int written = 0;
    json_object_foreach(map, nm, arr) {
        char key[2048];
        snprintf(key, sizeof(key), "%s/symbols/%s", namespace, nm);
        char* s = json_dumps(arr, JSON_COMPACT);
        if (s) {
            safe_set_json(key, s);
            free(s);
            written++;
        }
    }

    json_decref(map);

    char msg[160];
    snprintf(msg, sizeof(msg), "Indexed %d symbol entries into %d names", added, written);
    log_info(msg);
}

// call_graph.json 的 `arguments` 在不同产出方有两种形态：字符串，或
// 调用点实参的数组（新版 callgraph.c 写数组）。只认 json_string_value 会让
// 数组形态静默变成空串 —— 调用点全丢参数，看着像「没解析出来」。
// 这里两种都接：数组按 ", " 拼成一个字符串，超长截断。
static const char* call_args_text(json_t* call, char* buf, size_t cap) {
    json_t* a = json_object_get(call, "arguments");
    if (!a || cap == 0) return "";
    const char* s = json_string_value(a);
    if (s) {
        snprintf(buf, cap, "%s", s);
        return buf;
    }
    if (!json_is_array(a)) return "";
    size_t n = json_array_size(a), used = 0;
    buf[0] = '\0';
    for (size_t i = 0; i < n; i++) {
        json_t* it = json_array_get(a, i);
        const char* t = json_string_value(it);
        char numbuf[32];
        if (!t) {
            // 非字符串元素（数字/布尔）按 JSON 文本近似，别静默丢参数
            if (json_is_integer(it)) {
                snprintf(numbuf, sizeof(numbuf), "%lld", (long long)json_integer_value(it));
                t = numbuf;
            } else {
                continue;
            }
        }
        int w = snprintf(buf + used, cap - used, "%s%s", used ? ", " : "", t);
        if (w < 0 || (size_t)w >= cap - used) {  // 截断：保证 '\0'
            buf[cap - 1] = '\0';
            return buf;
        }
        used += (size_t)w;
    }
    return buf;
}

// Import call_graph.json
static void import_callgraph(const char* analysis_dir, const char* namespace) {
    char path[512];
    snprintf(path, sizeof(path), "%s/call_graph.json", analysis_dir);
    
    json_error_t error;
    json_t* root = json_load_file(path, 0, &error);
    if (!root) {
        log_warn("call_graph.json not found or invalid");
        return;
    }
    
    log_info("Phase 2: Importing call graph...");
    
    const char* func_name;
    json_t* func_data;
    int stored_callers = 0;
    int stored_callees = 0;

    // 正向表：caller → [callee 调用点]。call_graph.json 是反向图（key=callee，
    // "function"=caller），旧版把 func_name(callee 自己) 当 callee 存 → 全自指。
    json_t* callee_map = json_object();
    
    int callgraph_total = json_object_size(root);
    int callgraph_idx = 0;
    json_object_foreach(root, func_name, func_data) {
        callgraph_idx++;
        if (callgraph_idx % 1000 == 0) {
            log_progress("Phase 2: call graph", callgraph_idx, callgraph_total);
        }
        json_t* calls = json_object_get(func_data, "calls");
        if (!calls || !json_is_array(calls)) continue;
        
        // Build callers of func_name（call_graph.json 的 key 即 callee）
        json_t* callers = json_array();
        
        size_t idx;
        json_t* call;
        json_array_foreach(calls, idx, call) {
            char args_buf[512];
            const char* caller = json_string_value(json_object_get(call, "function"));
            const char* file = json_string_value(json_object_get(call, "file"));
            json_int_t line = json_integer_value(json_object_get(call, "line"));
            const char* args = call_args_text(call, args_buf, sizeof(args_buf));
            // 间接/成员调用标注（callgraph.c 写、query 侧展示）：obj->fn() 这类边
            // 只能按裸名解析，可能与同名直接调用混淆，标出来供调用方打折。
            json_t* indirect_j = json_object_get(call, "indirect");
            int indirect = (indirect_j && json_is_true(indirect_j)) ? 1 : 0;
            const char* via = json_string_value(json_object_get(call, "via"));
            // 跨文件解析结果（callgraph.c 写）：local=同文件定义，def=唯一定义文件，
            // ambiguous=多份同名实现混在这条边上。三者全空 = external。
            const char* def = json_string_value(json_object_get(call, "def"));
            const char* scope_j = json_string_value(json_object_get(call, "scope"));
            int scope_ambiguous = (scope_j && strcmp(scope_j, "ambiguous") == 0);
            int scope_local = (scope_j && strcmp(scope_j, "local") == 0);
            int defs_n = (int)json_integer_value(json_object_get(call, "defs"));
            
            if (!caller) continue;
            
            json_t* site = json_object();
            json_object_set_new(site, "name", json_string(caller));
            json_object_set_new(site, "file", json_string(file ? file : ""));
            json_object_set_new(site, "line", json_integer(line));
            json_object_set_new(site, "args", json_string(args ? args : ""));
            if (indirect) {
                json_object_set_new(site, "indirect", json_true());
                if (via) json_object_set_new(site, "via", json_string(via));
            }
            if (scope_local) json_object_set_new(site, "scope", json_string("local"));
            if (def) {
                json_object_set_new(site, "def", json_string(def));
                if (!json_object_get(site, "scope"))
                    json_object_set_new(site, "scope", json_string("global"));
            }
            if (scope_ambiguous) {
                json_object_set_new(site, "scope", json_string("ambiguous"));
                json_object_set_new(site, "defs", json_integer(defs_n > 0 ? defs_n : 2));
            }
            json_array_append_new(callers, site);

            // 正向累加：caller 调用了 callee(=func_name)
            json_t* carr = json_object_get(callee_map, caller);
            if (!carr) {
                carr = json_array();
                json_object_set_new(callee_map, caller, carr);
            }
            json_t* site2 = json_object();
            json_object_set_new(site2, "name", json_string(func_name));
            json_object_set_new(site2, "file", json_string(file ? file : ""));
            json_object_set_new(site2, "line", json_integer(line));
            json_object_set_new(site2, "args", json_string(args ? args : ""));
            if (indirect) {
                json_object_set_new(site2, "indirect", json_true());
                if (via) json_object_set_new(site2, "via", json_string(via));
            }
            if (scope_local) json_object_set_new(site2, "scope", json_string("local"));
            if (def) {
                json_object_set_new(site2, "def", json_string(def));
                if (!json_object_get(site2, "scope"))
                    json_object_set_new(site2, "scope", json_string("global"));
            }
            if (scope_ambiguous) {
                json_object_set_new(site2, "scope", json_string("ambiguous"));
                json_object_set_new(site2, "defs", json_integer(defs_n > 0 ? defs_n : 2));
            }
            json_array_append_new(carr, site2);
        }
        
        // Store callers: who calls this function
        if (json_array_size(callers) > 0) {
            char key[512];
            snprintf(key, sizeof(key), "%s/callers/%s", namespace, func_name);
            json_t* val = json_object();
            json_object_set_new(val, "count", json_integer(json_array_size(callers)));
            json_object_set_new(val, "callers", callers);
            char* str = json_dumps(val, JSON_COMPACT);
            if (str) {
                safe_set_json(key, str);
                free(str);
                stored_callers++;
            }
            json_decref(val);
        } else {
            json_decref(callers);
        }
    }
    
    // Store callees（正向）: what each function calls
    {
        const char* caller_name;
        json_t* carr;
        json_object_foreach(callee_map, caller_name, carr) {
            char key[512];
            snprintf(key, sizeof(key), "%s/callees/%s", namespace, caller_name);
            json_t* val = json_object();
            json_object_set_new(val, "count", json_integer(json_array_size(carr)));
            json_object_set_new(val, "callees", json_incref(carr));
            char* str = json_dumps(val, JSON_COMPACT);
            if (str) {
                safe_set_json(key, str);
                free(str);
                stored_callees++;
            }
            json_decref(val);
        }
    }
    json_decref(callee_map);
    
    json_decref(root);
    
    char msg[128];
    snprintf(msg, sizeof(msg), "Stored %d caller entries, %d callee entries", stored_callers, stored_callees);
    log_info(msg);
}

// Import dataflow.json
// _func_index 超过单值上限时的分片落盘：旧版只打一行 "skipped"，等于整块索引
// 静默消失（谁也不知道丢了什么）。这里按 4096 个函数一片写 _func_index/<NNNN>，
// 再写一条 _func_index_meta 记片数与函数总数，超限也照样可查。
static void store_sharded_func_index(const char* namespace, json_t* func_index,
                                     size_t total_bytes) {
    size_t total_funcs = json_object_size(func_index);
    json_t* shard = json_object();
    if (!shard) return;
    int in_shard = 0;
    int shards = 0;
    long long indexed = 0;
    const char* sk;
    json_t* sv;
    json_object_foreach(func_index, sk, sv) {
        json_object_set(shard, sk, sv);
        in_shard++;
        if (in_shard < 4096) continue;
        char* s = json_dumps(shard, JSON_COMPACT);
        if (s && strlen(s) < MAX_VALUE_LEN) {
            char skey[640];
            snprintf(skey, sizeof(skey), "%s/dataflow/_func_index/%04d",
                     namespace, shards + 1);
            safe_set_json(skey, s);
            shards++;
            indexed += in_shard;
            json_object_clear(shard);
            in_shard = 0;
        }
        free(s);
    }
    if (in_shard > 0) {
        char* s = json_dumps(shard, JSON_COMPACT);
        if (s && strlen(s) < MAX_VALUE_LEN) {
            char skey[640];
            snprintf(skey, sizeof(skey), "%s/dataflow/_func_index/%04d",
                     namespace, shards + 1);
            safe_set_json(skey, s);
            shards++;
            indexed += in_shard;
        }
        free(s);
    }
    json_decref(shard);

    json_t* meta = json_object();
    if (meta) {
        json_object_set_new(meta, "shards", json_integer(shards));
        json_object_set_new(meta, "functions", json_integer((json_int_t)total_funcs));
        json_object_set_new(meta, "indexed_functions", json_integer((json_int_t)indexed));
        json_object_set_new(meta, "key_prefix", json_string("dataflow/_func_index/"));
        json_object_set_new(meta, "note", json_string(
            "whole _func_index exceeded the 1MB single-value limit; read the shards, "
            "or prefer dataflow/funcs/<func> for exact lookups"));
        char* mstr = json_dumps(meta, JSON_COMPACT);
        if (mstr) {
            char mkey[512];
            snprintf(mkey, sizeof(mkey), "%s/dataflow/_func_index_meta", namespace);
            safe_set_json(mkey, mstr);
            free(mstr);
        }
        json_decref(meta);
    }

    char msg[192];
    snprintf(msg, sizeof(msg),
             "Phase 3: _func_index %.1f MB > limit, sharded into %d value(s) "
             "(%lld/%lld funcs indexed; see dataflow/_func_index_meta)",
             (double)total_bytes / (1024.0 * 1024.0), shards,
             indexed, (long long)total_funcs);
    log_info(msg);
}

static void import_dataflow(const char* analysis_dir, const char* namespace) {
    char path[512];
    snprintf(path, sizeof(path), "%s/dataflow.json", analysis_dir);
    
    json_error_t error;
    json_t* root = json_load_file(path, 0, &error);
    if (!root) {
        log_warn("dataflow.json not found or invalid");
        return;
    }
    
    log_info("Phase 3: Importing dataflow...");
    
    const char* var_name;
    json_t* var_data;
    int stored_vars = 0;
    
    int dataflow_total = json_object_size(root);
    int dataflow_idx = 0;
    json_object_foreach(root, var_name, var_data) {
        dataflow_idx++;
        if (dataflow_idx % 200 == 0) {
            log_progress("Phase 3: dataflow", dataflow_idx, dataflow_total);
        }
        json_t* occurrences = json_object_get(var_data, "occurrences");
        if (!occurrences || !json_is_array(occurrences)) continue;
        
        // Store variable occurrences
        char key[512];
        snprintf(key, sizeof(key), "%s/dataflow/vars/%s", namespace, var_name);
        json_t* val = json_object();
        json_object_set_new(val, "count", json_integer(json_array_size(occurrences)));
        json_object_set_new(val, "occurrences", json_incref(occurrences));
        // type（int/void/struct/...）：查询时才知道这是结构体还是普通变量，
        // 之前一律丢掉，`dataflow address_space` 只看到一个光秃秃的变量名。
        json_t* vtype = json_object_get(var_data, "type");
        if (vtype && json_is_string(vtype))
            json_object_set_new(val, "type", json_incref(vtype));
        // 结构体的字段清单（只留名字 + 访问次数，字段的 occurrence 走
        // dataflow/fields/<field>，不在这里重复存 context 大字符串）。
        json_t* vfields = json_object_get(var_data, "fields");
        if (vfields && json_is_object(vfields) && json_object_size(vfields) > 0) {
            json_t* fs = json_object();
            const char* fn;
            json_t* fo;
            json_object_foreach(vfields, fn, fo) {
                json_object_set_new(fs, fn, json_integer(
                    json_is_array(fo) ? (json_int_t)json_array_size(fo) : 0));
            }
            json_object_set_new(val, "fields", fs);
            json_object_set_new(val, "field_count", json_integer(json_object_size(vfields)));
        }
        // 跨过程跳（实参位置 → callee 形参）：analyzer 里算好落盘，查询侧直接读，
        // 不再用 strstr(args, var) 猜（猜会把 bufsize 算成 buf、把嵌套调用的内层
        // 实参算成外层实参）。单变量最多 48 条，KV 里全量存，查询时再截。
        json_t* vhops = json_object_get(var_data, "hops");
        if (vhops && json_is_array(vhops) && json_array_size(vhops) > 0) {
            json_object_set_new(val, "hops", json_incref(vhops));
            json_object_set_new(val, "hop_count", json_integer(
                (json_int_t)json_array_size(vhops)));
        }
        
        char* str = json_dumps(val, JSON_COMPACT);
        if (str) {
            safe_set_json(key, str);
            free(str);
            stored_vars++;
        }
        json_decref(val);
        
    }
    
    // Build function index: aggregate all variables per function
    // (single pass after variable storage avoids N*M cache_set calls)
    json_t* func_index = json_object();
    json_object_foreach(root, var_name, var_data) {
        json_t* occurrences = json_object_get(var_data, "occurrences");
        if (!occurrences || !json_is_array(occurrences)) continue;
        size_t idx;
        json_t* occ;
        json_array_foreach(occurrences, idx, occ) {
            const char* func = json_string_value(json_object_get(occ, "func"));
            if (!func) func = "unknown";
            json_t* arr = json_object_get(func_index, func);
            if (!arr) {
                arr = json_array();
                json_object_set_new(func_index, func, arr);
            }
            // 同一函数里同一个变量会出现多次（每个 use 一条 occurrence），
            // 索引只保留首次声明行，否则 funcs/<func> 里全是重复项。
            int dup = 0;
            size_t ei;
            json_t* e;
            json_array_foreach(arr, ei, e) {
                const char* ev = json_string_value(json_object_get(e, "var"));
                if (ev && strcmp(ev, var_name) == 0) { dup = 1; break; }
            }
            if (dup) continue;
            json_t* entry = json_object();
            json_object_set_new(entry, "var", json_string(var_name));
            json_object_set_new(entry, "line", json_integer(
                json_integer_value(json_object_get(occ, "line"))));
            json_array_append_new(arr, entry);
        }
    }
    
    // 全量函数索引：内核量级会超过 1MB 单值上限（旧版在这里打一条
    // "Value too large, skipping"，谁也不知道到底丢了什么）。查询侧已经改成
    // cache_get `dataflow/funcs/<func>`，这份大块索引只剩调试价值，所以
    // 超限就明确说一句跳过，不再假装失败。
    //
    // 函数数量先设闸：先 json_dumps 再看长度，等于为了知道「太大」而先把
    // 几 GB 的字符串拼出来——内核 191850 个函数那次在 18GB RSS + swap 抖动下
    // 卡在 json_dumps 里 29 分钟没动一行盘（gdb: json_dump_callback）。
    // 落盘与否由函数条数决定，超大就只写 dataflow/_func_index_meta 记一笔。
    char fkey[512];
    snprintf(fkey, sizeof(fkey), "%s/dataflow/_func_index", namespace);
    size_t func_count = json_object_size(func_index);
    size_t func_index_max = 20000;
    const char* fimax_env = getenv("LITE_CS_FUNC_INDEX_MAX");
    if (fimax_env && *fimax_env) {
        long v = atol(fimax_env);
        if (v > 0) func_index_max = (size_t)v;
    }
    if (func_count <= func_index_max) {
        char* fstr = json_dumps(func_index, JSON_COMPACT);
        if (fstr) {
            if (strlen(fstr) < MAX_VALUE_LEN) {
                safe_set_json(fkey, fstr);
            } else {
                store_sharded_func_index(namespace, func_index, strlen(fstr));
            }
            free(fstr);
        }
    } else {
        json_t* meta = json_object();
        if (meta) {
            json_object_set_new(meta, "shards", json_integer(0));
            json_object_set_new(meta, "functions", json_integer((json_int_t)func_count));
            json_object_set_new(meta, "indexed_functions", json_integer(0));
            json_object_set_new(meta, "key_prefix", json_string("dataflow/funcs/"));
            json_object_set_new(meta, "skipped", json_true());
            json_object_set_new(meta, "note", json_string(
                "function count above LITE_CS_FUNC_INDEX_MAX (default 20000): whole "
                "_func_index block skipped; query dataflow/funcs/<func> instead"));
            char* mstr = json_dumps(meta, JSON_COMPACT);
            if (mstr) {
                char mkey[512];
                snprintf(mkey, sizeof(mkey), "%s/dataflow/_func_index_meta", namespace);
                safe_set_json(mkey, mstr);
                free(mstr);
            }
            json_decref(meta);
        }
        char msg[192];
        snprintf(msg, sizeof(msg),
                 "Phase 3: _func_index skipped (%zu funcs > LITE_CS_FUNC_INDEX_MAX=%zu), "
                 "per-function dataflow/funcs/ keys only", func_count, func_index_max);
        log_info(msg);
    }

    // 每函数一条 `dataflow/funcs/<func>`：查某个函数碰了哪些变量时直接
    // cache_get O(1)，不用把几百 MB 的 _func_index 整块读进来反序列化。
    const char* fname;
    json_t* fvars;
    int stored_funcs = 0;
    json_object_foreach(func_index, fname, fvars) {
        if (!fname || !*fname || strcmp(fname, "unknown") == 0) continue;
        if (strlen(fname) > 200) continue;
        json_t* val = json_object();
        json_object_set_new(val, "func", json_string(fname));
        json_object_set_new(val, "count", json_integer(json_array_size(fvars)));
        json_object_set_new(val, "vars", json_incref(fvars));
        char* vstr = json_dumps(val, JSON_COMPACT);
        if (vstr) {
            char vkey[640];
            snprintf(vkey, sizeof(vkey), "%s/dataflow/funcs/%s", namespace, fname);
            safe_set_json(vkey, vstr);
            free(vstr);
            stored_funcs++;
        }
        json_decref(val);
    }
    if (stored_funcs > 0) {
        char msg[128];
        snprintf(msg, sizeof(msg), "Phase 3: indexed %d functions for dataflow", stored_funcs);
        log_info(msg);
    }
    json_decref(func_index);

    // ---- 结构体字段聚合 dataflow/fields/<field> ------------------------------
    // dataflow.json 把字段访问挂在父结构体下面（fields: {name: [occ...]}），
    // 字段名自己作为变量只有 0 条 occurrence —— 所以 `dataflow i_pages`（xarray
    // 里 22 万次字段访问之一）一直 0 命中。这里按字段名聚合跨结构体的访问：
    // funcs 计数 + 行号 + 样本文件，**丢掉每条 occurrence 的 context 大字符串**
    // （内核字段访问总量 22 万条，带 context 会把 KV 撑大一倍）。
    json_t* field_index = json_object();  // field -> {count, structs, funcs{func:...}}
    json_object_foreach(root, var_name, var_data) {
        json_t* vfields = json_object_get(var_data, "fields");
        if (!vfields || !json_is_object(vfields)) continue;
        const char* fname;
        json_t* foccs;
        json_object_foreach(vfields, fname, foccs) {
            if (!json_is_array(foccs) || json_array_size(foccs) == 0) continue;
            json_t* agg = json_object_get(field_index, fname);
            if (!agg) {
                agg = json_object();
                json_object_set_new(agg, "field", json_string(fname));
                json_object_set_new(agg, "count", json_integer(0));
                json_object_set_new(agg, "structs", json_array());
                json_object_set_new(agg, "funcs", json_object());
                json_object_set_new(field_index, fname, agg);
            }
            json_t* structs = json_object_get(agg, "structs");
            int seen = 0;
            size_t si;
            json_t* s;
            json_array_foreach(structs, si, s) {
                const char* sn = json_string_value(s);
                if (sn && strcmp(sn, var_name) == 0) { seen = 1; break; }
            }
            if (!seen && json_array_size(structs) < 16)
                json_array_append_new(structs, json_string(var_name));
            json_object_set_new(agg, "count", json_integer(
                json_integer_value(json_object_get(agg, "count")) +
                (json_int_t)json_array_size(foccs)));

            json_t* funcs = json_object_get(agg, "funcs");
            size_t oi;
            json_t* o;
            json_array_foreach(foccs, oi, o) {
                const char* fn = json_string_value(json_object_get(o, "func"));
                if (!fn || !*fn) fn = "unknown";
                if (strlen(fn) > 200) continue;
                json_t* fe = json_object_get(funcs, fn);
                if (!fe) {
                    if (json_object_size(funcs) >= 256) continue;  // 边界：单个字段最多记 256 个函数
                    fe = json_object();
                    json_object_set_new(fe, "func", json_string(fn));
                    json_object_set_new(fe, "count", json_integer(0));
                    json_object_set_new(fe, "lines", json_array());
                    const char* file = json_string_value(json_object_get(o, "file"));
                    if (file) json_object_set_new(fe, "file", json_string(file));
                    json_object_set_new(funcs, fn, fe);
                }
                json_object_set_new(fe, "count", json_integer(
                    json_integer_value(json_object_get(fe, "count")) + 1));
                json_t* lines = json_object_get(fe, "lines");
                json_t* ln = json_object_get(o, "line");
                if (lines && json_is_integer(ln) && json_array_size(lines) < 8) {
                    // 同一行多条 occurrence（定义+赋值/多次访问）只留一个行号，count 仍逐条累加
                    size_t lsz = json_array_size(lines);
                    json_t* last = lsz ? json_array_get(lines, lsz - 1) : NULL;
                    if (!(last && json_equal(last, ln))) json_array_append(lines, ln);
                }
            }
        }
    }

    const char* field_name;
    json_t* field_agg;
    int stored_fields = 0;
    json_object_foreach(field_index, field_name, field_agg) {
        if (!field_name || !*field_name || strlen(field_name) > 200) continue;
        json_t* val = json_object();
        json_object_set_new(val, "field", json_string(field_name));
        json_object_set_new(val, "count", json_incref(json_object_get(field_agg, "count")));
        json_t* structs = json_object_get(field_agg, "structs");
        json_object_set_new(val, "struct_count", json_integer(json_array_size(structs)));
        json_object_set_new(val, "structs", json_incref(structs));
        json_t* funcs = json_object_get(field_agg, "funcs");
        json_t* farr = json_array();
        const char* fk;
        json_t* fv;
        json_object_foreach(funcs, fk, fv) json_array_append_new(farr, json_incref(fv));
        json_object_set_new(val, "func_count", json_integer(json_array_size(farr)));
        json_object_set_new(val, "funcs", farr);
        char* fstr2 = json_dumps(val, JSON_COMPACT);
        if (fstr2) {
            char fkey2[640];
            snprintf(fkey2, sizeof(fkey2), "%s/dataflow/fields/%s", namespace, field_name);
            safe_set_json(fkey2, fstr2);
            free(fstr2);
            stored_fields++;
        }
        json_decref(val);
    }
    json_decref(field_index);
    if (stored_fields > 0) {
        char fmsg[128];
        snprintf(fmsg, sizeof(fmsg), "Phase 3: indexed %d struct fields for dataflow",
                 stored_fields);
        log_info(fmsg);
    }

    // ---- 覆盖范围 dataflow/_meta --------------------------------------------
    // dataflow 只做 C 词法：python/go/ts 的索引命中 0 条时，必须能说清是
    // 「语言不在覆盖范围」还是「名字拼错」，否则调用方只会去重跑 import。
    {
        char mpath[512];
        snprintf(mpath, sizeof(mpath), "%s/dataflow_meta.json", analysis_dir);
        json_error_t merr;
        json_t* meta = json_load_file(mpath, 0, &merr);
        if (meta) {
            char* mstr = json_dumps(meta, JSON_COMPACT);
            if (mstr) {
                char mkey[512];
                snprintf(mkey, sizeof(mkey), "%s/dataflow/_meta", namespace);
                safe_set_json(mkey, mstr);
                free(mstr);
            }
            json_decref(meta);
        }
    }

    json_decref(root);
    
    char msg[128];
    snprintf(msg, sizeof(msg), "Stored %d variables", stored_vars);
    log_info(msg);
}

// Register vector file reference
static void register_vectors(const char* analysis_dir, const char* namespace) {
    DIR* dir = opendir(analysis_dir);
    if (!dir) return;
    
    struct dirent* entry;
    char vector_file[512] = {0};
    while ((entry = readdir(dir)) != NULL) {
        if (strstr(entry->d_name, ".bin") && strstr(entry->d_name, "jina")) {
            snprintf(vector_file, sizeof(vector_file), "%s/%s", analysis_dir, entry->d_name);
            break;
        }
    }
    closedir(dir);
    
    if (vector_file[0]) {
        struct stat st;
        if (stat(vector_file, &st) == 0) {
            char key[512];
            snprintf(key, sizeof(key), "%s/vectors/path", namespace);
            
            json_t* val = json_object();
            json_object_set_new(val, "file", json_string(vector_file));
            json_object_set_new(val, "size_bytes", json_integer(st.st_size));
            json_object_set_new(val, "type", json_string("float32"));
            json_object_set_new(val, "description", json_string("Vector file reference"));
            
            char* str = json_dumps(val, JSON_COMPACT);
            if (str) {
                safe_set_json(key, str);
                free(str);
            }
            json_decref(val);
            
            char msg[256];
            snprintf(msg, sizeof(msg), "Vector file registered: %s", vector_file);
            log_info(msg);
        }
    }
}

// 从 chunks_meta.jsonl 的 file 字段反推源码根（公共目录前缀）。
// 以前 _meta/info 的 source_dir 直接写 analysis_dir（缓存目录），
// 读的人会当成源码根，实际源码在 /opt/linux/src/... 这种地方。
static void derive_source_root(const char* analysis_dir, char* out, size_t cap) {
    out[0] = '\0';
    char path[768];
    snprintf(path, sizeof(path), "%s/chunks_meta.jsonl", analysis_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) return;
    char* line = malloc(65536);
    if (!line) { fclose(fp); return; }
    int seen = 0;
    size_t plen = 0;
    while (seen < 500 && fgets(line, 65536, fp)) {
        json_error_t err;
        json_t* obj = json_loads(line, 0, &err);
        if (!obj) continue;
        const char* file = json_string_value(json_object_get(obj, "file"));
        if (file && *file) {
            size_t flen = strlen(file);
            if (seen == 0) {
                const char* slash = strrchr(file, '/');
                plen = slash ? (size_t)(slash - file) : 0;
                if (plen >= cap) plen = cap - 1;
                memcpy(out, file, plen);
                out[plen] = '\0';
            } else {
                while (plen > 0 && (flen < plen || strncmp(out, file, plen) != 0)) {
                    while (plen > 0 && out[plen - 1] != '/') plen--;
                    if (plen > 0) plen--;
                    out[plen] = '\0';
                }
            }
            seen++;
        }
        json_decref(obj);
    }
    free(line);
    fclose(fp);
    if (plen <= 1) out[0] = '\0';  // 只剩 "/" 或空 = 没有公共根
}

// Store metadata
static void store_metadata(const char* namespace, const char* source_dir,
                           const char* analysis_dir) {
    char key[512];
    snprintf(key, sizeof(key), "%s/_meta/info", namespace);
    
    time_t now = time(NULL);
    struct tm* tm = localtime(&now);
    char time_str[64];
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm);
    
    json_t* val = json_object();
    json_object_set_new(val, "type", json_string("code_repo"));
    json_object_set_new(val, "source_dir", json_string(source_dir));
    // 缓存目录单列：source_dir 只表示源码根，别混用
    json_object_set_new(val, "analysis_dir", json_string(analysis_dir ? analysis_dir : ""));
    json_object_set_new(val, "imported_at", json_string(time_str));
    json_object_set_new(val, "total_keys", json_integer(g_total_keys));
    
    char* str = json_dumps(val, JSON_COMPACT);
    if (str) {
        safe_set_json(key, str);
        free(str);
    }
    json_decref(val);
}

int lite_cs_import_main(int argc, char** argv) {
    if (argc < 3) {
        printf("Usage: %s <analysis_dir> <namespace> [options]\n", argv[0]);
        printf("\nOptions:\n");
        printf("  --cache-dir <dir>      KV Cache directory (default: /memory)\n");
        printf("  --skip-chunks          Skip chunk/symbol import\n");
        printf("  --skip-callgraph       Skip call graph import\n");
        printf("  --skip-dataflow        Skip dataflow import\n");
        printf("  --only-dataflow        Alias for --skip-chunks --skip-callgraph\n");
        printf("\nExamples:\n");
        printf("  %s /opt/code_caches/nginx_cache /code/nginx\n", argv[0]);
        printf("  %s ./linux_subsystems/mm_cache /code/linux/mm --cache-dir ./ai_memory\n", argv[0]);
        printf("  %s /opt/code_caches/php_cache /code/php --only-dataflow\n", argv[0]);
        printf("  %s /opt/code_caches/php_cache /code/php --skip-chunks --skip-callgraph\n", argv[0]);
        return 1;
    }
    
    const char* analysis_dir = argv[1];
    const char* namespace = argv[2];
    const char* cache_dir = "/memory";
    int skip_chunks = 0, skip_callgraph = 0, skip_dataflow = 0;
    
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--cache-dir") == 0 && i + 1 < argc) {
            cache_dir = argv[i + 1];
            i++;
        } else if (strcmp(argv[i], "--only-dataflow") == 0) {
            skip_chunks = 1;
            skip_callgraph = 1;
        } else if (strcmp(argv[i], "--skip-chunks") == 0) {
            skip_chunks = 1;
        } else if (strcmp(argv[i], "--skip-callgraph") == 0) {
            skip_callgraph = 1;
        } else if (strcmp(argv[i], "--skip-dataflow") == 0) {
            skip_dataflow = 1;
        }
    }
    
    g_start_time = time(NULL);
    log_info("Importing analysis into KV Cache");
    printf("  Namespace: %s\n", namespace);
    printf("  Source: %s\n", analysis_dir);
    printf("  Cache: %s\n", cache_dir);
    printf("  Mode: %s\n",
           skip_chunks && skip_callgraph && !skip_dataflow ? "dataflow only" :
           skip_chunks && skip_callgraph && skip_dataflow ? "register only" :
           "full import");
    
    // Linux 内核这种百万级 chunks 的导入会超过 4GiB；默认放宽到 8GiB。
    unsigned long long max_gb = 8;
    const char* kv_max_env = getenv("LITE_CS_KV_MAX_GB");
    if (kv_max_env && *kv_max_env) {
        long g = atol(kv_max_env);
        if (g > 0 && g <= 64) max_gb = (unsigned long long)g;
    }
    g_cache = cache_open_ex(cache_dir, (size_t)(max_gb * 1024ULL * 1024ULL * 1024ULL),
                            CACHE_OPEN_NO_TAG_INDEX | CACHE_OPEN_NO_VECTOR_INDEX);
    if (!g_cache) {
        fprintf(stderr, "[ERROR] Failed to open cache: %s\n", cache_dir);
        return 1;
    }
    
    if (!skip_chunks) {
        import_chunks(analysis_dir, namespace);
        import_symbols(analysis_dir, namespace);
    }
    if (!skip_callgraph) {
        import_callgraph(analysis_dir, namespace);
    }
    if (!skip_dataflow) {
        import_dataflow(analysis_dir, namespace);
    }
    if (!skip_chunks || !skip_callgraph) {
        register_vectors(analysis_dir, namespace);
        // source_dir 报源码根（从 chunk 路径反推），推导失败才退回 analysis_dir
        char root[768];
        derive_source_root(analysis_dir, root, sizeof(root));
        store_metadata(namespace, root[0] ? root : analysis_dir, analysis_dir);
    }
    
    flush_batch();
    cache_sync(g_cache);
    
    char msg[128];
    snprintf(msg, sizeof(msg), "Import complete! Total keys: %d", g_total_keys);
    log_info(msg);
    
    snprintf(msg, sizeof(msg), "Memory used: %zu bytes", cache_memory_used(g_cache));
    log_info(msg);
    
    cache_close(g_cache);
    return 0;
}
