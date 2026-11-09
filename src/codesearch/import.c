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
    char* line = malloc(MAX_LINE);
    int added = 0;

    while (fgets(line, MAX_LINE, fp)) {
        char name[512], kind[64], file[1024];
        if (!raw_field(line, "name", name, sizeof(name))) continue;
        if (!raw_field(line, "file", file, sizeof(file))) continue;
        raw_field(line, "kind", kind, sizeof(kind));

        // 过滤低价值 kind（变量/成员/局部等不建符号索引）
        if (strcmp(kind, "variable") == 0 || strcmp(kind, "member") == 0 ||
            strcmp(kind, "field") == 0 || strcmp(kind, "local") == 0 ||
            strcmp(kind, "parameter") == 0) {
            continue;
        }

        long ln = 0;
        const char* lp = strstr(line, "\"line_start\":");
        if (lp) ln = strtol(lp + 13, NULL, 10);

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
        if (duplicate) continue;

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
            const char* caller = json_string_value(json_object_get(call, "function"));
            const char* file = json_string_value(json_object_get(call, "file"));
            json_int_t line = json_integer_value(json_object_get(call, "line"));
            const char* args = json_string_value(json_object_get(call, "arguments"));
            
            if (!caller) continue;
            
            json_t* site = json_object();
            json_object_set_new(site, "name", json_string(caller));
            json_object_set_new(site, "file", json_string(file ? file : ""));
            json_object_set_new(site, "line", json_integer(line));
            json_object_set_new(site, "args", json_string(args ? args : ""));
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
            json_t* entry = json_object();
            json_object_set_new(entry, "var", json_string(var_name));
            json_object_set_new(entry, "line", json_integer(
                json_integer_value(json_object_get(occ, "line"))));
            json_array_append_new(arr, entry);
        }
    }
    
    // Store function index as single bulk entry
    char fkey[512];
    snprintf(fkey, sizeof(fkey), "%s/dataflow/_func_index", namespace);
    char* fstr = json_dumps(func_index, JSON_COMPACT);
    if (fstr) {
        safe_set_json(fkey, fstr);
        free(fstr);
    }
    json_decref(func_index);
    
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

// Store metadata
static void store_metadata(const char* namespace, const char* source_dir) {
    char key[512];
    snprintf(key, sizeof(key), "%s/_meta/info", namespace);
    
    time_t now = time(NULL);
    struct tm* tm = localtime(&now);
    char time_str[64];
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm);
    
    json_t* val = json_object();
    json_object_set_new(val, "type", json_string("code_repo"));
    json_object_set_new(val, "source_dir", json_string(source_dir));
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
    g_cache = cache_open(cache_dir, (size_t)(max_gb * 1024ULL * 1024ULL * 1024ULL));
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
        store_metadata(namespace, analysis_dir);
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
