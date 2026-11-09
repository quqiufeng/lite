/*
 * vector_engine.c — Semantic vector search engine library implementation
 * 
 * Features:
 *   - ONNX embedder (Jina v2 / MPNet)
 *   - HNSW approximate search + brute force fallback
 *   - TF-IDF keyword boost from word_freq.json
 *   - PageRank-like caller boost from call_graph.json
 *   - Filtering by kind/language/filename
 */

#define _GNU_SOURCE
#include "vector_engine.h"
#include "cache.h"
#include "onnx_embedder.h"
#include "cache_hnsw.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include "cs_compat.h"

#define MAX_NAMESPACES 32

static char g_error_msg[512] = {0};

static void set_error(const char* msg) {
    strncpy(g_error_msg, msg, sizeof(g_error_msg) - 1);
    g_error_msg[sizeof(g_error_msg) - 1] = '\0';
}

// ============================================================
// Internal: Vector source management
// ============================================================

typedef struct {
    char namespace[256];
    char vec_file[512];
    char idx_file[512];
    char hnsw_file[512];
    char model[32];
    uint32_t count;
    void* vec_mmap;
    size_t vec_mmap_size;
    float* vec_data;
    char** names;
    size_t* offsets;
    hnsw_index_t* hnsw;   // lazy-loaded once; HNSW 文件很大，不能每次 query 重读
} ve_source_t;

static int discover_sources(const char* cache_dir, ve_source_t* sources, int max_sources) {
    char vectors_dir[512];
    snprintf(vectors_dir, sizeof(vectors_dir), "%s/vectors", cache_dir);
    
    DIR* dir = opendir(vectors_dir);
    if (!dir) return 0;
    
    int count = 0;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL && count < max_sources) {
        size_t nlen = strlen(entry->d_name);
        int is_jina = nlen > 9 && strcmp(entry->d_name + nlen - 9, ".jina.bin") == 0;
        int is_mpnet = nlen > 11 && strcmp(entry->d_name + nlen - 11, ".mpnet.bin") == 0;
        if (!is_jina && !is_mpnet) continue;
        
        ve_source_t* s = &sources[count];
        memset(s, 0, sizeof(ve_source_t));
        
        snprintf(s->vec_file, sizeof(s->vec_file), "%s/vectors/%s", cache_dir, entry->d_name);
        
        char base_name[256];
        size_t len = strlen(entry->d_name);
        strncpy(base_name, entry->d_name, len - 4);
        base_name[len - 4] = '\0';
        
        char* model_suffix = NULL;
        char* last_dot = strrchr(base_name, '.');
        if (last_dot) {
            if (strcmp(last_dot + 1, "mpnet") == 0 ||
                strcmp(last_dot + 1, "jina") == 0) {
                model_suffix = last_dot + 1;
                *last_dot = '\0';
            }
        }
        if (!model_suffix) model_suffix = "mpnet";
        
        char ns[256] = {0};
        strncpy(ns, base_name, sizeof(ns) - 1);
        
        if (strncmp(ns, "code_local_", 11) == 0) {
            snprintf(s->namespace, sizeof(s->namespace), "/code/local/%s", ns + 11);
        } else if (strncmp(ns, "code_", 5) == 0) {
            snprintf(s->namespace, sizeof(s->namespace), "/code/%s", ns + 5);
        } else if (strncmp(ns, "books_", 6) == 0) {
            snprintf(s->namespace, sizeof(s->namespace), "/books/%s", ns + 6);
        } else {
            snprintf(s->namespace, sizeof(s->namespace), "/code/local/%s", ns);
        }
        
        strcpy(s->model, model_suffix);
        
        char idx_name[512];
        strncpy(idx_name, entry->d_name, sizeof(idx_name) - 1);
        idx_name[sizeof(idx_name) - 1] = '\0';
        char* dot = strrchr(idx_name, '.');
        if (dot) {
            strcpy(dot, ".idx");
            snprintf(s->idx_file, sizeof(s->idx_file), "%s/vectors/%s", cache_dir, idx_name);
        }
        
        snprintf(s->hnsw_file, sizeof(s->hnsw_file), "%s/vectors/%s.hnsw", cache_dir, entry->d_name);
        
        count++;
    }
    closedir(dir);
    return count;
}

static int parse_index_file(const char* idx_file, char** names, size_t* offsets, int max_entries) {
    FILE* fp = fopen(idx_file, "r");
    if (!fp) return -1;
    
    int count = 0;
    char line[4096];
    while (fgets(line, sizeof(line), fp) && count < max_entries) {
        char* quote = strchr(line, '"');
        if (!quote) continue;
        char* name_start = quote + 1;
        char* name_end = strchr(name_start, '"');
        if (!name_end) continue;
        
        size_t nlen = name_end - name_start;
        if (nlen >= VE_MAX_NAME_LEN) nlen = VE_MAX_NAME_LEN - 1;
        memcpy(names[count], name_start, nlen);
        names[count][nlen] = '\0';
        
        offsets[count] = (size_t)atol(name_end + 2);
        count++;
    }
    fclose(fp);
    return count;
}

static int mmap_source(ve_source_t* s) {
    if (s->vec_mmap) return 0;
    
    int fd = open(s->vec_file, O_RDONLY);
    if (fd < 0) return -1;
    
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return -1; }
    if (st.st_size < 8) { close(fd); return -1; }
    
    void* map = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return -1;
    
    uint32_t count = *(uint32_t*)map;
    uint32_t dim = *(uint32_t*)((char*)map + 4);
    if (dim != VE_DIM) {
        munmap(map, st.st_size);
        return -1;
    }
    
    s->vec_mmap = map;
    s->vec_mmap_size = st.st_size;
    s->count = count;
    s->vec_data = (float*)((char*)map + 8);
    
    s->names = malloc(count * sizeof(char*));
    s->offsets = malloc(count * sizeof(size_t));
    if (!s->names || !s->offsets) {
        munmap(map, st.st_size);
        return -1;
    }
    
    for (uint32_t i = 0; i < count; i++) {
        s->names[i] = malloc(VE_MAX_NAME_LEN);
        if (!s->names[i]) {
            for (uint32_t j = 0; j < i; j++) free(s->names[j]);
            free(s->names); free(s->offsets);
            munmap(map, st.st_size);
            return -1;
        }
    }
    
    if (parse_index_file(s->idx_file, s->names, s->offsets, count) < 0) {
        for (uint32_t i = 0; i < count; i++) free(s->names[i]);
        free(s->names); free(s->offsets);
        munmap(map, st.st_size);
        return -1;
    }
    
    return 0;
}

static void munmap_source(ve_source_t* s) {
    if (s->vec_mmap) {
        munmap(s->vec_mmap, s->vec_mmap_size);
        s->vec_mmap = NULL;
        s->vec_data = NULL;
    }
    if (s->names) {
        for (uint32_t i = 0; i < s->count; i++) free(s->names[i]);
        free(s->names);
        s->names = NULL;
    }
    if (s->offsets) {
        free(s->offsets);
        s->offsets = NULL;
    }
    if (s->hnsw) {
        hnsw_destroy(s->hnsw);
        s->hnsw = NULL;
    }
}

// ============================================================
// Internal: Metadata loading
// ============================================================

typedef struct meta_entry {
    char name[VE_MAX_NAME_LEN];
    char file[VE_MAX_FILE_LEN];
    char kind[32];
    char language[32];
    char signature[VE_MAX_SIGNATURE_LEN];
    char content[VE_MAX_CONTENT_LEN];
    int line_start;
    int line_end;
    struct meta_entry* next;
} meta_entry_t;

#define META_HASH_SIZE 262144

static meta_entry_t** g_meta_hash = NULL;

static uint64_t hash_name_fnv(const char* name) {
    uint64_t h = 0xcbf29ce484222325;
    for (const char* p = name; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 0x100000001b3;
    }
    return h;
}

static int load_metadata(const char* cache_dir) {
    if (g_meta_hash) return 0;
    
    g_meta_hash = calloc(META_HASH_SIZE, sizeof(meta_entry_t*));
    if (!g_meta_hash) return -1;
    
    char path[512];
    snprintf(path, sizeof(path), "%s/chunks_meta.jsonl", cache_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) {
        free(g_meta_hash);
        g_meta_hash = NULL;
        return -1;
    }
    
    char line[8192];
    int loaded = 0;
    while (fgets(line, sizeof(line), fp)) {
        meta_entry_t* entry = calloc(1, sizeof(meta_entry_t));
        if (!entry) continue;
        
        char* p = strstr(line, "\"name\":\"");
        if (p) {
            p += 8;
            char* end = strchr(p, '"');
            if (end) {
                size_t len = end - p;
                if (len >= VE_MAX_NAME_LEN) len = VE_MAX_NAME_LEN - 1;
                memcpy(entry->name, p, len);
                entry->name[len] = '\0';
            }
        }
        
        p = strstr(line, "\"file\":\"");
        if (p) {
            p += 8;
            char* end = strchr(p, '"');
            if (end) {
                size_t len = end - p;
                if (len >= VE_MAX_FILE_LEN) len = VE_MAX_FILE_LEN - 1;
                memcpy(entry->file, p, len);
                entry->file[len] = '\0';
            }
        }
        
        p = strstr(line, "\"kind\":\"");
        if (p) {
            p += 8;
            char* end = strchr(p, '"');
            if (end) {
                size_t len = end - p;
                if (len >= 31) len = 31;
                memcpy(entry->kind, p, len);
                entry->kind[len] = '\0';
            }
        }
        
        p = strstr(line, "\"language\":\"");
        if (p) {
            p += 12;
            char* end = strchr(p, '"');
            if (end) {
                size_t len = end - p;
                if (len >= 31) len = 31;
                memcpy(entry->language, p, len);
                entry->language[len] = '\0';
            }
        }
        
        p = strstr(line, "\"signature\":\"");
        if (p) {
            p += 13;
            char* end = strchr(p, '"');
            if (end) {
                size_t len = end - p;
                if (len >= VE_MAX_SIGNATURE_LEN) len = VE_MAX_SIGNATURE_LEN - 1;
                memcpy(entry->signature, p, len);
                entry->signature[len] = '\0';
            }
        }
        
        p = strstr(line, "\"content\":\"");
        if (p) {
            p += 11;
            char* end = p;
            while (*end) {
                if (*end == '\\' && *(end+1)) { end += 2; continue; }
                if (*end == '"') break;
                end++;
            }
            if (end > p) {
                size_t len = end - p;
                if (len >= VE_MAX_CONTENT_LEN) len = VE_MAX_CONTENT_LEN - 1;
                memcpy(entry->content, p, len);
                entry->content[len] = '\0';
            }
        }
        
        p = strstr(line, "\"line_start\":");
        if (p) entry->line_start = atoi(p + 13);
        p = strstr(line, "\"line_end\":");
        if (p) entry->line_end = atoi(p + 11);
        
        if (entry->name[0]) {
            uint64_t h = hash_name_fnv(entry->name) % META_HASH_SIZE;
            entry->next = g_meta_hash[h];
            g_meta_hash[h] = entry;
            loaded++;
        } else {
            free(entry);
        }
    }
    
    fclose(fp);
    return 0;
}

static meta_entry_t* lookup_meta(const char* name) {
    if (!g_meta_hash || !name || !name[0]) return NULL;
    uint64_t h = hash_name_fnv(name) % META_HASH_SIZE;
    meta_entry_t* entry = g_meta_hash[h];
    while (entry) {
        if (strcmp(entry->name, name) == 0) return entry;
        entry = entry->next;
    }
    return NULL;
}

static void free_metadata(void) {
    if (!g_meta_hash) return;
    for (int i = 0; i < META_HASH_SIZE; i++) {
        meta_entry_t* entry = g_meta_hash[i];
        while (entry) {
            meta_entry_t* next = entry->next;
            free(entry);
            entry = next;
        }
    }
    free(g_meta_hash);
    g_meta_hash = NULL;
}

// ============================================================
// Internal: TF-IDF word frequency boost
// ============================================================

#define WORD_HASH_SIZE 65536

typedef struct idf_entry {
    char word[64];
    float idf;
    struct idf_entry* next;
} idf_entry_t;

static idf_entry_t** g_idf_table = NULL;
static int g_idf_loaded = 0;

static unsigned int hash_word_simple(const char* word) {
    unsigned int h = 5381;
    while (*word) h = ((h << 5) + h) + *word++;
    return h % WORD_HASH_SIZE;
}

static void load_word_freq(const char* cache_dir) {
    if (g_idf_loaded) return;
    
    char path[512];
    snprintf(path, sizeof(path), "%s/word_freq.json", cache_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) return;
    
    g_idf_table = calloc(WORD_HASH_SIZE, sizeof(idf_entry_t*));
    if (!g_idf_table) { fclose(fp); return; }
    
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        char* key_start = strchr(line, '"');
        if (!key_start) continue;
        key_start++;
        char* key_end = strchr(key_start, '"');
        if (!key_end) continue;
        *key_end = '\0';
        
        if (key_start[0] == '_') continue;
        
        char* idf_p = strstr(key_end + 1, "\"idf\":");
        if (!idf_p) continue;
        float idf = atof(idf_p + 6);
        
        unsigned int h = hash_word_simple(key_start);
        idf_entry_t* entry = malloc(sizeof(idf_entry_t));
        if (entry) {
            strncpy(entry->word, key_start, sizeof(entry->word) - 1);
            entry->word[sizeof(entry->word) - 1] = '\0';
            entry->idf = idf;
            entry->next = g_idf_table[h];
            g_idf_table[h] = entry;
        }
    }
    
    fclose(fp);
    g_idf_loaded = 1;
}

static float get_idf(const char* word) {
    if (!g_idf_loaded || !g_idf_table) return 1.0f;
    unsigned int h = hash_word_simple(word);
    idf_entry_t* entry = g_idf_table[h];
    while (entry) {
        if (strcmp(entry->word, word) == 0) return entry->idf;
        entry = entry->next;
    }
    return 1.0f;
}

static void free_word_freq(void) {
    if (!g_idf_table) return;
    for (int i = 0; i < WORD_HASH_SIZE; i++) {
        idf_entry_t* entry = g_idf_table[i];
        while (entry) {
            idf_entry_t* next = entry->next;
            free(entry);
            entry = next;
        }
    }
    free(g_idf_table);
    g_idf_table = NULL;
    g_idf_loaded = 0;
}

// ============================================================
// Internal: Call graph / caller count boost
// ============================================================

#define CALLGRAPH_HASH_SIZE 65536

typedef struct caller_node {
    char name[256];
    struct caller_node* next;
} caller_node_t;

typedef struct callgraph_entry {
    char func_name[256];
    caller_node_t* callers;
    int caller_count;
    struct callgraph_entry* next;
} callgraph_entry_t;

static callgraph_entry_t** g_call_graph = NULL;
static int g_callgraph_loaded = 0;

static uint64_t hash_callgraph(const char* name) {
    uint64_t h = 0xcbf29ce484222325;
    for (const char* p = name; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 0x100000001b3;
    }
    return h % CALLGRAPH_HASH_SIZE;
}

static void load_call_graph(const char* cache_dir) {
    if (g_callgraph_loaded) return;
    
    char path[512];
    snprintf(path, sizeof(path), "%s/call_graph.json", cache_dir);
    FILE* fp = fopen(path, "r");
    if (!fp) return;
    
    g_call_graph = calloc(CALLGRAPH_HASH_SIZE, sizeof(callgraph_entry_t*));
    if (!g_call_graph) { fclose(fp); return; }
    
    char line[131072];
    while (fgets(line, sizeof(line), fp)) {
        char* key_start = strchr(line, '"');
        if (!key_start) continue;
        key_start++;
        char* key_end = strchr(key_start, '"');
        if (!key_end) continue;
        *key_end = '\0';
        
        char func_name[256];
        strncpy(func_name, key_start, sizeof(func_name) - 1);
        func_name[sizeof(func_name) - 1] = '\0';
        
        char* array_start = strchr(key_end + 1, '[');
        if (!array_start) continue;
        array_start++;
        
        uint64_t h = hash_callgraph(func_name);
        callgraph_entry_t* entry = g_call_graph[h];
        while (entry) {
            if (strcmp(entry->func_name, func_name) == 0) break;
            entry = entry->next;
        }
        
        if (!entry) {
            entry = calloc(1, sizeof(callgraph_entry_t));
            if (entry) {
                strncpy(entry->func_name, func_name, sizeof(entry->func_name) - 1);
                entry->func_name[sizeof(entry->func_name) - 1] = '\0';
                entry->next = g_call_graph[h];
                g_call_graph[h] = entry;
            }
        }
        
        char* p = array_start;
        while (*p && *p != ']') {
            if (*p == '"') {
                p++;
                char caller_name[256];
                int i = 0;
                while (*p && *p != '"' && i < 255) {
                    caller_name[i++] = *p++;
                }
                caller_name[i] = '\0';
                if (*p == '"') p++;
                
                if (entry && caller_name[0]) {
                    caller_node_t* node = malloc(sizeof(caller_node_t));
                    if (node) {
                        strncpy(node->name, caller_name, sizeof(node->name) - 1);
                        node->name[sizeof(node->name) - 1] = '\0';
                        node->next = entry->callers;
                        entry->callers = node;
                        entry->caller_count++;
                    }
                }
            } else {
                p++;
            }
        }
    }
    
    fclose(fp);
    g_callgraph_loaded = 1;
}

static int get_caller_count(const char* func_name) {
    if (!g_callgraph_loaded || !g_call_graph) return 0;
    uint64_t h = hash_callgraph(func_name);
    callgraph_entry_t* entry = g_call_graph[h];
    while (entry) {
        if (strcmp(entry->func_name, func_name) == 0) return entry->caller_count;
        entry = entry->next;
    }
    return 0;
}

static void free_call_graph(void) {
    if (!g_call_graph) return;
    for (int i = 0; i < CALLGRAPH_HASH_SIZE; i++) {
        callgraph_entry_t* entry = g_call_graph[i];
        while (entry) {
            caller_node_t* node = entry->callers;
            while (node) {
                caller_node_t* next = node->next;
                free(node);
                node = next;
            }
            callgraph_entry_t* next_entry = entry->next;
            free(entry);
            entry = next_entry;
        }
    }
    free(g_call_graph);
    g_call_graph = NULL;
    g_callgraph_loaded = 0;
}

// ============================================================
// Internal: Boost functions
// ============================================================

static float keyword_boost(const char* query, const char* name) {
    char qcopy[1024];
    strncpy(qcopy, query, sizeof(qcopy) - 1);
    qcopy[sizeof(qcopy) - 1] = '\0';
    
    float boost = 0.0f;
    char* token = strtok(qcopy, " _-.,;:!?()[]{}<>\"'\t\n");
    while (token) {
        if (strlen(token) >= 3) {
            const char* p = name;
            size_t tlen = strlen(token);
            while (*p) {
                if (strncasecmp(p, token, tlen) == 0) {
                    float idf = get_idf(token);
                    float weight = 0.01f + (idf / 9.0f) * 0.07f;
                    boost += weight;
                    break;
                }
                p++;
            }
        }
        token = strtok(NULL, " _-.,;:!?()[]{}<>\"'\t\n");
    }
    
    return boost > 0.3f ? 0.3f : boost;
}

static float caller_boost(const char* name) {
    int caller_count = get_caller_count(name);
    if (caller_count > 0) {
        float boost = logf(caller_count + 1) * 0.02f;
        return boost > 0.1f ? 0.1f : boost;
    }
    return 0.0f;
}

// ============================================================
// Internal: HNSW search
// ============================================================

typedef struct {
    char name[VE_MAX_NAME_LEN];
    float score;
} ve_search_result_t;

static int cmp_result(const void* a, const void* b) {
    float diff = ((ve_search_result_t*)b)->score - ((ve_search_result_t*)a)->score;
    return (diff > 0) ? 1 : (diff < 0) ? -1 : 0;
}

static int search_hnsw(ve_source_t* source, const float* query_vec, int top_k,
                       const char* query_text, ve_search_result_t* results,
                       const vector_search_opts_t* opts) {
    if (!source->hnsw_file[0]) return 0;

    // HNSW 文件可能有数 GB；只在第一次 query 时加载并常驻，避免每次 query
    // 都 malloc/read/deserialize 几 GB（内核索引下这是 20s+ 和 OOM 的主要来源）。
    int debug = getenv("LITE_CS_DEBUG") != NULL;
    clock_t load_t0 = clock();
    if (!source->hnsw) {
        FILE* fp = fopen(source->hnsw_file, "rb");
        if (!fp) return 0;

        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        fseek(fp, 0, SEEK_SET);

        void* buf = malloc(size);
        if (!buf) { fclose(fp); return 0; }
        if (fread(buf, 1, size, fp) != (size_t)size) {
            free(buf); fclose(fp); return 0;
        }
        fclose(fp);

        source->hnsw = hnsw_deserialize(buf, size);
        free(buf);
        if (!source->hnsw) return 0;
    }

    double load_ms = (double)(clock() - load_t0) * 1000.0 / CLOCKS_PER_SEC;
    hnsw_index_t* hnsw = source->hnsw;
    size_t* ids = NULL;
    float* scores = NULL;
    clock_t search_t0 = clock();
    size_t found = hnsw_search(hnsw, query_vec, top_k * 4, &ids, &scores);
    double search_ms = (double)(clock() - search_t0) * 1000.0 / CLOCKS_PER_SEC;
    if (debug) fprintf(stderr, "[ve] hnsw load=%.0fms search=%.0fms found=%zu\n",
                       load_ms, search_ms, found);
    
    if (!source->names && mmap_source(source) < 0) {
        free(ids); free(scores);
        return 0;
    }
    
    // Collect valid results first
    typedef struct {
        char name[VE_MAX_NAME_LEN];
        float score;
    } temp_result_t;
    temp_result_t* temp = malloc(found * sizeof(temp_result_t));
    int temp_count = 0;
    
    for (size_t i = 0; i < found; i++) {
        if (ids[i] >= source->count) continue;
        const char* name = source->names[ids[i]];
        if (strncmp(name, "__anon", 6) == 0) continue;
        
        float sim = scores[i];
        if (isnan(sim)) continue;
        
        // Temperature scaling: gently stretch similarity scores
        // HNSW cosine similarity for code embeddings is often clustered in [0.45, 0.75]
        // Apply mild S-curve to improve discrimination without destroying ranking
        float centered = (sim - 0.5f) * 2.0f;  // map [0,1] to [-1,1], baseline at 0.5
        float sharpened = tanhf(centered * 1.5f) * 0.5f + 0.5f;  // gentle S-curve
        sim = sharpened;
        
        // Keyword boost
        if (query_text && query_text[0] && opts && opts->use_keyword_boost) {
            sim += keyword_boost(query_text, name);
            if (sim > 1.0f) sim = 1.0f;
        }
        
        // Caller boost
        if (opts && opts->use_caller_boost) {
            sim += caller_boost(name);
            if (sim > 1.0f) sim = 1.0f;
        }
        
        // Lookup metadata once (noise penalty + filters 共用)
        meta_entry_t* meta = NULL;
        if (opts) {
            meta = lookup_meta(name);
        }
        
        // Noise penalty: 测试/自测路径降权 15%（实测：抽象算法查询曾被
        // kasan_test_c / locktorture / torture_* 噪音顶到前排，盖过真实核心函数）
        if (meta && meta->file) {
            const char* fp = meta->file;
            if (strstr(fp, "/test") || strstr(fp, "torture") || strstr(fp, "kunit")
                || strstr(fp, "selftest") || strstr(fp, "/tools/testing")
                || strstr(fp, "mock") || strstr(fp, "fuzzer")) {
                sim *= 0.85f;
            }
        }
        
        // Apply filters using metadata
        if (opts && (opts->kind_filter || opts->lang_filter || opts->file_filter)) {
            if (!meta) continue;
            if (opts->kind_filter && strcasecmp(meta->kind, opts->kind_filter) != 0) continue;
            if (opts->lang_filter && strcasecmp(meta->language, opts->lang_filter) != 0) continue;
            if (opts->file_filter && !strstr(meta->file, opts->file_filter)) continue;
        }
        
        strncpy(temp[temp_count].name, name, VE_MAX_NAME_LEN - 1);
        temp[temp_count].name[VE_MAX_NAME_LEN - 1] = '\0';
        temp[temp_count].score = sim;
        temp_count++;
    }
    
    // Sort by score descending
    for (int i = 0; i < temp_count - 1; i++) {
        for (int j = i + 1; j < temp_count; j++) {
            if (temp[j].score > temp[i].score) {
                temp_result_t t = temp[i];
                temp[i] = temp[j];
                temp[j] = t;
            }
        }
    }
    
    int count = 0;
    for (int i = 0; i < temp_count && count < top_k; i++) {
        // 同一 name 的 Part 2..5 / 多个同名定义只保留最高分的一条。
        int duplicate = 0;
        for (int j = 0; j < count; j++) {
            if (strcmp(results[j].name, temp[i].name) == 0) { duplicate = 1; break; }
        }
        if (duplicate) continue;
        strncpy(results[count].name, temp[i].name, VE_MAX_NAME_LEN - 1);
        results[count].name[VE_MAX_NAME_LEN - 1] = '\0';
        results[count].score = temp[i].score;
        count++;
    }
    
    free(temp);
    
    free(ids);
    free(scores);
    return count;
}

// ============================================================
// Vector engine structure
// ============================================================

struct vector_engine {
    char cache_dir[512];
    char model[32];
    ve_source_t sources[MAX_NAMESPACES];
    int num_sources;
    int meta_loaded;
    int word_freq_loaded;
    int callgraph_loaded;
    
    // Cached embedder for query encoding (avoids reloading model on every search)
    onnx_embedder_t* embedder;
    char embedder_model_path[512];
    char embedder_vocab_path[512];
};

// ============================================================
// Public API
// ============================================================

vector_engine_t* vector_engine_open(const char* cache_dir, const char* model) {
    vector_engine_t* engine = calloc(1, sizeof(vector_engine_t));
    if (!engine) {
        set_error("Out of memory");
        return NULL;
    }
    
    strncpy(engine->cache_dir, cache_dir, sizeof(engine->cache_dir) - 1);
    strncpy(engine->model, model ? model : "jina", sizeof(engine->model) - 1);
    
    engine->num_sources = discover_sources(cache_dir, engine->sources, MAX_NAMESPACES);
    if (engine->num_sources == 0) {
        set_error("No vector files found");
        free(engine);
        return NULL;
    }
    
    engine->meta_loaded = (load_metadata(cache_dir) == 0);
    load_word_freq(cache_dir);
    engine->word_freq_loaded = g_idf_loaded;
    load_call_graph(cache_dir);
    engine->callgraph_loaded = g_callgraph_loaded;
    
    const char* model_home = getenv("LITE_CS_MODEL_DIR");
    if (!model_home || !*model_home) model_home = "/opt/models";

    // Pre-initialize embedder to avoid reload on every search
    if (strcmp(engine->model, "jina") == 0) {
        snprintf(engine->embedder_model_path, sizeof(engine->embedder_model_path),
                 "%s/jina-embeddings-v2-base-code/model.onnx", model_home);
        snprintf(engine->embedder_vocab_path, sizeof(engine->embedder_vocab_path),
                 "%s/jina-embeddings-v2-base-code/vocab.json", model_home);
        engine->embedder = onnx_embedder_init(engine->embedder_model_path, engine->embedder_vocab_path, 512, VE_DIM);
    } else {
        snprintf(engine->embedder_model_path, sizeof(engine->embedder_model_path),
                 "%s/all-mpnet-base-v2/model.onnx", model_home);
        snprintf(engine->embedder_vocab_path, sizeof(engine->embedder_vocab_path),
                 "%s/all-mpnet-base-v2/vocab.txt", model_home);
        engine->embedder = onnx_embedder_init(engine->embedder_model_path, engine->embedder_vocab_path, 128, VE_DIM);
    }
    
    if (!engine->embedder) {
        fprintf(stderr, "[VECTOR] Warning: Failed to preload embedder (%s). Will retry on first search.\n", onnx_embedder_error());
    }
    
    return engine;
}

void vector_engine_close(vector_engine_t* engine) {
    if (!engine) return;
    for (int i = 0; i < engine->num_sources; i++) {
        munmap_source(&engine->sources[i]);
    }
    if (engine->embedder) {
        onnx_embedder_free(engine->embedder);
        engine->embedder = NULL;
    }
    free_metadata();
    free_word_freq();
    free_call_graph();
    free(engine);
}

const char* vector_engine_error(void) {
    return g_error_msg;
}

size_t vector_engine_count(vector_engine_t* engine) {
    if (!engine) return 0;
    size_t total = 0;
    for (int i = 0; i < engine->num_sources; i++) {
        total += engine->sources[i].count;
    }
    return total;
}

int vector_engine_search(vector_engine_t* engine, const char* query, 
                         int top_k, vector_result_t* results) {
    return vector_engine_search_ns(engine, query, top_k, NULL, results);
}

int vector_engine_search_ns(vector_engine_t* engine, const char* query,
                            int top_k, const char* namespace,
                            vector_result_t* results) {
    vector_search_opts_t opts = {0};
    return vector_engine_search_ex(engine, query, top_k, namespace, &opts, results);
}

int vector_engine_search_ex(vector_engine_t* engine, const char* query,
                            int top_k, const char* namespace,
                            const vector_search_opts_t* opts,
                            vector_result_t* results) {
    if (!engine || !query || !results || top_k <= 0) {
        set_error("Invalid arguments");
        return -1;
    }
    
    // Encode query using cached embedder (initialized in vector_engine_open)
    float query_vec[VE_DIM];
    onnx_embedder_t* embedder = engine->embedder;
    
    if (!embedder) {
        // Lazy initialization if pre-load failed
        if (strcmp(engine->model, "jina") == 0) {
            embedder = onnx_embedder_init(
                engine->embedder_model_path[0] ? engine->embedder_model_path :
                    "/opt/models/jina-embeddings-v2-base-code/model.onnx",
                engine->embedder_vocab_path[0] ? engine->embedder_vocab_path :
                    "/opt/models/jina-embeddings-v2-base-code/vocab.json",
                512, VE_DIM
            );
        } else {
            embedder = onnx_embedder_init(
                engine->embedder_model_path[0] ? engine->embedder_model_path :
                    "/opt/models/all-mpnet-base-v2/model.onnx",
                engine->embedder_vocab_path[0] ? engine->embedder_vocab_path :
                    "/opt/models/all-mpnet-base-v2/vocab.txt",
                128, VE_DIM
            );
        }
        if (!embedder) {
            set_error(onnx_embedder_error());
            return -1;
        }
        engine->embedder = embedder;
    }
    
    if (onnx_embedder_encode(embedder, query, query_vec) != 0) {
        set_error("Failed to encode query");
        return -1;
    }
    
    // Search all matching sources
    ve_search_result_t* raw_results = malloc(top_k * 4 * sizeof(ve_search_result_t));
    if (!raw_results) {
        set_error("Out of memory");
        return -1;
    }
    
    int total_found = 0;
    for (int i = 0; i < engine->num_sources; i++) {
        ve_source_t* s = &engine->sources[i];
        
        // Filter by namespace if specified
        if (namespace && namespace[0]) {
            int ns_match = (strcmp(s->namespace, namespace) == 0);
            if (!ns_match) ns_match = strstr(s->namespace, namespace) != NULL;
            if (!ns_match) ns_match = strstr(namespace, s->namespace) != NULL;
            
            // Allow /code/X to match /code/local/X (and vice versa)
            // Supports nested namespaces: /code/owner/repo matches /code/local/repo
            if (!ns_match && strncmp(s->namespace, "/code/local/", 12) == 0) {
                const char* local_name = s->namespace + 12;
                size_t name_len = strlen(local_name);
                size_t ns_len = strlen(namespace);
                if (ns_len > name_len + 1 &&
                    namespace[ns_len - name_len - 1] == '/' &&
                    strcmp(namespace + ns_len - name_len, local_name) == 0) {
                    ns_match = 1;
                }
            }
            if (!ns_match && strncmp(namespace, "/code/", 6) == 0) {
                const char* ns_rest = namespace + 6;
                const char* last_slash = strrchr(ns_rest, '/');
                const char* last_comp = last_slash ? last_slash + 1 : ns_rest;
                char local_check[256];
                snprintf(local_check, sizeof(local_check), "/code/local/%s", last_comp);
                ns_match = (strcmp(s->namespace, local_check) == 0);
            }
            
            if (!ns_match) continue;
        }
        
        // Filter by model
        if (strcmp(s->model, engine->model) != 0) continue;
        
        int n = search_hnsw(s, query_vec, top_k, query, &raw_results[total_found], opts);
        total_found += n;
        if (total_found >= top_k * 4) break;
    }
    
    // Sort by score
    if (total_found > 0) {
        qsort(raw_results, total_found, sizeof(ve_search_result_t), cmp_result);
    }
    
    // Fill output
    int count = 0;
    for (int i = 0; i < total_found && count < top_k; i++) {
        meta_entry_t* meta = lookup_meta(raw_results[i].name);
        if (!meta && !engine->meta_loaded) {
            strncpy(results[count].name, raw_results[i].name, VE_MAX_NAME_LEN - 1);
            results[count].score = raw_results[i].score;
            count++;
            continue;
        }
        if (!meta) continue;
        
        strncpy(results[count].namespace, namespace ? namespace : "", 255);
        strncpy(results[count].name, meta->name, VE_MAX_NAME_LEN - 1);
        strncpy(results[count].file, meta->file, VE_MAX_FILE_LEN - 1);
        strncpy(results[count].kind, meta->kind, 31);
        strncpy(results[count].language, meta->language, 31);
        strncpy(results[count].signature, meta->signature, VE_MAX_SIGNATURE_LEN - 1);
        strncpy(results[count].content, meta->content, VE_MAX_CONTENT_LEN - 1);
        results[count].line_start = meta->line_start;
        results[count].line_end = meta->line_end;
        results[count].score = raw_results[i].score;
        count++;
    }
    
    free(raw_results);
    return count;
}
