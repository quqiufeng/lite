#include "cache_internal.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ====== 向量索引操作 ======

int cache_vector_index_init(cache_t* cache) {
    if (!cache) return CACHE_ERR_INVAL;
    
    cache->vector_index.entries = NULL;
    cache->vector_index.count = 0;
    cache->vector_index.capacity = 0;
    cache->vector_index.hnsw = NULL;
    cache->vector_index.use_hnsw = 0;
    return CACHE_OK;
}

void cache_vector_index_destroy(cache_t* cache) {
    if (!cache) return;
    
    free(cache->vector_index.entries);
    cache->vector_index.entries = NULL;
    cache->vector_index.count = 0;
    cache->vector_index.capacity = 0;
    
    if (cache->vector_index.hnsw) {
        hnsw_destroy(cache->vector_index.hnsw);
        cache->vector_index.hnsw = NULL;
    }
    cache->vector_index.use_hnsw = 0;
}

// 在pool中分配向量存储空间
static size_t alloc_vector_data(cache_t* cache, const float* vector, size_t dim) {
    size_t data_size = sizeof(float) * dim;
    size_t offset = pool_alloc_offset(&cache->pool, data_size);
    if (!offset) return 0;
    
    float* dest = (float*)CACHE_PTR(cache, offset);
    memcpy(dest, vector, data_size);
    return offset;
}

// 从 pool 读取向量数据
static const float* get_vector_data(cache_t* cache, size_t vector_offset) {
    return (const float*)CACHE_PTR(cache, vector_offset);
}

// 检查是否应该启用 HNSW
static void maybe_enable_hnsw(cache_t* cache) {
    if (cache->vector_index.use_hnsw) return;
    if (cache->vector_index.count < CACHE_HNSW_THRESHOLD) return;
    
    // 确定维度（使用第一个有效向量的维度）
    size_t dim = 0;
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        if (cache->vector_index.entries[i].dim > 0) {
            dim = cache->vector_index.entries[i].dim;
            break;
        }
    }
    if (dim == 0) return;
    
    // 创建 HNSW
    hnsw_index_t* hnsw = hnsw_create(dim);
    if (!hnsw) return;
    
    // 批量插入所有现有向量
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        cache_vector_entry_t* e = &cache->vector_index.entries[i];
        const float* vec = get_vector_data(cache, e->vector_offset);
        hnsw_insert(hnsw, e->entry_offset, vec);
    }
    
    cache->vector_index.hnsw = hnsw;
    cache->vector_index.use_hnsw = 1;
}

// 添加向量到索引
int cache_vector_index_add(cache_t* cache, size_t entry_offset, const float* vector, size_t dim) {
    if (!cache || !vector || dim == 0 || dim > CACHE_MAX_VECTOR_DIM) return CACHE_ERR_INVAL;
    
    // 检查是否已存在（更新）
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        if (cache->vector_index.entries[i].entry_offset == entry_offset) {
            // 更新现有向量
            size_t new_offset = alloc_vector_data(cache, vector, dim);
            if (!new_offset) return CACHE_ERR_NOMEM;
            
            cache->vector_index.entries[i].vector_offset = new_offset;
            cache->vector_index.entries[i].dim = dim;
            
            // 如果 HNSW 已启用，更新 HNSW 中的向量
            if (cache->vector_index.use_hnsw && cache->vector_index.hnsw) {
                hnsw_remove(cache->vector_index.hnsw, entry_offset);
                hnsw_insert(cache->vector_index.hnsw, entry_offset, vector);
            }
            
            return CACHE_OK;
        }
    }
    
    // 分配新条目
    if (cache->vector_index.count >= cache->vector_index.capacity) {
        size_t new_cap = cache->vector_index.capacity == 0 ? 16 : cache->vector_index.capacity * 2;
        cache_vector_entry_t* new_entries = realloc(cache->vector_index.entries, 
                                                      sizeof(cache_vector_entry_t) * new_cap);
        if (!new_entries) return CACHE_ERR_NOMEM;
        cache->vector_index.entries = new_entries;
        cache->vector_index.capacity = new_cap;
    }
    
    // 分配向量数据
    size_t vector_offset = alloc_vector_data(cache, vector, dim);
    if (!vector_offset) return CACHE_ERR_NOMEM;
    
    cache_vector_entry_t* entry = &cache->vector_index.entries[cache->vector_index.count];
    entry->entry_offset = entry_offset;
    entry->vector_offset = vector_offset;
    entry->dim = dim;
    cache->vector_index.count++;
    
    // 如果 HNSW 已启用，插入到 HNSW
    if (cache->vector_index.use_hnsw && cache->vector_index.hnsw) {
        hnsw_insert(cache->vector_index.hnsw, entry_offset, vector);
    }
    
    // 检查是否需要启用 HNSW
    maybe_enable_hnsw(cache);
    
    return CACHE_OK;
}

// 从索引中移除向量
void cache_vector_index_remove(cache_t* cache, size_t entry_offset) {
    if (!cache) return;
    
    // 从 HNSW 中删除
    if (cache->vector_index.use_hnsw && cache->vector_index.hnsw) {
        hnsw_remove(cache->vector_index.hnsw, entry_offset);
    }
    
    // 从 entries 数组中删除
    size_t write = 0;
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        if (cache->vector_index.entries[i].entry_offset != entry_offset) {
            cache->vector_index.entries[write++] = cache->vector_index.entries[i];
        }
    }
    cache->vector_index.count = write;
}

// 余弦相似度计算 (-1 to 1, we normalize to 0 to 1)
float cache_vector_cosine_similarity(const float* a, const float* b, size_t dim) {
    if (!a || !b || dim == 0) return -1.0f;
    
    double dot = 0.0;
    double norm_a = 0.0;
    double norm_b = 0.0;
    
    for (size_t i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }
    
    if (norm_a == 0.0 || norm_b == 0.0) return 0.0f;
    
    double cosine = dot / (sqrt(norm_a) * sqrt(norm_b));
    // 归一化到 [0, 1]（假设向量已归一化，cosine范围[-1,1]，映射到[0,1]）
    return (float)((cosine + 1.0) / 2.0);
}

// 重建向量索引（扫描所有entry）
void cache_vector_index_rebuild(cache_t* cache) {
    if (!cache) return;
    
    // 清空现有索引
    free(cache->vector_index.entries);
    cache->vector_index.entries = NULL;
    cache->vector_index.count = 0;
    cache->vector_index.capacity = 0;
    
    if (cache->vector_index.hnsw) {
        hnsw_destroy(cache->vector_index.hnsw);
        cache->vector_index.hnsw = NULL;
    }
    cache->vector_index.use_hnsw = 0;
    
    uint64_t now = cache_now_ms();
    size_t offset = CACHE_HEADER_SIZE;
    
    while (offset + sizeof(cache_entry_header_t) <= cache->pool.used) {
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
        
        // 跳过无效entry
        if (h->key_len == 0 || h->key_len > CACHE_MAX_KEY_LEN ||
            h->value_len > CACHE_MAX_VALUE_LEN ||
            (h->flags & CACHE_ENTRY_DELETED)) {
            offset += MYDB_ALIGN;
            continue;
        }
        
        // 检查是否过期
        if (h->expire_at > 0 && h->expire_at < now) {
            offset += cache_entry_total_size(h);
            continue;
        }
        
        // 检查value中是否包含向量元数据
        const char* value = (const char*)CACHE_PTR(cache, offset + sizeof(cache_entry_header_t) + h->key_len + 1);
        
        // 安全解析向量元数据：要求 value 以 '{"__vector_offset":' 开头
        // 格式: {"__vector_offset":N,"__vector_dim":N,"content":...}
        if (value[0] == '{' && strncmp(value + 1, "\"__vector_offset\":" , 18) == 0) {
            const char* p = value + 19;  // 跳过 {"__vector_offset":
            
            // 解析 offset
            size_t vector_offset = 0;
            while (*p >= '0' && *p <= '9') {
                vector_offset = vector_offset * 10 + (*p - '0');
                p++;
            }
            
            // 跳过 ",\"__vector_dim\":"
            if (*p == ',' && strncmp(p + 1, "\"__vector_dim\":" , 15) == 0) {
                p += 16;  // 跳过 ,"__vector_dim":
                
                // 解析 dim
                size_t vector_dim = 0;
                while (*p >= '0' && *p <= '9') {
                    vector_dim = vector_dim * 10 + (*p - '0');
                    p++;
                }
                
                if (vector_offset > 0 && vector_dim > 0 && vector_dim <= CACHE_MAX_VECTOR_DIM) {
                    // 验证向量数据在 pool 范围内
                    size_t vector_end = vector_offset + sizeof(float) * vector_dim;
                    if (vector_end <= cache->pool.used) {
                        // 添加到索引
                        if (cache->vector_index.count >= cache->vector_index.capacity) {
                            size_t new_cap = cache->vector_index.capacity == 0 ? 16 : cache->vector_index.capacity * 2;
                            cache_vector_entry_t* new_entries = realloc(cache->vector_index.entries,
                                                                          sizeof(cache_vector_entry_t) * new_cap);
                            if (new_entries) {
                                cache->vector_index.entries = new_entries;
                                cache->vector_index.capacity = new_cap;
                            }
                        }
                        
                        if (cache->vector_index.count < cache->vector_index.capacity) {
                            cache_vector_entry_t* entry = &cache->vector_index.entries[cache->vector_index.count];
                            entry->entry_offset = offset;
                            entry->vector_offset = vector_offset;
                            entry->dim = vector_dim;
                            cache->vector_index.count++;
                        }
                    }
                }
            }
        }
        
        offset += cache_entry_total_size(h);
    }
    
    // 重建后检查是否需要启用 HNSW
    maybe_enable_hnsw(cache);
}

// ====== 公共 API 实现 ======

int cache_set_vector(cache_t* cache, const char* key, const char* value,
                     const float* vector, size_t dim, uint64_t ttl_ms) {
    if (!cache || !key || !value || !vector || dim == 0 || dim > CACHE_MAX_VECTOR_DIM) {
        return CACHE_ERR_INVAL;
    }
    
    // 分配向量数据到 pool（先分配，确保成功后再写入 value）
    size_t vector_offset = alloc_vector_data(cache, vector, dim);
    if (!vector_offset) return CACHE_ERR_NOMEM;
    
    // 构建包含向量元数据的 value
    size_t meta_len = snprintf(NULL, 0, "{\"__vector_offset\":%zu,\"__vector_dim\":%zu,\"content\":"
                                , vector_offset, dim);
    size_t value_len = strlen(value);
    size_t total_value_len = meta_len + value_len + 2;  // +2 for closing }
    
    char* new_value = malloc(total_value_len + 1);
    if (!new_value) return CACHE_ERR_NOMEM;
    
    snprintf(new_value, total_value_len + 1,
             "{\"__vector_offset\":%zu,\"__vector_dim\":%zu,\"content\":%s}",
             vector_offset, dim, value);
    
    // 单次写入 entry（含向量元数据）
    int ret = cache_set(cache, key, new_value, ttl_ms);
    free(new_value);
    
    if (ret == CACHE_OK) {
        size_t entry_offset = cache_hash_lookup(cache, key, strlen(key));
        if (entry_offset) {
            cache_vector_index_add(cache, entry_offset, vector, dim);
        }
    }
    // 如果 cache_set 失败，向量数据仍在 pool 中（孤儿数据），
    // 将在下次 compact 时回收。这是 pool 分配器的限制。
    
    return ret;
}

const float* cache_get_vector(cache_t* cache, const char* key, size_t* out_dim) {
    if (!cache || !key || !out_dim) return NULL;
    *out_dim = 0;
    
    size_t key_len = strlen(key);
    size_t entry_offset = cache_hash_lookup(cache, key, key_len);
    if (!entry_offset) return NULL;
    
    // 查找向量索引
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        if (cache->vector_index.entries[i].entry_offset == entry_offset) {
            *out_dim = cache->vector_index.entries[i].dim;
            return (float*)CACHE_PTR(cache, cache->vector_index.entries[i].vector_offset);
        }
    }
    
    return NULL;
}

// 用于qsort的比较结构
typedef struct {
    size_t entry_offset;
    float score;
} vector_score_t;

static int compare_vector_score(const void* a, const void* b) {
    float diff = ((vector_score_t*)b)->score - ((vector_score_t*)a)->score;
    if (diff > 0) return 1;
    if (diff < 0) return -1;
    return 0;
}

// ====== Hybrid Scoring (Semantic + Title + Keyword + Position) ======

// Count how many query words appear in text (case-insensitive)
static int count_keyword_matches(const char* query, const char* text) {
    if (!query || !text) return 0;
    
    int matches = 0;
    char query_lower[256];
    char text_lower[1024];
    
    // Simple lowercase copy
    int i = 0;
    while (query[i] && i < 255) {
        query_lower[i] = tolower((unsigned char)query[i]);
        i++;
    }
    query_lower[i] = '\0';
    
    i = 0;
    while (text[i] && i < 1023) {
        text_lower[i] = tolower((unsigned char)text[i]);
        i++;
    }
    text_lower[i] = '\0';
    
    // Check each word in query (using strtok_r for reentrancy)
    char* q = query_lower;
    char* saveptr = NULL;
    char* word;
    while ((word = strtok_r(q, " \t\n\r", &saveptr)) != NULL) {
        q = NULL;  // For subsequent calls
        if (strlen(word) >= 2 && strstr(text_lower, word)) {
            matches++;
        }
    }

    return matches;
}

// Extract paragraph index from key like ".../content/p0123"
static int get_paragraph_index(const char* key) {
    const char* p = strstr(key, "/content/p");
    if (!p) return 999;  // Not a paragraph, give low priority
    return atoi(p + 10);
}

// Calculate hybrid score
static double calculate_hybrid_score(cache_t* cache, size_t entry_offset,
                                     double semantic_score, const char* query_text) {
    size_t key_len, value_len;
    const char* key = entry_key(cache, entry_offset, &key_len);
    const char* value = entry_value(cache, entry_offset, &value_len);
    
    double score = semantic_score;
    
    // 1. Title bonus: exact key match or title entries get higher weight
    // Use strict path segment matching to avoid false positives like "my-title-guide"
    size_t key_len_actual = strlen(key);
    if ((key_len_actual >= 6 && strcmp(key + key_len_actual - 6, "/title") == 0) ||
        strstr(key, "/title/") != NULL) {
        score *= 1.5;  // Title entries are more important
    } else if (strstr(key, "/_meta/") != NULL) {
        score *= 1.3;  // Metadata is also important
    }
    
    // 2. Keyword frequency bonus
    if (query_text && value) {
        int keyword_matches = count_keyword_matches(query_text, value);
        if (keyword_matches > 0) {
            // Each matching keyword adds up to 10% bonus
            double keyword_bonus = 1.0 + (keyword_matches * 0.1);
            if (keyword_bonus > 1.5) keyword_bonus = 1.5;  // Cap at 50%
            score *= keyword_bonus;
        }
    }
    
    // 3. Position bonus: earlier paragraphs in a chapter are more likely to be summaries
    int para_idx = get_paragraph_index(key);
    if (para_idx < 3) {
        score *= 1.1;  // First 3 paragraphs get 10% bonus
    }
    
    return score;
}

int cache_search_vector(cache_t* cache, const float* query_vector, size_t dim,
                        int top_k, double min_score,
                        cache_search_options_t* options,
                        cache_result_t** out_results, size_t* out_count) {
    if (!cache || !query_vector || dim == 0 || !out_results || !out_count) {
        return CACHE_ERR_INVAL;
    }
    
    *out_results = NULL;
    *out_count = 0;
    
    if (cache->vector_index.count == 0) return CACHE_OK;  // 无向量数据
    
    uint64_t now = cache_now_ms();
    int max_results = top_k > 0 ? top_k : 10;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    // 如果启用了 HNSW 且数据量足够，使用近似搜索
    if (cache->vector_index.use_hnsw && cache->vector_index.hnsw) {
        size_t* ids = NULL;
        float* scores = NULL;
        
        // 扩大搜索范围，然后过滤
        int ef = (max_results > hnsw_get_ef_search(cache->vector_index.hnsw)) ? 
                 max_results : hnsw_get_ef_search(cache->vector_index.hnsw);
        hnsw_set_ef_search(cache->vector_index.hnsw, ef);
        
        size_t found = hnsw_search(cache->vector_index.hnsw, query_vector, max_results * 2, &ids, &scores);
        
        if (found == 0) return CACHE_OK;
        
        // 过滤无效结果和 namespace，应用 min_score
        vector_score_t* valid_scores = malloc(sizeof(vector_score_t) * found);
        if (!valid_scores) {
            free(ids); free(scores);
            return CACHE_ERR_NOMEM;
        }
        
        size_t valid_count = 0;
        for (size_t i = 0; i < found; i++) {
            size_t entry_offset = ids[i];
            if (!entry_is_valid(cache, entry_offset, now)) continue;
            if (!ns_filter_match(cache, entry_offset, ns_filter)) continue;
            if (scores[i] < min_score) continue;
            
            valid_scores[valid_count].entry_offset = entry_offset;
            valid_scores[valid_count].score = scores[i];
            valid_count++;
        }
        
        free(ids);
        free(scores);
        
        if (valid_count == 0) {
            free(valid_scores);
            return CACHE_OK;
        }
        
        // Apply hybrid scoring (semantic + title + keyword + position)
        const char* query_text = options ? options->query_text : NULL;
        for (size_t i = 0; i < valid_count; i++) {
            valid_scores[i].score = calculate_hybrid_score(cache, valid_scores[i].entry_offset,
                                                           valid_scores[i].score, query_text);
        }
        
        // Re-sort by hybrid score
        qsort(valid_scores, valid_count, sizeof(vector_score_t), compare_vector_score);
        
        // 取前 top_k
        size_t result_count = valid_count < (size_t)max_results ? valid_count : (size_t)max_results;
        
        cache_result_t* results = malloc(sizeof(cache_result_t) * result_count);
        if (!results) {
            free(valid_scores);
            return CACHE_ERR_NOMEM;
        }
        
        for (size_t i = 0; i < result_count; i++) {
            size_t key_len, value_len;
            results[i].key = entry_key(cache, valid_scores[i].entry_offset, &key_len);
            results[i].value = entry_value(cache, valid_scores[i].entry_offset, &value_len);
            results[i].score = valid_scores[i].score;
        }
        
        free(valid_scores);
        
        *out_results = results;
        *out_count = result_count;
        return CACHE_OK;
    }
    
    // 暴力精确搜索（少量数据或 HNSW 未启用）
    vector_score_t* scores = malloc(sizeof(vector_score_t) * cache->vector_index.count);
    if (!scores) return CACHE_ERR_NOMEM;
    
    size_t score_count = 0;
    
    // 计算所有向量的相似度
    for (size_t i = 0; i < cache->vector_index.count; i++) {
        cache_vector_entry_t* entry = &cache->vector_index.entries[i];
        
        if (entry->dim != dim) continue;  // 维度不匹配
        if (!entry_is_valid(cache, entry->entry_offset, now)) continue;
        if (!ns_filter_match(cache, entry->entry_offset, ns_filter)) continue;
        
        float* vector_data = (float*)CACHE_PTR(cache, entry->vector_offset);
        float score = cache_vector_cosine_similarity(query_vector, vector_data, dim);
        
        if (score >= min_score) {
            scores[score_count].entry_offset = entry->entry_offset;
            scores[score_count].score = score;
            score_count++;
        }
    }
    
    if (score_count == 0) {
        free(scores);
        return CACHE_OK;
    }
    
    // Apply hybrid scoring
    const char* query_text = options ? options->query_text : NULL;
    for (size_t i = 0; i < score_count; i++) {
        scores[i].score = calculate_hybrid_score(cache, scores[i].entry_offset,
                                                  scores[i].score, query_text);
    }
    
    // 按混合评分排序（降序）
    qsort(scores, score_count, sizeof(vector_score_t), compare_vector_score);
    
    // 取前top_k
    size_t result_count = score_count < (size_t)max_results ? score_count : (size_t)max_results;
    
    cache_result_t* results = malloc(sizeof(cache_result_t) * result_count);
    if (!results) {
        free(scores);
        return CACHE_ERR_NOMEM;
    }
    
    for (size_t i = 0; i < result_count; i++) {
        size_t key_len, value_len;
        results[i].key = entry_key(cache, scores[i].entry_offset, &key_len);
        results[i].value = entry_value(cache, scores[i].entry_offset, &value_len);
        results[i].score = scores[i].score;
    }
    
    free(scores);
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}
