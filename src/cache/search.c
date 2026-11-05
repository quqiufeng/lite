#include "cache_internal.h"
#include <string.h>
#include <stdlib.h>
#include <regex.h>
#include <stdio.h>
#include <ctype.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ====== 辅助函数 ======

// 从 entry_offset 读取 key
const char* entry_key(cache_t* cache, size_t offset, size_t* key_len_out) {
    cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
    if (key_len_out) *key_len_out = h->key_len;
    return (const char*)CACHE_PTR(cache, offset + sizeof(cache_entry_header_t));
}

// 从 entry_offset 读取 value
// Layout: [header][key(key_len+1)][value(value_len+1)]
const char* entry_value(cache_t* cache, size_t offset, size_t* value_len_out) {
    cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
    if (value_len_out) *value_len_out = h->value_len;
    return (const char*)CACHE_PTR(cache, offset + sizeof(cache_entry_header_t) + h->key_len + 1);
}

// 检查 entry 是否有效（未删除、未过期）
int entry_is_valid(cache_t* cache, size_t offset, uint64_t now) {
    cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
    if (h->flags & CACHE_ENTRY_DELETED) return 0;
    if (h->expire_at > 0 && h->expire_at < now) return 0;
    return 1;
}

// 添加结果到动态数组
int append_result(cache_result_t** results, size_t* count, size_t* capacity,
                          cache_t* cache, size_t entry_offset, double score) {
    if (*count >= *capacity) {
        size_t new_cap = *capacity * 2;
        if (new_cap < 16) new_cap = 16;
        cache_result_t* new_results = realloc(*results, sizeof(cache_result_t) * new_cap);
        if (!new_results) return -1;
        *results = new_results;
        *capacity = new_cap;
    }
    
    cache_result_t* r = &(*results)[*count];
    size_t key_len, value_len;
    r->key = entry_key(cache, entry_offset, &key_len);
    r->value = entry_value(cache, entry_offset, &value_len);
    r->score = score;
    
    (*count)++;
    return 0;
}

// 辅助：字符串前缀匹配
int str_starts_with(const char* str, size_t str_len, const char* prefix, size_t prefix_len) {
    if (str_len < prefix_len) return 0;
    return memcmp(str, prefix, prefix_len) == 0;
}

// 辅助：检查 namespace 过滤
int ns_filter_match(cache_t* cache, size_t entry_offset, const char* ns_filter) {
    if (!ns_filter) return 1;
    size_t key_len;
    const char* key = entry_key(cache, entry_offset, &key_len);
    size_t ns_len = strlen(ns_filter);
    if (key_len < ns_len) return 0;
    if (memcmp(key, ns_filter, ns_len) != 0) return 0;
    // 确保 ns_filter 是完整的路径段，不是部分匹配
    // 如 "/coding" 应该匹配 "/coding/cpp" 但不匹配 "/coding2"
    if (key_len > ns_len && key[ns_len] != '/') return 0;
    return 1;
}

// ====== 前缀搜索 ======

int cache_search_prefix(cache_t* cache, const char* prefix,
                        const cache_search_options_t* options,
                        cache_result_t** out_results, size_t* out_count) {
    if (!cache || !prefix || !out_results || !out_count) return CACHE_ERR_INVAL;
    
    *out_results = NULL;
    *out_count = 0;
    
    size_t prefix_len = strlen(prefix);
    if (prefix_len == 0) return CACHE_ERR_INVAL;
    
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;
    
    // 如果跳表已启用且数据量大，使用跳表遍历
    if (cache->sorted.skiplist && cache->sorted.count >= CACHE_SKIPLIST_THRESHOLD) {
        // 用跳表找到第一个 >= prefix 的节点
        cache_skiplist_node_t* current = cache->sorted.skiplist->head;
        for (int i = cache->sorted.skiplist->max_level - 1; i >= 0; i--) {
            while (current->forward[i] && 
                   strncmp(current->forward[i]->key, prefix, prefix_len) < 0) {
                current = current->forward[i];
            }
        }
        current = current->forward[0];
        
        // 从该节点开始遍历，直到不匹配前缀
        while (current) {
            if (!str_starts_with(current->key, current->key_len, prefix, prefix_len)) break;
            
            if (entry_is_valid(cache, current->offset, now) &&
                ns_filter_match(cache, current->offset, ns_filter)) {
                double score = 1.0;
                if (append_result(&results, &result_count, &result_cap, cache, current->offset, score) < 0) {
                    free(results);
                    return CACHE_ERR_NOMEM;
                }
                if (max_results > 0 && result_count >= (size_t)max_results) break;
            }
            current = current->forward[0];
        }
        
        *out_results = results;
        *out_count = result_count;
        return CACHE_OK;
    }
    
    // 使用排序数组的 lower_bound 找到前缀起点
    size_t start = cache_sorted_find_lower_bound(cache, prefix, prefix_len);
    size_t count = cache->sorted.count;
    
    for (size_t i = start; i < count; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) break;
        
        size_t key_len;
        const char* key = entry_key(cache, offset, &key_len);
        
        // 检查是否仍匹配前缀（排序数组中后续 key 可能不匹配）
        if (!str_starts_with(key, key_len, prefix, prefix_len)) break;
        
        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        
        double score = 1.0;  // 前缀匹配完全相关
        if (append_result(&results, &result_count, &result_cap, cache, offset, score) < 0) {
            free(results);
            return CACHE_ERR_NOMEM;
        }
        
        if (max_results > 0 && result_count >= (size_t)max_results) break;
    }
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== 范围搜索 [start_key, end_key) ======

int cache_search_range(cache_t* cache, const char* start_key, const char* end_key,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count) {
    if (!cache || !start_key || !end_key || !out_results || !out_count) return CACHE_ERR_INVAL;
    
    *out_results = NULL;
    *out_count = 0;
    
    size_t start_len = strlen(start_key);
    size_t end_len = strlen(end_key);
    
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;
    
    // 如果跳表已启用，使用跳表遍历
    if (cache->sorted.skiplist && cache->sorted.count >= CACHE_SKIPLIST_THRESHOLD) {
        // 找到第一个 >= start_key 的节点
        cache_skiplist_node_t* current = cache->sorted.skiplist->head;
        for (int i = cache->sorted.skiplist->max_level - 1; i >= 0; i--) {
            while (current->forward[i] && 
                   strncmp(current->forward[i]->key, start_key, start_len) < 0) {
                current = current->forward[i];
            }
        }
        current = current->forward[0];
        
        // 遍历直到 >= end_key
        while (current) {
            if (strncmp(current->key, end_key, end_len) >= 0) break;
            
            if (entry_is_valid(cache, current->offset, now) &&
                ns_filter_match(cache, current->offset, ns_filter)) {
                if (append_result(&results, &result_count, &result_cap, cache, current->offset, 1.0) < 0) {
                    free(results);
                    return CACHE_ERR_NOMEM;
                }
                if (max_results > 0 && result_count >= (size_t)max_results) break;
            }
            current = current->forward[0];
        }
        
        *out_results = results;
        *out_count = result_count;
        return CACHE_OK;
    }
    
    size_t start_idx = cache_sorted_find_lower_bound(cache, start_key, start_len);
    size_t end_idx = cache_sorted_find_lower_bound(cache, end_key, end_len);
    
    for (size_t i = start_idx; i < end_idx; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) continue;
        
        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        
        if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
            free(results);
            return CACHE_ERR_NOMEM;
        }
        
        if (max_results > 0 && result_count >= (size_t)max_results) break;
    }
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== 正则搜索 ======

int cache_search_regex(cache_t* cache, const char* pattern,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count) {
    if (!cache || !pattern || !out_results || !out_count) return CACHE_ERR_INVAL;
    
    *out_results = NULL;
    *out_count = 0;
    
    regex_t regex;
    int cflags = REG_EXTENDED | REG_NOSUB;
    if (!options || !options->case_sensitive) cflags |= REG_ICASE;
    
    if (regcomp(&regex, pattern, cflags) != 0) return CACHE_ERR_INVAL;
    
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;
    
    // 遍历所有 entry（使用排序数组）
    for (size_t i = 0; i < cache->sorted.count; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) continue;
        
        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        
        size_t key_len;
        const char* key = entry_key(cache, offset, &key_len);
        
        // key 在 pool 中已以 '\0' 结尾，可直接使用
        int match = (regexec(&regex, key, 0, NULL, 0) == 0);
        
        if (match) {
            if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
                regfree(&regex);
                free(results);
                return CACHE_ERR_NOMEM;
            }
            if (max_results > 0 && result_count >= (size_t)max_results) break;
        }
    }
    
    regfree(&regex);
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== Levenshtein 距离 ======

static size_t levenshtein_distance(const char* s1, size_t len1, const char* s2, size_t len2) {
    if (len1 == 0) return len2;
    if (len2 == 0) return len1;
    
    // 使用两行滚动数组优化内存
    size_t* prev = calloc(len2 + 1, sizeof(size_t));
    size_t* curr = calloc(len2 + 1, sizeof(size_t));
    if (!prev || !curr) {
        free(prev); free(curr);
        return len1 > len2 ? len1 : len2;
    }
    
    for (size_t j = 0; j <= len2; j++) prev[j] = j;
    
    for (size_t i = 1; i <= len1; i++) {
        curr[0] = i;
        for (size_t j = 1; j <= len2; j++) {
            size_t cost = (s1[i-1] == s2[j-1]) ? 0 : 1;
            size_t del = prev[j] + 1;
            size_t ins = curr[j-1] + 1;
            size_t sub = prev[j-1] + cost;
            
            size_t min = del;
            if (ins < min) min = ins;
            if (sub < min) min = sub;
            curr[j] = min;
        }
        size_t* tmp = prev; prev = curr; curr = tmp;
    }
    
    size_t result = prev[len2];
    free(prev); free(curr);
    return result;
}

// 辅助：计算模糊搜索的 score（0-1，1=完全匹配）
static double fuzzy_score(const char* key, size_t key_len, const char* query, size_t query_len) {
    size_t dist = levenshtein_distance(key, key_len, query, query_len);
    size_t max_len = key_len > query_len ? key_len : query_len;
    if (max_len == 0) return 1.0;
    
    // score = 1 - dist/max_len，但保证 dist==0 时为 1
    double score = 1.0 - (double)dist / max_len;
    if (score < 0) score = 0;
    return score;
}

int cache_search_fuzzy(cache_t* cache, const char* query,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count) {
    if (!cache || !query || !out_results || !out_count) return CACHE_ERR_INVAL;
    
    *out_results = NULL;
    *out_count = 0;
    
    size_t query_len = strlen(query);
    if (query_len == 0) return CACHE_ERR_INVAL;
    
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;
    
    for (size_t i = 0; i < cache->sorted.count; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) continue;
        
        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        
        size_t key_len;
        const char* key = entry_key(cache, offset, &key_len);
        
        double score = fuzzy_score(key, key_len, query, query_len);
        if (score > 0.5) {  // 阈值：只返回比较相似的结果
            if (append_result(&results, &result_count, &result_cap, cache, offset, score) < 0) {
                free(results);
                return CACHE_ERR_NOMEM;
            }
            if (max_results > 0 && result_count >= (size_t)max_results) break;
        }
    }
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== 标签搜索 ======

// 辅助：在 value 中查找 tag（简单字符串搜索）
// 假设 value 是 JSON，查找 "tag" 或 [..., "tag", ...]
static int value_contains_tag(const char* value, size_t value_len, const char* tag) {
    size_t tag_len = strlen(tag);
    if (tag_len == 0 || value_len < tag_len) return 0;
    
    // 简单实现：在 value 中搜索 tag 字符串
    // 为了更准确，可以搜索引号包围的 tag
    for (size_t i = 0; i <= value_len - tag_len; i++) {
        if (memcmp(value + i, tag, tag_len) == 0) {
            // 检查边界：确保是完整的词匹配
            int left_ok = (i == 0) || !isalnum((unsigned char)value[i-1]);
            int right_ok = (i + tag_len >= value_len) || !isalnum((unsigned char)value[i + tag_len]);
            if (left_ok && right_ok) return 1;
        }
    }
    return 0;
}

int cache_search_tag(cache_t* cache, const char* tag,
                     const cache_search_options_t* options,
                     cache_result_t** out_results, size_t* out_count) {
    if (!cache || !tag || !out_results || !out_count) return CACHE_ERR_INVAL;
    
    *out_results = NULL;
    *out_count = 0;
    
    size_t tag_len = strlen(tag);
    if (tag_len == 0) return CACHE_ERR_INVAL;
    
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;
    
    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;
    
    // 先尝试用 tag 索引（O(1) 查找）
    size_t* indexed_offsets = NULL;
    size_t indexed_count = 0;
    int use_index = (cache_tag_index_search(cache, tag, &indexed_offsets, &indexed_count) == CACHE_OK);
    
    if (use_index && indexed_count > 0) {
        // 使用索引结果
        for (size_t i = 0; i < indexed_count; i++) {
            size_t offset = indexed_offsets[i];
            if (!offset) continue;
            
            if (!entry_is_valid(cache, offset, now)) continue;
            if (!ns_filter_match(cache, offset, ns_filter)) continue;
            
            if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
                free(results);
                free(indexed_offsets);
                return CACHE_ERR_NOMEM;
            }
            if (max_results > 0 && result_count >= (size_t)max_results) break;
        }
        free(indexed_offsets);
        
        *out_results = results;
        *out_count = result_count;
        return CACHE_OK;
    }
    
    if (indexed_offsets) free(indexed_offsets);
    
    // 索引未命中或不可用，回退到全量扫描（O(n)）
    for (size_t i = 0; i < cache->sorted.count; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) continue;
        
        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        
        size_t value_len;
        const char* value = entry_value(cache, offset, &value_len);
        
        if (value_contains_tag(value, value_len, tag)) {
            if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
                free(results);
                return CACHE_ERR_NOMEM;
            }
            if (max_results > 0 && result_count >= (size_t)max_results) break;
        }
    }
    
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== 释放搜索结果 ======

void cache_results_free(cache_result_t* results) {
    free(results);
}
