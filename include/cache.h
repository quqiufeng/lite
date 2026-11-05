#ifndef CACHE_H
#define CACHE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ====== 错误码（和 mydb.h 统一风格）======
#define CACHE_OK            0
#define CACHE_ERR_INVAL    -1   // 参数错误
#define CACHE_ERR_IO       -2   // 文件/磁盘错误
#define CACHE_ERR_NOMEM    -3   // 内存不足
#define CACHE_ERR_NOENT    -4   // key 不存在
#define CACHE_ERR_EXIST    -5   // key 已存在
#define CACHE_ERR_CORRUPTED -6  // 文件损坏

// ====== 常量 ======
#define CACHE_MAX_KEY_LEN   1024    // key 最大长度
#define CACHE_MAX_VALUE_LEN (1024*1024) // value 最大 1MB
#define CACHE_MAX_MEMORY_DEFAULT (100*1024*1024) // 默认 100MB

// ====== 句柄（不透明）======
typedef struct cache cache_t;
typedef struct cache_iter cache_iter_t;

// ====== 搜索结果结构（借鉴 code_bin query_result_t）======
typedef struct {
    const char* key;        // key（指向 pool 数据，不拷贝）
    const char* value;      // value（JSON 格式）
    double score;           // 相关性评分（0-1，1=完全匹配）
} cache_result_t;

// ====== 搜索选项（借鉴 code_bin query_options_t）======
typedef struct {
    int max_results;        // 最大返回数量（0 = 无限制）
    int case_sensitive;     // 大小写敏感（默认 0）
    const char* ns_filter;  // namespace 过滤（可选）
    const char* query_text; // 原始查询文本（用于混合评分，可选）
} cache_search_options_t;

// ====== 默认搜索选项 ======
static inline cache_search_options_t cache_search_options_default(void) {
    return (cache_search_options_t){
        .max_results = 100,     // 默认最多返回 100 条
        .case_sensitive = 0,    // 默认不区分大小写
        .ns_filter = NULL       // 默认不过滤
    };
}

// ====== 生命周期 ======
cache_t* cache_open(const char* db_dir, size_t max_memory);
void cache_close(cache_t* cache);
int cache_sync(cache_t* cache);

// ====== 基础 CRUD ======
int cache_set(cache_t* cache, const char* key, const char* value, uint64_t ttl_ms);
const char* cache_get(cache_t* cache, const char* key);  // 返回指针，不拷贝，NULL = 不存在或过期
int cache_del(cache_t* cache, const char* key);
int cache_exists(cache_t* cache, const char* key);

// ====== 批量操作 ======
typedef struct {
    const char* key;
    const char* value;
    uint64_t ttl_ms;
} cache_batch_item_t;

// 批量设置（性能优化：避免排序数组 O(n) 多次移动）
int cache_batch_set(cache_t* cache, const cache_batch_item_t* items, size_t count);

// ====== 统计信息 ======
size_t cache_count(cache_t* cache);
size_t cache_memory_used(cache_t* cache);
size_t cache_memory_max(cache_t* cache);

// ====== 搜索（核心功能）======
// 前缀搜索：key 以 prefix 开头
int cache_search_prefix(cache_t* cache, const char* prefix,
                        const cache_search_options_t* options,
                        cache_result_t** out_results, size_t* out_count);

// 范围搜索：[start_key, end_key)
int cache_search_range(cache_t* cache, const char* start_key, const char* end_key,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count);

// 正则搜索（POSIX 扩展正则）
int cache_search_regex(cache_t* cache, const char* pattern,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count);

// 模糊搜索（Levenshtein 距离）
int cache_search_fuzzy(cache_t* cache, const char* query,
                       const cache_search_options_t* options,
                       cache_result_t** out_results, size_t* out_count);

// 标签搜索：搜索 value JSON 中包含指定标签的 entry
int cache_search_tag(cache_t* cache, const char* tag,
                     const cache_search_options_t* options,
                     cache_result_t** out_results, size_t* out_count);

// 释放搜索结果
void cache_results_free(cache_result_t* results);

// ====== 迭代器（借鉴 code_bin hashmap_iter）======
cache_iter_t* cache_iter_create(cache_t* cache);
void cache_iter_destroy(cache_iter_t* iter);

// 遍历所有 entry（按 key 字典序）
int cache_iter_next(cache_iter_t* iter, const char** key_out, const char** value_out);

// 遍历指定 namespace 下的 entry
int cache_iter_ns_next(cache_iter_t* iter, const char* ns_prefix,
                       const char** key_out, const char** value_out);

// 重置迭代器到开始位置
void cache_iter_reset(cache_iter_t* iter);

// ====== Namespace 便捷操作 ======
// 在指定 namespace 内设置 key（自动拼接 namespace + key）
int cache_set_ns(cache_t* cache, const char* ns, const char* key, 
                 const char* value, uint64_t ttl_ms);

// 在指定 namespace 内获取 key
const char* cache_get_ns(cache_t* cache, const char* ns, const char* key);

// 在指定 namespace 内删除 key
int cache_del_ns(cache_t* cache, const char* ns, const char* key);

// 删除整个 namespace 及其下所有 entry
int cache_del_namespace(cache_t* cache, const char* ns);

// ====== 生命周期管理 ======
// 立即过期某个 key
int cache_expire(cache_t* cache, const char* key);

// 更新 access_time（手动触发 LRU 更新）
int cache_touch(cache_t* cache, const char* key);

// 物理清理过期/删除的条目，回收空间
size_t cache_compact(cache_t* cache);

// 清理所有过期条目（返回清理数量）
size_t cache_purge_expired(cache_t* cache);

// 诊断：检查 cache 文件完整性
int cache_check(const char* db_dir);

// ====== 源码语义分析（轻量级 AST 提取）======
// AST 节点类型
typedef enum {
    CACHE_AST_FUNCTION,
    CACHE_AST_CLASS,
    CACHE_AST_STRUCT,
    CACHE_AST_VARIABLE,
    CACHE_AST_IMPORT,
    CACHE_AST_COMMENT,
} cache_ast_node_type_t;

// AST 树（不透明）
typedef struct cache_ast_tree cache_ast_tree_t;

// 分析源代码，提取 AST 信息
// filename: 用于检测语言（.c, .py, .js 等）
// source: 源代码内容
cache_ast_tree_t* cache_analyze_source(const char* filename, const char* source);

// 将 AST 序列化为 JSON 字符串（调用者负责 free）
char* cache_ast_to_json(const cache_ast_tree_t* tree, const char* filename);

// 从 AST 提取语义标签（func:name class:name 格式，用于 tag 索引）
int cache_ast_extract_tags(const char* filename, const char* source,
                           char** out_tags, size_t* out_tag_count);

// 语义搜索：在 AST JSON 中搜索特定符号
int cache_search_ast(cache_t* cache, const char* query, cache_ast_node_type_t type_filter,
                     cache_search_options_t* options,
                     cache_result_t** out_results, size_t* out_count);

// 释放 AST 树
void cache_ast_free(cache_ast_tree_t* tree);

// ====== 向量搜索 ======
// 设置带向量嵌入的 key-value
// vector: float 数组，dim 维度（常用 384/768/1536）
int cache_set_vector(cache_t* cache, const char* key, const char* value,
                     const float* vector, size_t dim, uint64_t ttl_ms);

// 向量相似度搜索（暴力精确搜索，O(n)，适合 < 10万条）
// query_vector: 查询向量
// top_k: 返回最相似的 k 个结果
// min_score: 最小相似度阈值（0-1，cosine similarity，1=完全相同）
int cache_search_vector(cache_t* cache, const float* query_vector, size_t dim,
                        int top_k, double min_score,
                        cache_search_options_t* options,
                        cache_result_t** out_results, size_t* out_count);

// 获取 entry 的向量（NULL = 无向量）
const float* cache_get_vector(cache_t* cache, const char* key, size_t* out_dim);

#ifdef __cplusplus
}
#endif

#endif /* CACHE_H */