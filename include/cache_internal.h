#ifndef CACHE_INTERNAL_H
#define CACHE_INTERNAL_H

#include "cache.h"
#include "cache_hnsw.h"
#include "mydb_internal.h"  // 复用 db_pool_t, error handling 等
#include <stdbool.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef CACHE_LOG
#define CACHE_LOG(...) do { if (getenv("LITE_CACHE_VERBOSE")) fprintf(stderr, __VA_ARGS__); } while (0)
#endif

// ====== 文件格式常量 ======
#define CACHE_MAGIC     "MYCA"   // Magic: "MYCA"
#define CACHE_VERSION   1
#define CACHE_HEADER_SIZE 48     // cache 文件头大小，对齐到 8
#define CACHE_ENTRY_HEADER_SIZE 28  // entry 头大小（packed）
#define CACHE_ENTRY_HEADER_ALIGNED 32 // entry 头对齐到 8

// ====== Entry 标志位 ======
#define CACHE_ENTRY_DELETED     0x01  // 逻辑删除
#define CACHE_ENTRY_PERMANENT   0x02  // 永久不过期

// ====== Entry Header（变长 entry 的头部）======
typedef struct __attribute__((packed)) {
    uint32_t key_len;           // key 长度
    uint32_t value_len;         // value 长度
    uint64_t expire_at;         // 过期时间（毫秒时间戳，0=永久）
    uint64_t access_time;       // 最后访问时间（毫秒时间戳）
    uint16_t flags;             // 标志位
    uint16_t reserved;          // 保留（对齐到 8）
} cache_entry_header_t;

// 总大小：28 bytes（packed，但后续对齐到 32）
_Static_assert(sizeof(cache_entry_header_t) == 28, "Entry header must be 28 bytes");

// ====== Entry（内存中的表示）======
typedef struct {
    size_t offset;              // 在 pool 中的偏移
    size_t key_offset;          // key 在 pool 中的偏移
    size_t value_offset;        // value 在 pool 中的偏移
    uint32_t key_len;
    uint32_t value_len;
    uint64_t expire_at;
    uint64_t access_time;
    uint16_t flags;
} cache_entry_t;

// ====== Hash 索引（借鉴 code_bin hashmap）======
// 使用 my_db 风格的 pool offset，不存指针

typedef struct {
    size_t entry_offset;        // 指向 cache_entry_t 的 offset
    size_t next_offset;         // 冲突链下一个 bucket 的 offset（0=无）
} cache_hash_bucket_t;

typedef struct {
    size_t bucket_count;        // bucket 数量
    size_t size;                // 当前元素数量
    size_t buckets_offset;      // bucket 数组在 pool 中的 offset
} cache_hash_index_t;

// ====== 跳表（Skip List）======
#define CACHE_SKIPLIST_MAX_LEVEL 20
#define CACHE_SKIPLIST_P 0.5
#define CACHE_SKIPLIST_THRESHOLD 1000000  // 超过此阈值启用跳表

typedef struct cache_skiplist_node {
    size_t offset;              // entry 在 pool 中的 offset
    char* key;                  // key 的副本（用于比较）
    size_t key_len;
    struct cache_skiplist_node** forward;  // 前向指针数组 [level]
    int level;                  // 节点层数
} cache_skiplist_node_t;

typedef struct {
    cache_skiplist_node_t* head;  // 头节点
    int max_level;                // 当前最大层数
    size_t size;                  // 节点数量
} cache_skiplist_t;

// ====== 排序数组（借鉴 code_bin sorted array）======
typedef struct {
    size_t* offsets;            // entry offset 数组（按 key 字典序排列）
    size_t count;               // 当前数量
    size_t capacity;            // 数组容量
    int dirty;                  // 1 = 需要重新排序（延迟排序优化）
    cache_skiplist_t* skiplist; // 跳表加速层（NULL = 未启用）
} cache_sorted_array_t;

// ====== Namespace 索引 ======
typedef struct cache_ns_node {
    char* path;                 // namespace 路径（如 "/coding/cpp"）
    size_t* entry_offsets;      // 属于该 namespace 的 entry offsets
    size_t entry_count;
    size_t entry_capacity;
    struct cache_ns_node** children;  // 子 namespace
    size_t child_count;
    size_t child_capacity;
} cache_ns_node_t;

// ====== 迭代器 ======
struct cache_iter {
    cache_t* cache;
    size_t index;               // 当前在 sorted 数组中的位置
    const char* ns_prefix;      // namespace 过滤（NULL = 不过滤）
    size_t ns_prefix_len;       // namespace 前缀长度
};

// ====== Tag 反向索引 ======
#define CACHE_TAG_INDEX_SIZE 64  // tag hash 表大小（2 的幂）

typedef struct cache_tag_entry {
    char* tag;                  // tag 字符串（堆上分配）
    size_t* offsets;            // entry offset 数组
    size_t count;               // 当前数量
    size_t capacity;            // 数组容量
    struct cache_tag_entry* next;  // 冲突链
} cache_tag_entry_t;

typedef struct {
    cache_tag_entry_t** buckets;  // hash bucket 数组
    size_t bucket_count;          // bucket 数量
    size_t size;                  // 总 tag 数量
} cache_tag_index_t;

// ====== Vector 索引 ======
#define CACHE_MAX_VECTOR_DIM 1536  // 最大向量维度（OpenAI text-embedding-3-small=1536）
#define CACHE_HNSW_THRESHOLD 1000  // 超过此数量启用 HNSW

typedef struct {
    size_t entry_offset;        // 对应的 entry offset
    size_t vector_offset;       // 向量数据在 pool 中的 offset
    uint16_t dim;               // 向量维度
} cache_vector_entry_t;

typedef struct {
    cache_vector_entry_t* entries;  // 向量条目数组（暴力搜索用）
    size_t count;                   // 当前数量
    size_t capacity;                // 数组容量
    hnsw_index_t* hnsw;             // HNSW 近似索引（NULL = 未启用）
    int use_hnsw;                   // 1 = 当前使用 HNSW
} cache_vector_index_t;

// ====== Hot Cache（热点缓存，加速重复读取）======
#define CACHE_HOT_SIZE 64

typedef struct {
    uint64_t key_hash;          // key 的 FNV hash
    size_t entry_offset;        // entry 在 pool 中的 offset
    uint64_t access_time;       // 最后访问时间
} cache_hot_entry_t;

// ====== Cache 实例 ======
struct cache {
    db_pool_t pool;             // mmap pool（复用 my_db）
    
    // 索引
    cache_hash_index_t hash;    // Hash 索引：key → entry_offset
    cache_sorted_array_t sorted; // 排序数组：按 key 字典序排列
    cache_ns_node_t* ns_root;   // Namespace 树
    cache_tag_index_t tag_index; // Tag 反向索引：tag → [entry_offsets]
    
    // 向量索引
    cache_vector_index_t vector_index; // 向量索引（内存中，重启重建）
    
    // 热点缓存
    cache_hot_entry_t hot_cache[CACHE_HOT_SIZE];
    size_t hot_count;
    
    // 统计
    size_t entry_count;         // 总条目数（不含已删除）
    size_t deleted_count;       // 已删除条目数
    size_t memory_used;         // 已用内存（估算）
    size_t memory_max;          // 最大内存限制
    
    // 状态
    char db_dir[256];           // 数据库目录
    
    // 索引持久化（mmap）
    void* index_mmap_base;      // index.bin mmap base
    size_t index_mmap_size;     // mmap size
    int index_loaded;           // 1 = loaded from file, 0 = rebuilt
};

// ====== 内部函数（其他模块使用）======

// Hash 索引操作
int cache_hash_init(cache_t* cache);
int cache_hash_insert(cache_t* cache, size_t entry_offset, const char* key, size_t key_len);
int cache_hash_remove(cache_t* cache, const char* key, size_t key_len);
size_t cache_hash_lookup(cache_t* cache, const char* key, size_t key_len);

// 排序数组操作
int cache_sorted_init(cache_t* cache);
int cache_sorted_insert(cache_t* cache, size_t entry_offset);
int cache_sorted_remove(cache_t* cache, const char* key, size_t key_len);
size_t cache_sorted_find_lower_bound(cache_t* cache, const char* key, size_t key_len);
size_t cache_sorted_find_upper_bound(cache_t* cache, const char* key, size_t key_len);
size_t cache_sorted_get(cache_t* cache, size_t index);
void cache_sorted_destroy(cache_t* cache);
void cache_sorted_rebuild(cache_t* cache);
void cache_sorted_ensure_sorted(cache_t* cache);

// Namespace 操作
int cache_ns_init(cache_t* cache);
int cache_ns_add(cache_t* cache, const char* key, size_t entry_offset);
int cache_ns_remove(cache_t* cache, const char* key);
cache_ns_node_t* cache_ns_find(cache_t* cache, const char* ns_path);
void cache_ns_destroy(cache_t* cache);

// 工具函数
uint64_t cache_now_ms(void);
int cache_entry_is_expired(cache_entry_t* entry, uint64_t now);
size_t cache_entry_total_size(cache_entry_header_t* header);

// 搜索辅助函数（供其他模块使用）
const char* entry_key(cache_t* cache, size_t offset, size_t* key_len_out);
const char* entry_value(cache_t* cache, size_t offset, size_t* value_len_out);
int entry_is_valid(cache_t* cache, size_t offset, uint64_t now);
int append_result(cache_result_t** results, size_t* count, size_t* capacity,
                  cache_t* cache, size_t entry_offset, double score);
int str_starts_with(const char* str, size_t str_len, const char* prefix, size_t prefix_len);
int ns_filter_match(cache_t* cache, size_t offset, const char* ns_filter);

// 搜索内部函数
int cache_search_internal_prefix(cache_t* cache, const char* prefix,
                                 const cache_search_options_t* options,
                                 cache_result_t** out_results, size_t* out_count);
int cache_search_internal_regex(cache_t* cache, const char* pattern,
                                const cache_search_options_t* options,
                                cache_result_t** out_results, size_t* out_count);
int cache_search_internal_fuzzy(cache_t* cache, const char* query,
                                 const cache_search_options_t* options,
                                 cache_result_t** out_results, size_t* out_count);

// Tag 索引操作
int cache_tag_index_init(cache_t* cache);
void cache_tag_index_destroy(cache_t* cache);
int cache_tag_index_add(cache_t* cache, size_t entry_offset, const char* value, size_t value_len);
int cache_tag_index_remove(cache_t* cache, size_t entry_offset, const char* value, size_t value_len);
int cache_tag_index_search(cache_t* cache, const char* tag, size_t** out_offsets, size_t* out_count);
void cache_tag_index_rebuild(cache_t* cache);

// 跳表操作
cache_skiplist_t* cache_skiplist_create(void);
void cache_skiplist_destroy(cache_skiplist_t* sl);
int cache_skiplist_insert(cache_t* cache, cache_skiplist_t* sl, size_t entry_offset, const char* key, size_t key_len);
void cache_skiplist_remove(cache_skiplist_t* sl, const char* key, size_t key_len);
cache_skiplist_node_t* cache_skiplist_find(cache_skiplist_t* sl, const char* key, size_t key_len);
void cache_skiplist_build(cache_t* cache, cache_skiplist_t* sl);

// 向量操作
int cache_vector_index_init(cache_t* cache);
void cache_vector_index_destroy(cache_t* cache);
int cache_vector_index_add(cache_t* cache, size_t entry_offset, const float* vector, size_t dim);
void cache_vector_index_remove(cache_t* cache, size_t entry_offset);
float cache_vector_cosine_similarity(const float* a, const float* b, size_t dim);
void cache_vector_index_rebuild(cache_t* cache);

#endif /* CACHE_INTERNAL_H */