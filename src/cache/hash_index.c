#include "cache_internal.h"
#include <string.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// FNV-1a hash 算法（借鉴 code_bin hashmap）
static uint64_t hash_fnv1a(const void* data, size_t len) {
    const uint8_t* bytes = (const uint8_t*)data;
    uint64_t hash = 0xcbf29ce484222325;
    for (size_t i = 0; i < len; i++) {
        hash ^= bytes[i];
        hash *= 0x100000001b3;
    }
    return hash;
}

// 从 pool 分配 hash bucket 数组
static size_t alloc_buckets(cache_t* cache, size_t count) {
    size_t size = sizeof(cache_hash_bucket_t) * count;
    size_t aligned = (size + MYDB_ALIGN - 1) & ~(MYDB_ALIGN - 1);
    void* ptr = pool_alloc(&cache->pool, aligned);
    if (!ptr) return 0;
    memset(ptr, 0, aligned);
    return (size_t)((char*)ptr - (char*)cache->pool.base);
}

// 初始化 hash 索引
int cache_hash_init(cache_t* cache) {
    if (!cache) return -1;
    
    cache->hash.bucket_count = 64;  // 初始 64 个 bucket
    cache->hash.size = 0;
    cache->hash.buckets_offset = alloc_buckets(cache, 64);
    
    return cache->hash.buckets_offset ? 0 : -1;
}

// 扩容 hash 表（负载因子 > 0.75）
static int hash_resize(cache_t* cache) {
    size_t old_count = cache->hash.bucket_count;
    size_t new_count = old_count * 2;
    if (new_count < old_count) return -1;  // 溢出
    
    // 分配新 bucket 数组
    size_t new_buckets_offset = alloc_buckets(cache, new_count);
    if (!new_buckets_offset) return -1;
    
    cache_hash_bucket_t* new_buckets = (cache_hash_bucket_t*)CACHE_PTR(cache, new_buckets_offset);
    cache_hash_bucket_t* old_buckets = (cache_hash_bucket_t*)CACHE_PTR(cache, cache->hash.buckets_offset);
    
    // 遍历旧 bucket，重新分配到新 bucket
    for (size_t i = 0; i < old_count; i++) {
        size_t node_offset = old_buckets[i].entry_offset;
        while (node_offset) {
            cache_hash_bucket_t* node = (cache_hash_bucket_t*)CACHE_PTR(cache, node_offset);
            cache_entry_header_t* header = (cache_entry_header_t*)CACHE_PTR(cache, node->entry_offset);
            char* key = (char*)CACHE_PTR(cache, node->entry_offset + sizeof(cache_entry_header_t));
            
            // 计算新 hash
            uint64_t h = hash_fnv1a(key, header->key_len);
            size_t idx = h % new_count;
            
            // 保存 next（在当前节点中）
            size_t next_offset = node->next_offset;
            
            // 插入新 bucket 链尾部
            cache_hash_bucket_t* new_bucket = &new_buckets[idx];
            size_t* p = &new_bucket->entry_offset;
            while (*p) {
                cache_hash_bucket_t* b = (cache_hash_bucket_t*)CACHE_PTR(cache, *p);
                p = &b->next_offset;
            }
            *p = node_offset;
            node->next_offset = 0;  // 切断旧链接，避免循环
            
            // 继续遍历旧链
            node_offset = next_offset;
        }
    }
    
    cache->hash.bucket_count = new_count;
    cache->hash.buckets_offset = new_buckets_offset;
    return 0;
}

// 插入 key → entry_offset
int cache_hash_insert(cache_t* cache, size_t entry_offset, const char* key, size_t key_len) {
    if (!cache || !entry_offset || !key || key_len == 0) return -1;
    
    // 自动初始化 hash 表（防御性编程）
    if (cache->hash.bucket_count == 0) {
        if (cache_hash_init(cache) < 0) return -1;
    }
    
    // 检查负载因子
    if (cache->hash.size > 0 && cache->hash.size >= cache->hash.bucket_count * 3 / 4) {
        if (hash_resize(cache) < 0) {
            // 扩容失败，继续插入（性能下降但可用）
        }
    }
    
    uint64_t h = hash_fnv1a(key, key_len);
    size_t idx = h % cache->hash.bucket_count;
    size_t buckets_offset = cache->hash.buckets_offset;

    // 用偏移量而非裸指针跟踪插入点：pool_alloc 可能触发 pool_resize /
    // mremap 搬移整个映射，alloc 之前缓存的指针在 alloc 之后会失效
    // （曾导致写野指针 SIGSEGV）。prev_offset==0 表示链头。
    size_t prev_offset = 0;
    size_t current = ((cache_hash_bucket_t*)CACHE_PTR(cache, buckets_offset))[idx].entry_offset;
    while (current) {
        cache_hash_bucket_t* b = (cache_hash_bucket_t*)CACHE_PTR(cache, current);
        cache_entry_header_t* header = (cache_entry_header_t*)CACHE_PTR(cache, b->entry_offset);
        char* entry_key = (char*)CACHE_PTR(cache, b->entry_offset + sizeof(cache_entry_header_t));
        
        if (header->key_len == key_len && memcmp(entry_key, key, key_len) == 0) {
            // 已存在，更新 entry_offset
            b->entry_offset = entry_offset;
            return 0;
        }
        prev_offset = current;
        current = b->next_offset;
    }
    
    // 分配新 bucket 节点（可能搬移 mmap，故先不缓存任何 pool 指针）
    void* node_ptr = pool_alloc(&cache->pool, sizeof(cache_hash_bucket_t));
    if (!node_ptr) return -1;
    size_t node_offset = (size_t)((char*)node_ptr - (char*)cache->pool.base);
    
    cache_hash_bucket_t* new_node = (cache_hash_bucket_t*)node_ptr;
    new_node->entry_offset = entry_offset;
    new_node->next_offset = 0;
    
    // 从偏移量重新解析插入点（映射可能已被搬移）
    if (prev_offset == 0) {
        cache_hash_bucket_t* head = (cache_hash_bucket_t*)CACHE_PTR(cache, buckets_offset);
        head[idx].entry_offset = node_offset;
    } else {
        cache_hash_bucket_t* prev = (cache_hash_bucket_t*)CACHE_PTR(cache, prev_offset);
        prev->next_offset = node_offset;
    }
    cache->hash.size++;
    
    return 0;
}

// 查找 key → entry_offset
size_t cache_hash_lookup(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0 || !cache->hash.buckets_offset) return 0;
    
    uint64_t h = hash_fnv1a(key, key_len);
    size_t idx = h % cache->hash.bucket_count;
    
    cache_hash_bucket_t* buckets = (cache_hash_bucket_t*)CACHE_PTR(cache, cache->hash.buckets_offset);
    size_t current = buckets[idx].entry_offset;
    
    while (current) {
        cache_hash_bucket_t* b = (cache_hash_bucket_t*)CACHE_PTR(cache, current);
        cache_entry_header_t* header = (cache_entry_header_t*)CACHE_PTR(cache, b->entry_offset);
        char* entry_key = (char*)CACHE_PTR(cache, b->entry_offset + sizeof(cache_entry_header_t));
        
        if (header->key_len == key_len && memcmp(entry_key, key, key_len) == 0) {
            return b->entry_offset;
        }
        current = b->next_offset;
    }
    
    return 0;
}

// 删除 key
int cache_hash_remove(cache_t* cache, const char* key, size_t key_len) {
    if (!cache || !key || key_len == 0 || !cache->hash.buckets_offset) return -1;
    
    uint64_t h = hash_fnv1a(key, key_len);
    size_t idx = h % cache->hash.bucket_count;
    
    cache_hash_bucket_t* buckets = (cache_hash_bucket_t*)CACHE_PTR(cache, cache->hash.buckets_offset);
    size_t* pp = &buckets[idx].entry_offset;
    size_t current = buckets[idx].entry_offset;
    
    while (current) {
        cache_hash_bucket_t* b = (cache_hash_bucket_t*)CACHE_PTR(cache, current);
        cache_entry_header_t* header = (cache_entry_header_t*)CACHE_PTR(cache, b->entry_offset);
        char* entry_key = (char*)CACHE_PTR(cache, b->entry_offset + sizeof(cache_entry_header_t));
        
        if (header->key_len == key_len && memcmp(entry_key, key, key_len) == 0) {
            *pp = b->next_offset;
            cache->hash.size--;
            return 0;
        }
        pp = &b->next_offset;
        current = b->next_offset;
    }
    
    return -1;  // 未找到
}