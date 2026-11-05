#include "cache_internal.h"
#include <string.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ========================================================================
// 比较函数
// ========================================================================

static int compare_entries_qsort(const void* a, const void* b) {
    // 使用全局变量传递 cache 指针（qsort 不支持额外参数）
    extern __thread cache_t* g_qsort_cache;
    cache_t* cache = g_qsort_cache;
    if (!cache) return 0;
    
    size_t offset_a = *(const size_t*)a;
    size_t offset_b = *(const size_t*)b;
    
    cache_entry_header_t* ha = (cache_entry_header_t*)CACHE_PTR(cache, offset_a);
    cache_entry_header_t* hb = (cache_entry_header_t*)CACHE_PTR(cache, offset_b);
    
    const char* key_a = (const char*)CACHE_PTR(cache, offset_a + sizeof(cache_entry_header_t));
    const char* key_b = (const char*)CACHE_PTR(cache, offset_b + sizeof(cache_entry_header_t));
    
    size_t min_len = ha->key_len < hb->key_len ? ha->key_len : hb->key_len;
    int cmp = memcmp(key_a, key_b, min_len);
    if (cmp != 0) return cmp;
    if (ha->key_len < hb->key_len) return -1;
    if (ha->key_len > hb->key_len) return 1;
    return 0;
}

static int compare_key_with_entry(const char* key, size_t key_len, cache_t* cache, size_t entry_offset) {
    cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, entry_offset);
    const char* entry_key = (const char*)CACHE_PTR(cache, entry_offset + sizeof(cache_entry_header_t));
    
    size_t min_len = key_len < h->key_len ? key_len : h->key_len;
    int cmp = memcmp(key, entry_key, min_len);
    if (cmp != 0) return cmp;
    return (int)(key_len - h->key_len);
}

// ========================================================================
// 内部辅助
// ========================================================================

__thread cache_t* g_qsort_cache = NULL;

static int ensure_capacity(cache_sorted_array_t* sorted, size_t need) {
    if (need <= sorted->capacity) return 0;
    
    size_t new_cap = sorted->capacity * 2;
    if (new_cap < need) new_cap = need;
    if (new_cap < 16) new_cap = 16;
    
    size_t* new_offsets = (size_t*)realloc(sorted->offsets, sizeof(size_t) * new_cap);
    if (!new_offsets) return -1;
    
    sorted->offsets = new_offsets;
    sorted->capacity = new_cap;
    return 0;
}

// 确保排序数组已排序（延迟排序）
void cache_sorted_ensure_sorted(cache_t* cache) {
    if (!cache || !cache->sorted.dirty) return;
    
    cache_sorted_array_t* sorted = &cache->sorted;
    if (sorted->count <= 1) {
        sorted->dirty = 0;
        return;
    }
    
    g_qsort_cache = cache;
    qsort(sorted->offsets, sorted->count, sizeof(size_t), compare_entries_qsort);
    g_qsort_cache = NULL;
    
    sorted->dirty = 0;
}

// 内部使用的静态包装
static void ensure_sorted(cache_t* cache) {
    cache_sorted_ensure_sorted(cache);
}

// ========================================================================
// 公共 API
// ========================================================================

int cache_sorted_init(cache_t* cache) {
    if (!cache) return -1;
    
    cache->sorted.offsets = NULL;
    cache->sorted.count = 0;
    cache->sorted.capacity = 0;
    cache->sorted.dirty = 0;
    cache->sorted.skiplist = NULL;
    
    return 0;
}

// O(1) 插入：直接追加到末尾，标记 dirty
int cache_sorted_insert(cache_t* cache, size_t entry_offset) {
    if (!cache) return -1;
    
    cache_sorted_array_t* sorted = &cache->sorted;
    
    if (ensure_capacity(sorted, sorted->count + 1) < 0) return -1;
    
    sorted->offsets[sorted->count] = entry_offset;
    sorted->count++;
    sorted->dirty = 1;  // 标记需要重新排序
    
    // 如果跳表已启用，也插入到跳表
    if (sorted->skiplist) {
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, entry_offset);
        const char* key = (const char*)CACHE_PTR(cache, entry_offset + sizeof(cache_entry_header_t));
        cache_skiplist_insert(cache, sorted->skiplist, entry_offset, key, h->key_len);
    }
    
    return 0;
}

// O(1) 删除：swap-with-last + pop，标记 dirty
int cache_sorted_remove(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0) return -1;
    
    cache_sorted_array_t* sorted = &cache->sorted;
    if (sorted->count == 0) return -1;
    
    // 优化：如果跳表已启用且规模足够，直接用跳表定位，避免全表排序
    if (sorted->skiplist && sorted->count >= CACHE_SKIPLIST_THRESHOLD) {
        cache_skiplist_node_t* node = cache_skiplist_find(sorted->skiplist, key, key_len);
        if (node) {
            // 在 sorted array 中查找对应 offset 并删除（O(n) 但 n 通常很小）
            for (size_t i = 0; i < sorted->count; i++) {
                if (sorted->offsets[i] == node->offset) {
                    sorted->offsets[i] = sorted->offsets[sorted->count - 1];
                    sorted->count--;
                    sorted->dirty = 1;
                    cache_skiplist_remove(sorted->skiplist, key, key_len);
                    return 0;
                }
            }
        }
        return -1;  // 跳表中未找到
    }
    
    ensure_sorted(cache);  // fallback：排序后二分查找
    
    // 二分查找
    size_t left = 0, right = sorted->count;
    while (left < right) {
        size_t mid = left + (right - left) / 2;
        int cmp = compare_key_with_entry(key, key_len, cache, sorted->offsets[mid]);
        if (cmp > 0) {
            left = mid + 1;
        } else if (cmp < 0) {
            right = mid;
        } else {
            // 找到，swap-with-last 删除（O(1)）
            sorted->offsets[mid] = sorted->offsets[sorted->count - 1];
            sorted->count--;
            sorted->dirty = 1;
            
            // 如果跳表已启用，也删除跳表节点
            if (sorted->skiplist) {
                cache_skiplist_remove(sorted->skiplist, key, key_len);
            }
            
            return 0;
        }
    }
    
    return -1;  // 未找到
}

// 二分查找 lower_bound（需要排序）
size_t cache_sorted_find_lower_bound(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0 || cache->sorted.count == 0) return 0;
    
    ensure_sorted(cache);
    
    cache_sorted_array_t* sorted = &cache->sorted;
    size_t left = 0, right = sorted->count;
    
    while (left < right) {
        size_t mid = left + (right - left) / 2;
        if (compare_key_with_entry(key, key_len, cache, sorted->offsets[mid]) <= 0) {
            right = mid;
        } else {
            left = mid + 1;
        }
    }
    
    return left;
}

// 二分查找 upper_bound（需要排序）
size_t cache_sorted_find_upper_bound(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0 || cache->sorted.count == 0) return 0;
    
    ensure_sorted(cache);
    
    cache_sorted_array_t* sorted = &cache->sorted;
    size_t left = 0, right = sorted->count;
    
    while (left < right) {
        size_t mid = left + (right - left) / 2;
        if (compare_key_with_entry(key, key_len, cache, sorted->offsets[mid]) < 0) {
            right = mid;
        } else {
            left = mid + 1;
        }
    }
    
    return left;
}

// 获取指定位置的 entry_offset
size_t cache_sorted_get(cache_t* cache, size_t index) {
    if (!cache || index >= cache->sorted.count) return 0;
    return cache->sorted.offsets[index];
}

// 重建排序数组（全量 qsort），并根据数据量决定是否启用跳表
void cache_sorted_rebuild(cache_t* cache) {
    if (!cache) return;
    ensure_sorted(cache);
    
    // 当数据量超过阈值时，启用跳表加速
    if (cache->sorted.count >= CACHE_SKIPLIST_THRESHOLD) {
        if (!cache->sorted.skiplist) {
            cache->sorted.skiplist = cache_skiplist_create();
        }
        if (cache->sorted.skiplist) {
            cache_skiplist_build(cache, cache->sorted.skiplist);
        }
    }
}

// 释放排序数组内存
void cache_sorted_destroy(cache_t* cache) {
    if (!cache) return;
    if (cache->sorted.offsets) {
        free(cache->sorted.offsets);
        cache->sorted.offsets = NULL;
    }
    cache->sorted.count = 0;
    cache->sorted.capacity = 0;
    cache->sorted.dirty = 0;
    
    if (cache->sorted.skiplist) {
        cache_skiplist_destroy(cache->sorted.skiplist);
        cache->sorted.skiplist = NULL;
    }
}
