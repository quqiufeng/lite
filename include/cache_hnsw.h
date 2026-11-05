#ifndef CACHE_HNSW_H
#define CACHE_HNSW_H

#include "cache.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ====== HNSW 配置 ======
#define HNSW_DEFAULT_M 16
#define HNSW_DEFAULT_EF_CONSTRUCTION 200
#define HNSW_DEFAULT_EF_SEARCH 50
#define HNSW_MAX_LEVEL 16

// ====== HNSW 索引（不透明）=====
typedef struct hnsw_index hnsw_index_t;

// ====== HNSW 生命周期 ======
// 创建 HNSW 索引
// dim: 向量维度，所有向量必须同维度
hnsw_index_t* hnsw_create(size_t dim);

// 销毁 HNSW 索引
void hnsw_destroy(hnsw_index_t* index);

// ====== HNSW 配置 ======
// 设置参数（创建后、插入前调用）
void hnsw_set_m(hnsw_index_t* index, int M);
void hnsw_set_ef_construction(hnsw_index_t* index, int ef);
void hnsw_set_ef_search(hnsw_index_t* index, int ef);

// ====== HNSW 操作 ======
// 插入向量
// id: 用户自定义 ID（对应 cache entry_offset）
// vector: float 数组，长度 = dim
int hnsw_insert(hnsw_index_t* index, size_t id, const float* vector);

// 线程安全并行插入（用于批量构建）
int hnsw_insert_parallel(hnsw_index_t* index, size_t id, const float* vector);

// 预分配节点容量（用于并行构建前）
int hnsw_reserve(hnsw_index_t* index, size_t n);

// 删除向量（软删除，标记为无效）
void hnsw_remove(hnsw_index_t* index, size_t id);

// 搜索最近邻
// query: 查询向量
// top_k: 返回最相似的 k 个结果
// out_ids: 输出 ID 数组（malloc 分配，调用者 free）
// out_scores: 输出分数数组（malloc 分配，调用者 free）
// 返回找到的结果数量
size_t hnsw_search(hnsw_index_t* index, const float* query, int top_k,
                   size_t** out_ids, float** out_scores);

// 暴力精确搜索（用于验证和少量数据 fallback）
size_t hnsw_search_exact(hnsw_index_t* index, const float* query, int top_k,
                         size_t** out_ids, float** out_scores);

// ====== 统计 ======
size_t hnsw_count(const hnsw_index_t* index);
size_t hnsw_memory_usage(const hnsw_index_t* index);
int hnsw_get_ef_search(const hnsw_index_t* index);

// ====== 持久化 ======
// 计算序列化所需大小
size_t hnsw_serialize_size(const hnsw_index_t* index);

// 序列化到缓冲区
// 返回写入的字节数，失败返回 0
size_t hnsw_serialize(const hnsw_index_t* index, void* buf, size_t buf_size);

// 从缓冲区反序列化
// 返回新创建的索引，失败返回 NULL
hnsw_index_t* hnsw_deserialize(const void* buf, size_t buf_size);

#ifdef __cplusplus
}
#endif

#endif /* CACHE_HNSW_H */
