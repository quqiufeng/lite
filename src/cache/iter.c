#include "cache_internal.h"
#include <string.h>
#include <stdlib.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ====== 迭代器 API ======

cache_iter_t* cache_iter_create(cache_t* cache) {
    if (!cache) return NULL;
    
    cache_iter_t* iter = calloc(1, sizeof(cache_iter_t));
    if (!iter) return NULL;
    
    iter->cache = cache;
    iter->index = 0;
    iter->ns_prefix = NULL;
    iter->ns_prefix_len = 0;
    
    return iter;
}

void cache_iter_destroy(cache_iter_t* iter) {
    free(iter);
}

int cache_iter_next(cache_iter_t* iter, const char** key_out, const char** value_out) {
    if (!iter || !iter->cache) return -1;
    
    cache_t* cache = iter->cache;
    uint64_t now = cache_now_ms();
    
    while (iter->index < cache->sorted.count) {
        size_t offset = cache_sorted_get(cache, iter->index);
        iter->index++;
        
        if (!offset) continue;
        if (!entry_is_valid(cache, offset, now)) continue;
        
        if (key_out) *key_out = entry_key(cache, offset, NULL);
        if (value_out) *value_out = entry_value(cache, offset, NULL);
        return 1;  // 成功返回一条
    }
    
    return 0;  // 遍历结束
}

int cache_iter_ns_next(cache_iter_t* iter, const char* ns_prefix,
                       const char** key_out, const char** value_out) {
    if (!iter || !iter->cache || !ns_prefix) return -1;
    
    cache_t* cache = iter->cache;
    uint64_t now = cache_now_ms();
    size_t ns_len = strlen(ns_prefix);
    
    while (iter->index < cache->sorted.count) {
        size_t offset = cache_sorted_get(cache, iter->index);
        iter->index++;
        
        if (!offset) continue;
        if (!entry_is_valid(cache, offset, now)) continue;
        
        size_t key_len;
        const char* key = entry_key(cache, offset, &key_len);
        
        // 检查是否属于该 namespace
        if (key_len < ns_len) continue;
        if (memcmp(key, ns_prefix, ns_len) != 0) continue;
        // 确保是完整路径段匹配
        if (key_len > ns_len && key[ns_len] != '/') continue;
        
        if (key_out) *key_out = key;
        if (value_out) *value_out = entry_value(cache, offset, NULL);
        return 1;
    }
    
    return 0;
}

void cache_iter_reset(cache_iter_t* iter) {
    if (!iter) return;
    iter->index = 0;
}
