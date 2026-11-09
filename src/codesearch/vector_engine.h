/*
 * vector_engine.h — Semantic vector search engine library
 * 
 * Extracted from vector_search.c for reuse in cache_query and other tools.
 * 
 * Usage:
 *   vector_engine_t* engine = vector_engine_open("/opt/code_caches/nginx_cache", "jina");
 *   vector_result_t results[10];
 *   int n = vector_engine_search(engine, "memory pool allocation", 10, results);
 *   for (int i = 0; i < n; i++) {
 *       printf("%s: %f\n", results[i].name, results[i].score);
 *   }
 *   vector_engine_close(engine);
 */

#ifndef VECTOR_ENGINE_H
#define VECTOR_ENGINE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VE_DIM 768
#define VE_MAX_NAME_LEN 256
#define VE_MAX_FILE_LEN 512
#define VE_MAX_CONTENT_LEN 4096
#define VE_MAX_SIGNATURE_LEN 512

// Search result
typedef struct {
    char namespace[256];       // e.g., "/code/nginx"
    char name[VE_MAX_NAME_LEN];       // function/struct name
    char file[VE_MAX_FILE_LEN];       // source file path
    char kind[32];             // function, struct, macro, etc.
    char language[32];         // c, cpp, etc.
    char signature[VE_MAX_SIGNATURE_LEN]; // function signature
    char content[VE_MAX_CONTENT_LEN];     // code content (first ~50 lines)
    int line_start;
    int line_end;
    float score;               // similarity score (0-1)
} vector_result_t;

// Opaque engine handle
typedef struct vector_engine vector_engine_t;

// Search options for filtering and boosting
typedef struct {
    const char* kind_filter;    // e.g., "function", "struct", "macro"
    const char* lang_filter;    // e.g., "c", "cpp"
    const char* file_filter;    // substring match on filename
    int use_keyword_boost;      // TF-IDF keyword boost from word_freq.json
    int use_caller_boost;       // PageRank-like boost from call_graph.json
} vector_search_opts_t;

// Open a vector engine for a given analysis cache directory
// cache_dir: directory containing vectors/, chunks_meta.jsonl, etc.
// model: "jina" or "mpnet"
// Returns NULL on error
vector_engine_t* vector_engine_open(const char* cache_dir, const char* model);

// Close engine and free resources
void vector_engine_close(vector_engine_t* engine);

// Get last error message
const char* vector_engine_error(void);

// Semantic search
// query: natural language query text
// top_k: maximum number of results
// results: output array (caller must allocate at least top_k elements)
// Returns: number of results found (0 to top_k), or -1 on error
int vector_engine_search(vector_engine_t* engine, const char* query, 
                         int top_k, vector_result_t* results);

// Search with namespace filter
int vector_engine_search_ns(vector_engine_t* engine, const char* query,
                            int top_k, const char* namespace,
                            vector_result_t* results);

// Search with advanced options (filtering + boosting)
int vector_engine_search_ex(vector_engine_t* engine, const char* query,
                            int top_k, const char* namespace,
                            const vector_search_opts_t* opts,
                            vector_result_t* results);

// Get total number of vectors indexed
size_t vector_engine_count(vector_engine_t* engine);

#ifdef __cplusplus
}
#endif

#endif // VECTOR_ENGINE_H
