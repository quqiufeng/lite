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

// O(1) 追加：末尾塞一个 offset 并置 dirty，排序留给下一次 ensure_sorted。
// 只给批量场景用（全量加载/compact 重建/批量窗口）：那里 N 次插入只该付一次 qsort。
int cache_sorted_append(cache_t* cache, size_t entry_offset) {
    if (!cache) return -1;

    cache_sorted_array_t* sorted = &cache->sorted;

    if (ensure_capacity(sorted, sorted->count + 1) < 0) return -1;

    sorted->offsets[sorted->count] = entry_offset;
    sorted->count++;
    sorted->dirty = 1;

    if (sorted->skiplist) {
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, entry_offset);
        const char* key = (const char*)CACHE_PTR(cache, entry_offset + sizeof(cache_entry_header_t));
        cache_skiplist_insert(cache, sorted->skiplist, entry_offset, key, h->key_len);
    }

    return 0;
}

// 稳态插入：数组本来有序就按序插（二分 + memmove，O(n) 搬指针），dirty 保持 0。
// 老版无论何时都「末尾追加 + dirty=1」，于是稳态 put 之后的第一次 del/范围查询又付
// 一次全量 qsort：实测 put 0.7µs → put+del 195µs(n=3200)/690µs(n=10000)，而 memory
// 的 raw_keep 每轮都是「先 put 再 del」，正好把这条路径踩满。
// 反着改回「永远追加」会让稳态写变慢几十倍；反过来「永远二分插入」会让批量加载退化
// 成 O(n²)，所以两条路都留着，由 dirty/defer 分流。
int cache_sorted_insert(cache_t* cache, size_t entry_offset) {
    if (!cache) return -1;

    cache_sorted_array_t* sorted = &cache->sorted;

    // 批量窗口、或数组已经脏（正在批量灌）：追加最省，排序统一交 ensure_sorted。
    if (cache->sorted_defer || sorted->dirty) {
        return cache_sorted_append(cache, entry_offset);
    }

    if (ensure_capacity(sorted, sorted->count + 1) < 0) return -1;

    cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, entry_offset);
    const char* key = (const char*)CACHE_PTR(cache, entry_offset + sizeof(cache_entry_header_t));
    size_t key_len = h->key_len;

    // upper_bound：等 key 的旧 entry 之后插入（删除按 key 二分时能命中任意一条）
    size_t left = 0, right = sorted->count;
    while (left < right) {
        size_t mid = left + (right - left) / 2;
        if (compare_key_with_entry(key, key_len, cache, sorted->offsets[mid]) < 0) {
            right = mid;
        } else {
            left = mid + 1;
        }
    }
    if (left < sorted->count) {
        memmove(&sorted->offsets[left + 1], &sorted->offsets[left],
                (sorted->count - left) * sizeof(size_t));
    }
    sorted->offsets[left] = entry_offset;
    sorted->count++;

    // 如果跳表已启用，也插入到跳表
    if (sorted->skiplist) {
        cache_skiplist_insert(cache, sorted->skiplist, entry_offset, key, key_len);
    }
    
    return 0;
}

// O(1) 删除：swap-with-last + pop，标记 dirty
// 批量写入窗口里 cache_sorted_remove 只记账不动数组，墓碑偏移量攒着；
// 这里一次性把它们摘掉（O(n) 顺序过滤，比 qsort 便宜），并把 dirty 置位交给
// 下一次 ensure_sorted / rebuild 统一排序。
void cache_sorted_purge_tombstones(cache_t* cache) {
    if (!cache) return;
    cache_sorted_array_t* sorted = &cache->sorted;
    size_t w = 0;
    for (size_t i = 0; i < sorted->count; i++) {
        size_t off = sorted->offsets[i];
        if (off >= cache->pool.used) continue;           // 越界防御：坏偏移直接丢
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, off);
        if (h->flags & CACHE_ENTRY_DELETED) continue;
        sorted->offsets[w++] = off;
    }
    sorted->count = w;
    sorted->dirty = 1;
    cache->sorted_defer_pending = 0;
}

int cache_sorted_remove(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0) return -1;
    
    cache_sorted_array_t* sorted = &cache->sorted;
    if (sorted->count == 0) return -1;

    // 批量窗口：调用方已经把旧 entry 标了墓碑，这里不清数组也不会让人读到旧值
    // （cache_get 走 hash，排序数组只服务范围/前缀扫描，而墓碑会被过滤掉）。
    // 没有这一步，CACHE_SKIPLIST_THRESHOLD(1e6) 之下的库每次删除都全量 qsort：
    // 49 万 offset 单次 ≈0.4s，8192 个重复 key 的批 ≈ 1 小时。
    if (cache->sorted_defer && !sorted->skiplist) {
        if (++cache->sorted_defer_pending >= 4096) {
            cache_sorted_purge_tombstones(cache);
        }
        return 0;
    }
    
    // 大库上的隐患：跳表从未被建过（cache_skiplist_build 只有 cache_sorted_rebuild 调用，
    // 而 rebuild 此前没有任何调用者），于是每次删除都掉进下面的 fallback：一次全量 qsort。
    // 3.4M 条 key 的库单次 qsort ≈ 4s，批量删（import 清理旧调用边）就退化成 N×4s 的小时级任务。
    // 超过阈值就先付一次「排序 + 建跳表」的代价，之后每次删除走 O(log n)。
    if (!sorted->skiplist && sorted->count >= CACHE_SKIPLIST_THRESHOLD) {
        cache_sorted_rebuild(cache);
    }

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
            // 找到：有序删除，memmove 填洞。
            // 旧版用 swap-with-last（O(1)）但把数组打乱并置 dirty，导致下一次
            // cache_sorted_remove 的 ensure_sorted 对全部 n 个 offset 重新 qsort：
            // 中小库（count < CACHE_SKIPLIST_THRESHOLD 的 1e6，跳表没建）每次删除
            // 都付一次 O(n log n) 全量 strcmp。实测 n=3200 单次 del ≈500µs，
            // 而 put 只要 13µs；raw_keep 每轮淘汰消息就踩这条路径。
            // 一次 memmove 是 O(n) 但只是搬 8 字节指针（3200 条 ≈25KB，几 µs），
            // 换来 dirty 保持 0，后续二分免排序。
            memmove(&sorted->offsets[mid], &sorted->offsets[mid + 1],
                    (sorted->count - mid - 1) * sizeof(size_t));
            sorted->count--;
            
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
