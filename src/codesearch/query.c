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
#include <jansson.h>
#include "vector_engine.h"

// Cache API from libmydb.so
extern void* cache_open(const char* dir, size_t max_size);
extern void cache_close(void* cache);
extern const char* cache_get(void* cache, const char* key);

static void* g_cache = NULL;
static vector_engine_t* g_ve = NULL;
// 进程内复用：同一项目连续 query（TUI/agent）不再反复加载 2GB KV 和数 GB HNSW。
// 反复 create/destroy ORT session 还会偶发段错误；保持 engine 常驻更稳。
static char g_cache_dir[512] = {0};
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

// Exact query
static json_t* do_exact(const char* query) {
    const char* value = cache_get(g_cache, query);
    if (!value) return json_array();
    
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

// Symbol query
static json_t* do_symbol(const char* name, const char* repo) {
    json_t* arr = json_array();
    
    char key[512];
    snprintf(key, sizeof(key), "%s/symbols/%s", repo, name);
    const char* value = cache_get(g_cache, key);
    if (!value) return arr;
    
    json_error_t error;
    json_t* symbols = json_loads(value, 0, &error);
    if (!symbols || !json_is_array(symbols)) {
        if (symbols) json_decref(symbols);
        return arr;
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
            }
        } else {
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
    
    // Get symbol
    json_t* symbol_result = do_symbol(name, repo);
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
    printf("\nQuery types: auto, exact, symbol, context, search\n");
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
                const char* n = json_string_value(json_object_get(json_array_get(callers, i), "name"));
                printf("%s%s", i ? ", " : "", n ? n : "?");
            }
            printf("\n");
        }
        json_t* callees = json_object_get(ctx, "callees");
        if (callees && json_array_size(callees)) {
            printf("callees(%zu): ", json_array_size(callees));
            for (size_t i = 0; i < json_array_size(callees) && i < 30; i++) {
                const char* n = json_string_value(json_object_get(json_array_get(callees, i), "name"));
                printf("%s%s", i ? ", " : "", n ? n : "?");
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
    
    // Auto-detect type
    if (strcmp(type, "auto") == 0) {
        type = detect_query_type(query, repo);
    }
    
    // Open cache (reuse if same project)
    if (!g_cache || strcmp(g_cache_dir, cache_dir) != 0) {
        if (g_cache) {
            cache_close(g_cache);
            g_cache = NULL;
            g_cache_dir[0] = '\0';
        }
        // 与 import 使用同一上限；query 若用更小的 max_memory 而 KV 已超过，
        // cache 内部淘汰/索引路径会出问题（内核索引曾因此偶发段错误）。
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
        snprintf(g_cache_dir, sizeof(g_cache_dir), "%s", cache_dir);
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
        json_t* results = do_exact(query);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else if (strcmp(type, "symbol") == 0) {
        json_t* results = do_symbol(query, repo);
        json_object_set_new(response, "results", results);
        json_object_set_new(response, "context", json_object());
        json_object_set_new(response, "stats", json_object());
    } else if (strcmp(type, "context") == 0) {
        json_t* result = do_context(query, repo, call_depth);
        json_t* results = json_object_get(result, "results");
        json_t* ctx = json_object_get(result, "context");
        json_t* stats = json_object_get(result, "stats");
        if (results) json_object_set(response, "results", results);
        if (ctx) json_object_set(response, "context", ctx);
        if (stats) json_object_set(response, "stats", stats);
        json_decref(result);
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
