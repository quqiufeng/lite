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

// ====== 前缀 + needle 过滤 ======

static int needle_match(const char* key, size_t key_len,
                        const char* needle, cache_match_mode_t mode) {
    if (mode == CACHE_MATCH_NONE) return 1;
    if (!needle || !*needle) return 0;
    size_t nlen = strlen(needle);
    if (key_len < nlen) return 0;

    if (mode == CACHE_MATCH_SUFFIX) {
        return memcmp(key + key_len - nlen, needle, nlen) == 0;
    }

    // CACHE_MATCH_PATH: 要求 "/<needle>/" 完整路径段，避免 loop.lua 命中 xloop.lua
    for (size_t i = 0; i + nlen + 2 <= key_len; i++) {
        if (key[i] != '/') continue;
        if (memcmp(key + i + 1, needle, nlen) != 0) continue;
        if (key[i + 1 + nlen] == '/') return 1;
    }
    return 0;
}

int cache_search_prefix_match(cache_t* cache, const char* prefix,
                              const char* needle, cache_match_mode_t mode,
                              const cache_search_options_t* options,
                              cache_result_t** out_results, size_t* out_count) {
    if (!cache || !prefix || !*prefix || !out_results || !out_count) return CACHE_ERR_INVAL;

    *out_results = NULL;
    *out_count = 0;

    size_t prefix_len = strlen(prefix);
    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;

    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;

    // 跳表与排序数组两条路径保持一致：扫完整个 prefix 段，命中 max_results 提前停。
    if (cache->sorted.skiplist && cache->sorted.count >= CACHE_SKIPLIST_THRESHOLD) {
        cache_skiplist_node_t* current = cache->sorted.skiplist->head;
        for (int i = cache->sorted.skiplist->max_level - 1; i >= 0; i--) {
            while (current->forward[i] &&
                   strncmp(current->forward[i]->key, prefix, prefix_len) < 0) {
                current = current->forward[i];
            }
        }
        current = current->forward[0];

        while (current) {
            if (!str_starts_with(current->key, current->key_len, prefix, prefix_len)) break;
            if (entry_is_valid(cache, current->offset, now) &&
                ns_filter_match(cache, current->offset, ns_filter) &&
                needle_match(current->key, current->key_len, needle, mode)) {
                if (append_result(&results, &result_count, &result_cap,
                                  cache, current->offset, 1.0) < 0) {
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

    size_t start = cache_sorted_find_lower_bound(cache, prefix, prefix_len);
    size_t count = cache->sorted.count;

    for (size_t i = start; i < count; i++) {
        size_t offset = cache_sorted_get(cache, i);
        if (!offset) break;

        size_t key_len;
        const char* key = entry_key(cache, offset, &key_len);
        if (!str_starts_with(key, key_len, prefix, prefix_len)) break;

        if (!entry_is_valid(cache, offset, now)) continue;
        if (!ns_filter_match(cache, offset, ns_filter)) continue;
        if (!needle_match(key, key_len, needle, mode)) continue;

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

// 辅助：在 value 中查找 tag（子串 + 词边界匹配）
// 假设 value 是 JSON，查找 "tag" 或 [..., "tag", ...]
//
// 性能：tag 索引只在「显式 tags 字段」上有条目，索引未命中时 fallback 要扫全库
// 每条 value（mem.bin 里 7k 条 / 3.7MB 是常态）。旧版在每个字节偏移都 memcmp
// 一次，是 O(value_len × tag_len)，实测单次未命中 ~12ms，recall 的 8 个 term
// 里大半未命中 → recall 卡在 10ms 级（trace oncpu 火焰图里 libc 的
// __memcmp_avx2_movbe 占绝对多数）。改成先用 memchr(SIMD) 跳首个字节命中点，
// 再 memcmp 全文 + 校验边界：语义完全不变（不是「近似匹配」），只是把逐字节
// 试探降成「跳着找」。CJK tag 首字节集中于 0xE*，仍有 3× 左右跳过量。
static int value_contains_tag(const char* value, size_t value_len, const char* tag, size_t tag_len) {
    if (tag_len == 0 || value_len < tag_len) return 0;

    const unsigned char first = (unsigned char)tag[0];
    size_t i = 0;
    while (i + tag_len <= value_len) {
        const char* hit = (const char*)memchr(value + i, first, value_len - tag_len + 1 - i);
        if (!hit) return 0;
        i = (size_t)(hit - value);
        if (memcmp(value + i, tag, tag_len) == 0) {
            // 检查边界：确保是完整的词匹配
            int left_ok = (i == 0) || !isalnum((unsigned char)value[i-1]);
            int right_ok = (i + tag_len >= value_len) || !isalnum((unsigned char)value[i + tag_len]);
            if (left_ok && right_ok) return 1;
        }
        i++;
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
        
        if (value_contains_tag(value, value_len, tag, tag_len)) {
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

// 多标签搜索：单个 cache_search_tag 的并集，但 entry 表只遍历一遍。
// 语义与逐个调用一致（索引命中走索引、索引未命中回退 value 子串 + 词边界），
// 区别只在「遍历次数」：8 个 term 各自未命中索引时，旧路径走 8 遍全库；
// 这里一遍即可，且每条 value 会在 L1 里连续被剩下的 tag 扫，省掉重复的
// entry_is_valid / ns_filter / entry_value 和重复的冷内存遍历。
// 去重用 offset 开地址哈希集：单个 tag 时不需要去重，多个 tag 的并集才需要，
// 而结果集可能上千条——线性比对就是 O(n²)（实测把 8 tag 的收益全吃掉）。
// offset 在同一 cache 内唯一标识 entry，用它代替 key 指针比较等价。
typedef struct {
    size_t* slots;   // 0 = 空（offset 0 是头块，不当 entry 用）
    size_t cap;      // 2 的幂
    size_t count;
} offset_set_t;

static size_t offset_set_hash(size_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 29;
    return (size_t)x;
}

static int offset_set_init(offset_set_t* s, size_t hint) {
    size_t cap = 64;
    while (cap < hint * 2) cap <<= 1;
    s->slots = (size_t*)calloc(cap, sizeof(size_t));
    s->cap = s->slots ? cap : 0;
    s->count = 0;
    return s->slots ? 0 : -1;
}

static void offset_set_free(offset_set_t* s) {
    free(s->slots);
    s->slots = NULL;
    s->cap = 0;
    s->count = 0;
}

static int offset_set_insert(offset_set_t* s, size_t x);

// 扩容后重插（保持 0.5 装载上限）
static int offset_set_grow(offset_set_t* s) {
    size_t old_cap = s->cap;
    size_t* old = s->slots;
    size_t new_cap = old_cap ? old_cap * 2 : 64;
    size_t* fresh = (size_t*)calloc(new_cap, sizeof(size_t));
    if (!fresh) return -1;
    s->slots = fresh;
    s->cap = new_cap;
    s->count = 0;
    for (size_t i = 0; i < old_cap; i++) {
        if (old[i]) offset_set_insert(s, old[i]);
    }
    free(old);
    return 0;
}

static int offset_set_insert(offset_set_t* s, size_t x) {
    if (s->cap == 0 || (s->count + 1) * 2 > s->cap) {
        if (offset_set_grow(s) < 0) return -1;
    }
    size_t mask = s->cap - 1;
    size_t i = offset_set_hash(x) & mask;
    for (;;) {
        if (s->slots[i] == 0) {
            s->slots[i] = x;
            s->count++;
            return 1;          // 新插入
        }
        if (s->slots[i] == x) return 0;   // 已存在
        i = (i + 1) & mask;
    }
}

int cache_search_tags(cache_t* cache, const char* const* tags, size_t ntags,
                      const cache_search_options_t* options,
                      cache_result_t** out_results, size_t* out_count) {
    if (!cache || !tags || ntags == 0 || !out_results || !out_count) return CACHE_ERR_INVAL;

    *out_results = NULL;
    *out_count = 0;

    // 单 tag 直接复用原实现（含它自己的「索引命中即短路」），避免两套代码走偏。
    if (ntags == 1) return cache_search_tag(cache, tags[0], options, out_results, out_count);

    uint64_t now = cache_now_ms();
    int max_results = options ? options->max_results : 100;
    const char* ns_filter = options ? options->ns_filter : NULL;

    cache_result_t* results = NULL;
    size_t result_count = 0;
    size_t result_cap = 0;

    size_t* lens = (size_t*)malloc(sizeof(size_t) * ntags);
    unsigned char* need_scan = (unsigned char*)calloc(ntags, 1);
    if (!lens || !need_scan) {
        free(lens); free(need_scan);
        return CACHE_ERR_NOMEM;
    }

    offset_set_t seen;
    if (offset_set_init(&seen, 256) < 0) {
        free(lens); free(need_scan);
        return CACHE_ERR_NOMEM;
    }

    size_t nscan = 0;
    for (size_t t = 0; t < ntags; t++) {
        lens[t] = tags[t] ? strlen(tags[t]) : 0;
        if (lens[t] == 0) continue;

        size_t* indexed_offsets = NULL;
        size_t indexed_count = 0;
        int ok = (cache_tag_index_search(cache, tags[t], &indexed_offsets, &indexed_count) == CACHE_OK);
        if (ok && indexed_count > 0) {
            for (size_t i = 0; i < indexed_count; i++) {
                size_t offset = indexed_offsets[i];
                if (!offset) continue;
                if (!entry_is_valid(cache, offset, now)) continue;
                if (!ns_filter_match(cache, offset, ns_filter)) continue;
                if (offset_set_insert(&seen, offset) == 0) continue;
                if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
                    free(indexed_offsets); free(lens); free(need_scan);
                    offset_set_free(&seen); free(results);
                    return CACHE_ERR_NOMEM;
                }
                if (max_results > 0 && result_count >= (size_t)max_results) break;
            }
            free(indexed_offsets);
        } else {
            if (indexed_offsets) free(indexed_offsets);
            need_scan[t] = 1;
            nscan++;
        }
        if (max_results > 0 && result_count >= (size_t)max_results) break;
    }

    if (nscan > 0 && !(max_results > 0 && result_count >= (size_t)max_results)) {
        for (size_t i = 0; i < cache->sorted.count; i++) {
            size_t offset = cache_sorted_get(cache, i);
            if (!offset) continue;
            if (!entry_is_valid(cache, offset, now)) continue;
            if (!ns_filter_match(cache, offset, ns_filter)) continue;

            size_t value_len;
            const char* value = entry_value(cache, offset, &value_len);
            int hit = 0;
            for (size_t t = 0; t < ntags; t++) {
                if (!need_scan[t]) continue;
                if (value_contains_tag(value, value_len, tags[t], lens[t])) { hit = 1; break; }
            }
            if (!hit) continue;
            if (offset_set_insert(&seen, offset) == 0) continue;

            if (append_result(&results, &result_count, &result_cap, cache, offset, 1.0) < 0) {
                free(lens); free(need_scan); offset_set_free(&seen); free(results);
                return CACHE_ERR_NOMEM;
            }
            if (max_results > 0 && result_count >= (size_t)max_results) break;
        }
    }

    free(lens);
    free(need_scan);
    offset_set_free(&seen);
    *out_results = results;
    *out_count = result_count;
    return CACHE_OK;
}

// ====== 释放搜索结果 ======

void cache_results_free(cache_result_t* results) {
    free(results);
}
