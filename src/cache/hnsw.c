#include "cache_hnsw.h"
#include "cache_internal.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

// ====== 优先队列（最小堆）======

typedef struct {
    size_t id;
    float dist;
} pq_item_t;

typedef struct {
    pq_item_t* items;
    size_t count;
    size_t capacity;
} min_pq_t;

static min_pq_t* pq_create(size_t capacity) {
    min_pq_t* pq = malloc(sizeof(min_pq_t));
    if (!pq) return NULL;
    pq->items = malloc(sizeof(pq_item_t) * capacity);
    if (!pq->items) { free(pq); return NULL; }
    pq->count = 0;
    pq->capacity = capacity;
    return pq;
}

static void pq_destroy(min_pq_t* pq) {
    if (!pq) return;
    free(pq->items);
    free(pq);
}

static void pq_push(min_pq_t* pq, size_t id, float dist) {
    if (pq->count >= pq->capacity) return;
    size_t i = pq->count++;
    while (i > 0) {
        size_t parent = (i - 1) / 2;
        if (pq->items[parent].dist <= dist) break;
        pq->items[i] = pq->items[parent];
        i = parent;
    }
    pq->items[i].id = id;
    pq->items[i].dist = dist;
}

static int pq_pop(min_pq_t* pq, size_t* out_id, float* out_dist) {
    if (pq->count == 0) return 0;
    *out_id = pq->items[0].id;
    *out_dist = pq->items[0].dist;
    pq_item_t last = pq->items[--pq->count];
    size_t i = 0;
    while (1) {
        size_t left = i * 2 + 1;
        size_t right = left + 1;
        size_t smallest = i;
        if (left < pq->count && pq->items[left].dist < pq->items[smallest].dist)
            smallest = left;
        if (right < pq->count && pq->items[right].dist < pq->items[smallest].dist)
            smallest = right;
        if (smallest == i) break;
        pq->items[i] = pq->items[smallest];
        i = smallest;
    }
    pq->items[i] = last;
    return 1;
}

// ====== HNSW 数据结构 ======

typedef struct {
    size_t* ids;
    size_t count;
    size_t capacity;
} neighbor_list_t;

typedef struct {
    size_t id;
    float* vector;
    int level;
    int valid;  // 0 = 已删除
    neighbor_list_t* neighbors;  // neighbors[0..level]
} hnsw_node_impl_t;

struct hnsw_index {
    size_t dim;
    int M;
    int M_max;
    int ef_construction;
    int ef_search;
    float mL;
    
    hnsw_node_impl_t* nodes;
    size_t node_count;
    size_t node_capacity;
    
    // 连续向量存储池（提升 cache locality，减少 malloc 碎片）
    float* vector_pool;
    size_t vector_pool_capacity;  // 按 float 计数
    
    int max_level;
    size_t entry_point;
    
    // 删除节点复用
    size_t* free_list;
    size_t free_count;
    size_t free_capacity;
    
    // 缓存有效节点数（避免每次搜索遍历）
    size_t valid_count;
    int valid_count_dirty;  // 1 = 需要重新计算
    
    // 搜索优化：epoch-based visited array
    uint32_t* visited_epochs;
    uint32_t current_epoch;
};

// 确保 vector_pool 有足够容量，并更新所有 node 的 vector 指针
static int ensure_vector_pool_capacity(hnsw_index_t* idx, size_t n) {
    size_t need = n * idx->dim;
    if (need <= idx->vector_pool_capacity) return CACHE_OK;
    
    size_t new_cap = need * 2;
    if (new_cap < 64 * idx->dim) new_cap = 64 * idx->dim;
    
    float* new_pool = realloc(idx->vector_pool, sizeof(float) * new_cap);
    if (!new_pool) return CACHE_ERR_NOMEM;
    
    idx->vector_pool = new_pool;
    idx->vector_pool_capacity = new_cap;
    
    // realloc 后地址可能改变，更新所有有效 node 的 vector 指针
    for (size_t i = 0; i < idx->node_count; i++) {
        if (idx->nodes[i].valid) {
            idx->nodes[i].vector = idx->vector_pool + i * idx->dim;
        }
    }
    
    return CACHE_OK;
}

// ====== 距离计算 ======

// 余弦距离 = 1 - cosine_similarity
// 输入向量已归一化，cosine_similarity = dot(a,b) / (|a||b|) = dot(a,b)
// 返回距离（越小越近），用于 HNSW 构建和搜索
static float hnsw_distance(const hnsw_index_t* idx, const float* a, const float* b) {
    // 输入向量已归一化：cosine_similarity = dot(a,b) / (|a||b|) = dot(a,b)
    // 直接返回 1 - dot_product 作为距离（越小越近）
    // SIMD：768 维点积是构建/搜索的热点，用 omp simd reduction 向量化（-O2 默认不向量化归约）
    float dot = 0.0f;
    #pragma omp simd reduction(+:dot)
    for (size_t i = 0; i < idx->dim; i++) {
        dot += a[i] * b[i];
    }
    return 1.0f - dot;
}

// ====== 随机层数生成 ======

static unsigned int hnsw_rng_state = 12345;

static float hnsw_random(void) {
    hnsw_rng_state = hnsw_rng_state * 1103515245 + 12345;
    return (float)(hnsw_rng_state & 0x7fffffff) / (float)0x7fffffff;
}

static int hnsw_random_level(hnsw_index_t* idx) {
    float r = hnsw_random();
    if (r <= 0.0f) r = 1e-10f;
    int level = (int)(-logf(r) * idx->mL);
    if (level < 0) level = 0;
    if (level > HNSW_MAX_LEVEL) level = HNSW_MAX_LEVEL;
    return level;
}

// Thread-safe random level generation
static float hnsw_random_ts(unsigned int* state) {
    *state = *state * 1103515245 + 12345;
    return (float)(*state & 0x7fffffff) / (float)0x7fffffff;
}

static int hnsw_random_level_ts(hnsw_index_t* idx, unsigned int* state) {
    float r = hnsw_random_ts(state);
    if (r <= 0.0f) r = 1e-10f;
    int level = (int)(-logf(r) * idx->mL);
    if (level < 0) level = 0;
    if (level > HNSW_MAX_LEVEL) level = HNSW_MAX_LEVEL;
    return level;
}

// ====== 邻居列表操作 ======

static int neighbor_list_init(neighbor_list_t* list, size_t capacity) {
    list->ids = malloc(sizeof(size_t) * capacity);
    if (!list->ids) return -1;
    list->count = 0;
    list->capacity = capacity;
    return 0;
}

static void neighbor_list_destroy(neighbor_list_t* list) {
    if (list->ids) free(list->ids);
    list->ids = NULL;
    list->count = 0;
    list->capacity = 0;
}

static int neighbor_list_add(neighbor_list_t* list, size_t id) {
    if (list->count >= list->capacity) return -1;
    list->ids[list->count++] = id;
    return 0;
}

// ====== 核心算法：单层贪心搜索 ======

// 返回最近节点的索引
static size_t hnsw_greedy_search_layer(hnsw_index_t* idx, const float* query,
                                       size_t entry_id, int level) {
    size_t curr = entry_id;
    float curr_dist = hnsw_distance(idx, query, idx->nodes[curr].vector);
    
    int changed = 1;
    while (changed) {
        changed = 0;
        hnsw_node_impl_t* node = &idx->nodes[curr];
        if (level > node->level) continue;
        
        neighbor_list_t* nb = &node->neighbors[level];
        for (size_t i = 0; i < nb->count; i++) {
            size_t nid = nb->ids[i];
            if (!idx->nodes[nid].valid) continue;
            float d = hnsw_distance(idx, query, idx->nodes[nid].vector);
            if (d < curr_dist) {
                curr_dist = d;
                curr = nid;
                changed = 1;
            }
        }
    }
    return curr;
}

// 简单的 ef 最近搜索（单层）
// 返回找到的最近节点数量（最多 ef 个）
static int hnsw_search_layer_nearest(hnsw_index_t* idx, const float* query,
                                     size_t entry_id, int level, int ef,
                                     size_t* out_ids, float* out_dists) {
    // BFS + 维护 ef 个最近节点
    min_pq_t* candidates = pq_create(ef * 2 + 1);
    
    // 使用 epoch-based visited array 避免每次 calloc
    if (idx->node_capacity > 0 && (!idx->visited_epochs || idx->node_capacity > 0)) {
        uint32_t* new_epochs = realloc(idx->visited_epochs, sizeof(uint32_t) * idx->node_capacity);
        if (new_epochs) {
            // 新分配的部分初始化为 0
            if (idx->visited_epochs) {
                // 扩展：只需清零新增部分
                // 但这里我们不知道旧容量，简单清零全部
            }
            idx->visited_epochs = new_epochs;
            memset(idx->visited_epochs, 0, sizeof(uint32_t) * idx->node_capacity);
        }
    }
    
    uint32_t epoch = ++idx->current_epoch;
    if (epoch == 0) {
        // 溢出：重置所有 epoch
        if (idx->visited_epochs) {
            memset(idx->visited_epochs, 0, sizeof(uint32_t) * idx->node_capacity);
        }
        epoch = idx->current_epoch = 1;
    }
    
    float entry_dist = hnsw_distance(idx, query, idx->nodes[entry_id].vector);
    pq_push(candidates, entry_id, entry_dist);
    if (idx->visited_epochs && entry_id < idx->node_capacity) {
        idx->visited_epochs[entry_id] = epoch;
    }
    
    int found = 0;
    
    while (candidates->count > 0 && found < ef) {
        size_t curr_id;
        float curr_dist;
        pq_pop(candidates, &curr_id, &curr_dist);
        
        hnsw_node_impl_t* node = &idx->nodes[curr_id];
        if (level > node->level) continue;
        
        out_ids[found] = curr_id;
        out_dists[found] = curr_dist;
        found++;
        
        neighbor_list_t* nb = &node->neighbors[level];
        for (size_t i = 0; i < nb->count; i++) {
            size_t nid = nb->ids[i];
            if (nid >= idx->node_capacity) continue;
            if (idx->visited_epochs && idx->visited_epochs[nid] == epoch) continue;
            if (!idx->nodes[nid].valid) continue;
            if (idx->visited_epochs) idx->visited_epochs[nid] = epoch;
            
            float d = hnsw_distance(idx, query, idx->nodes[nid].vector);
            pq_push(candidates, nid, d);
        }
    }
    
    pq_destroy(candidates);
    return found;
}

// ====== 公共 API 实现 ======

hnsw_index_t* hnsw_create(size_t dim) {
    if (dim == 0 || dim > CACHE_MAX_VECTOR_DIM) return NULL;
    
    hnsw_index_t* idx = calloc(1, sizeof(hnsw_index_t));
    if (!idx) return NULL;
    
    idx->dim = dim;
    idx->M = HNSW_DEFAULT_M;
    idx->M_max = HNSW_DEFAULT_M * 2;
    idx->ef_construction = HNSW_DEFAULT_EF_CONSTRUCTION;
    idx->ef_search = HNSW_DEFAULT_EF_SEARCH;
    idx->mL = 1.0f / logf((float)idx->M);
    
    idx->node_capacity = 64;
    idx->nodes = calloc(idx->node_capacity, sizeof(hnsw_node_impl_t));
    if (!idx->nodes) {
        free(idx);
        return NULL;
    }
    
    // 预分配连续向量池
    idx->vector_pool_capacity = idx->node_capacity * dim;
    idx->vector_pool = calloc(idx->vector_pool_capacity, sizeof(float));
    if (!idx->vector_pool) {
        free(idx->nodes);
        free(idx);
        return NULL;
    }
    
    idx->max_level = -1;
    idx->entry_point = (size_t)-1;
    idx->valid_count = 0;
    idx->valid_count_dirty = 0;
    idx->visited_epochs = NULL;
    idx->current_epoch = 1;
    
    return idx;
}

void hnsw_destroy(hnsw_index_t* idx) {
    if (!idx) return;
    
    for (size_t i = 0; i < idx->node_count; i++) {
        hnsw_node_impl_t* node = &idx->nodes[i];
        // vector 由统一 pool 管理，不单独释放
        if (node->neighbors) {
            for (int l = 0; l <= node->level; l++) {
                neighbor_list_destroy(&node->neighbors[l]);
            }
            free(node->neighbors);
        }
    }
    free(idx->nodes);
    free(idx->vector_pool);  // 统一释放连续向量池
    free(idx->free_list);
    free(idx->visited_epochs);
    free(idx);
}

void hnsw_set_m(hnsw_index_t* idx, int M) {
    if (!idx || M <= 0) return;
    idx->M = M;
    idx->M_max = M * 2;
    idx->mL = 1.0f / logf((float)M);
}

void hnsw_set_ef_construction(hnsw_index_t* idx, int ef) {
    if (!idx || ef <= 0) return;
    idx->ef_construction = ef;
}

void hnsw_set_ef_search(hnsw_index_t* idx, int ef) {
    if (!idx || ef <= 0) return;
    idx->ef_search = ef;
}

// ====== 预分配容量（用于并行构建）======

int hnsw_reserve(hnsw_index_t* idx, size_t n) {
    if (!idx) return CACHE_ERR_INVAL;
    if (n <= idx->node_capacity) return CACHE_OK;
    
    hnsw_node_impl_t* new_nodes = realloc(idx->nodes, sizeof(hnsw_node_impl_t) * n);
    if (!new_nodes) return CACHE_ERR_NOMEM;
    memset(&new_nodes[idx->node_capacity], 0, sizeof(hnsw_node_impl_t) * (n - idx->node_capacity));
    idx->nodes = new_nodes;
    idx->node_capacity = n;
    
    // 同步扩容连续向量池
    int ret = ensure_vector_pool_capacity(idx, n);
    if (ret != CACHE_OK) return ret;
    
    uint32_t* new_epochs = realloc(idx->visited_epochs, sizeof(uint32_t) * n);
    if (new_epochs) {
        memset(&new_epochs[idx->node_count], 0, sizeof(uint32_t) * (n - idx->node_count));
        idx->visited_epochs = new_epochs;
    }
    
    return CACHE_OK;
}

// ====== 插入 ======

int hnsw_insert(hnsw_index_t* idx, size_t id, const float* vector) {
    if (!idx || !vector) return CACHE_ERR_INVAL;
    
    // 检查是否已存在
    for (size_t i = 0; i < idx->node_count; i++) {
        if (idx->nodes[i].id == id) {
            if (idx->nodes[i].valid) return CACHE_ERR_EXIST;
            // 复用已删除的节点
            memcpy(idx->nodes[i].vector, vector, sizeof(float) * idx->dim);
            idx->nodes[i].valid = 1;
            idx->valid_count++;
            return CACHE_OK;
        }
    }
    
    // 分配新节点
    size_t node_idx;
    if (idx->free_count > 0) {
        node_idx = idx->free_list[--idx->free_count];
    } else {
        if (idx->node_count >= idx->node_capacity) {
            size_t new_cap = idx->node_capacity * 2;
            hnsw_node_impl_t* new_nodes = realloc(idx->nodes, sizeof(hnsw_node_impl_t) * new_cap);
            if (!new_nodes) return CACHE_ERR_NOMEM;
            idx->nodes = new_nodes;
            memset(&idx->nodes[idx->node_capacity], 0, sizeof(hnsw_node_impl_t) * (new_cap - idx->node_capacity));
            idx->node_capacity = new_cap;
            
            // 同步扩容连续向量池
            int ret = ensure_vector_pool_capacity(idx, new_cap);
            if (ret != CACHE_OK) return ret;
        }
        node_idx = idx->node_count++;
    }
    
    hnsw_node_impl_t* node = &idx->nodes[node_idx];
    node->id = id;
    // 从统一 pool 分配向量（提升 cache locality）
    node->vector = idx->vector_pool + node_idx * idx->dim;
    memcpy(node->vector, vector, sizeof(float) * idx->dim);
    node->level = hnsw_random_level(idx);
    node->valid = 1;
    idx->valid_count++;
    
    // 分配邻居列表
    node->neighbors = calloc(node->level + 1, sizeof(neighbor_list_t));
    if (!node->neighbors) {
        // 不清空 vector，由 pool 统一管理
        node->valid = 0;
        idx->valid_count--;
        return CACHE_ERR_NOMEM;
    }
    
    int M = idx->M;
    for (int l = 0; l <= node->level; l++) {
        int cap = (l == 0) ? idx->M_max : M;
        if (neighbor_list_init(&node->neighbors[l], cap) < 0) {
            for (int j = 0; j < l; j++) {
                neighbor_list_destroy(&node->neighbors[j]);
            }
            free(node->neighbors);
            node->neighbors = NULL;
            node->valid = 0;
            idx->valid_count--;
            return CACHE_ERR_NOMEM;
        }
    }
    
    // 第一个节点：直接设为 entry point
    if (idx->entry_point == (size_t)-1) {
        idx->entry_point = node_idx;
        idx->max_level = node->level;
        return CACHE_OK;
    }
    
    // 搜索每层最近邻居
    size_t curr_ep = idx->entry_point;
    int top_level = idx->max_level;
    
    // 1. 从顶层下降到新节点的层数+1
    for (int lc = top_level; lc > node->level; lc--) {
        curr_ep = hnsw_greedy_search_layer(idx, vector, curr_ep, lc);
    }
    
    // 2. 从 min(node_level, max_level) 下降到 0，每层搜索最近邻居
    for (int lc = (node->level < top_level ? node->level : top_level); lc >= 0; lc--) {
        // 搜索该层最近 ef_construction 个邻居
        size_t* nearest_ids = malloc(sizeof(size_t) * idx->ef_construction);
        float* nearest_dists = malloc(sizeof(float) * idx->ef_construction);
        if (!nearest_ids || !nearest_dists) {
            free(nearest_ids);
            free(nearest_dists);
            continue;
        }
        
        int found = hnsw_search_layer_nearest(idx, vector, curr_ep, lc, 
                                               idx->ef_construction, nearest_ids, nearest_dists);
        
        // 选择最近的 M 个邻居（第0层用 M_max）
        int max_neighbors = (lc == 0) ? idx->M_max : M;
        
        // 取最近的 max_neighbors 个（nearest_ids 已按距离升序）
        int selected = 0;
        for (int i = 0; i < found && selected < max_neighbors; i++) {
            size_t nid = nearest_ids[i];
            if (nid == node_idx) continue;  // 跳过自己
            
            // 双向连接
            neighbor_list_add(&node->neighbors[lc], nid);
            
            // 检查对方是否已满，如果满则移除最远的
            hnsw_node_impl_t* nb_node = &idx->nodes[nid];
            if (lc <= nb_node->level) {
                if (nb_node->neighbors[lc].count >= (size_t)max_neighbors) {
                    // 找到最远的邻居并移除
                    float max_d = 0;
                    size_t max_i = 0;
                    for (size_t j = 0; j < nb_node->neighbors[lc].count; j++) {
                        size_t other = nb_node->neighbors[lc].ids[j];
                        float d = hnsw_distance(idx, nb_node->vector, idx->nodes[other].vector);
                        if (d > max_d) {
                            max_d = d;
                            max_i = j;
                        }
                    }
                    // 如果新节点更近，替换最远的
                    float d_new = nearest_dists[i];
                    if (d_new < max_d) {
                        // 移除最远
                        nb_node->neighbors[lc].ids[max_i] = nb_node->neighbors[lc].ids[--nb_node->neighbors[lc].count];
                        neighbor_list_add(&nb_node->neighbors[lc], node_idx);
                    }
                } else {
                    neighbor_list_add(&nb_node->neighbors[lc], node_idx);
                }
            }
            
            selected++;
        }
        
        // 更新 curr_ep 为下一层的入口（最近的那个）
        if (found > 0) {
            curr_ep = nearest_ids[0];
        }
        
        free(nearest_ids);
        free(nearest_dists);
    }
    
    // 更新 entry point 和 max level
    if (node->level > idx->max_level) {
        idx->max_level = node->level;
        idx->entry_point = node_idx;
    }
    
    return CACHE_OK;
}

// ====== 并行插入（线程安全，用于批量构建）======

int hnsw_insert_parallel(hnsw_index_t* idx, size_t id, const float* vector) {
    if (!idx || !vector) return CACHE_ERR_INVAL;
    
    // 原子分配 node_idx
    size_t node_idx = __atomic_fetch_add(&idx->node_count, 1, __ATOMIC_SEQ_CST);
    if (node_idx >= idx->node_capacity) {
        // 回滚
        __atomic_fetch_sub(&idx->node_count, 1, __ATOMIC_SEQ_CST);
        return CACHE_ERR_NOMEM;
    }
    
    hnsw_node_impl_t* node = &idx->nodes[node_idx];
    node->id = id;
    node->vector = malloc(sizeof(float) * idx->dim);
    if (!node->vector) {
        node->valid = 0;
        return CACHE_ERR_NOMEM;
    }
    memcpy(node->vector, vector, sizeof(float) * idx->dim);
    
    // 线程安全随机数：用 id 作为 seed
    unsigned int rng_state = (unsigned int)(id + 12345);
    node->level = hnsw_random_level_ts(idx, &rng_state);
    node->valid = 1;
    __atomic_fetch_add(&idx->valid_count, 1, __ATOMIC_RELAXED);
    
    // 分配邻居列表
    node->neighbors = calloc(node->level + 1, sizeof(neighbor_list_t));
    if (!node->neighbors) {
        free(node->vector);
        node->vector = NULL;
        node->valid = 0;
        return CACHE_ERR_NOMEM;
    }
    
    int M = idx->M;
    for (int l = 0; l <= node->level; l++) {
        int cap = (l == 0) ? idx->M_max : M;
        if (neighbor_list_init(&node->neighbors[l], cap) < 0) {
            for (int j = 0; j < l; j++) {
                neighbor_list_destroy(&node->neighbors[j]);
            }
            free(node->neighbors);
            free(node->vector);
            node->vector = NULL;
            node->valid = 0;
            return CACHE_ERR_NOMEM;
        }
    }
    
    // 第一个节点：设为 entry point
    int is_first = 0;
    #pragma omp critical(hnsw_ep)
    {
        if (idx->entry_point == (size_t)-1) {
            idx->entry_point = node_idx;
            idx->max_level = node->level;
            is_first = 1;
        }
    }
    if (is_first) return CACHE_OK;
    
    // 获取当前 entry point（可能已被其他线程更新）
    size_t curr_ep;
    int top_level;
    #pragma omp critical(hnsw_ep)
    {
        curr_ep = idx->entry_point;
        top_level = idx->max_level;
    }
    
    // 1. 从顶层下降到新节点的层数+1（读操作，无竞争）
    for (int lc = top_level; lc > node->level; lc--) {
        curr_ep = hnsw_greedy_search_layer(idx, vector, curr_ep, lc);
    }
    
    // 2. 每层搜索最近邻居并连接
    for (int lc = (node->level < top_level ? node->level : top_level); lc >= 0; lc--) {
        size_t* nearest_ids = malloc(sizeof(size_t) * idx->ef_construction);
        float* nearest_dists = malloc(sizeof(float) * idx->ef_construction);
        if (!nearest_ids || !nearest_dists) {
            free(nearest_ids);
            free(nearest_dists);
            continue;
        }
        
        int found = hnsw_search_layer_nearest(idx, vector, curr_ep, lc,
                                               idx->ef_construction, nearest_ids, nearest_dists);
        
        int max_neighbors = (lc == 0) ? idx->M_max : M;
        int selected = 0;
        
        for (int i = 0; i < found && selected < max_neighbors; i++) {
            size_t nid = nearest_ids[i];
            if (nid == node_idx) continue;
            
            // 新节点的邻居列表（只有自己访问，无竞争）
            neighbor_list_add(&node->neighbors[lc], nid);
            
            // 已有邻居的邻居列表修改（需要 critical section）
            #pragma omp critical(hnsw_conn)
            {
                hnsw_node_impl_t* nb_node = &idx->nodes[nid];
                if (lc <= nb_node->level) {
                    if (nb_node->neighbors[lc].count >= (size_t)max_neighbors) {
                        float max_d = 0;
                        size_t max_i = 0;
                        for (size_t j = 0; j < nb_node->neighbors[lc].count; j++) {
                            size_t other = nb_node->neighbors[lc].ids[j];
                            float d = hnsw_distance(idx, nb_node->vector, idx->nodes[other].vector);
                            if (d > max_d) {
                                max_d = d;
                                max_i = j;
                            }
                        }
                        float d_new = nearest_dists[i];
                        if (d_new < max_d) {
                            nb_node->neighbors[lc].ids[max_i] = nb_node->neighbors[lc].ids[--nb_node->neighbors[lc].count];
                            neighbor_list_add(&nb_node->neighbors[lc], node_idx);
                        }
                    } else {
                        neighbor_list_add(&nb_node->neighbors[lc], node_idx);
                    }
                }
            }
            
            selected++;
        }
        
        if (found > 0) {
            curr_ep = nearest_ids[0];
        }
        
        free(nearest_ids);
        free(nearest_dists);
    }
    
    // 更新 entry point（如果新节点 level 更高）
    if (node->level > top_level) {
        #pragma omp critical(hnsw_ep)
        {
            if (node->level > idx->max_level) {
                idx->max_level = node->level;
                idx->entry_point = node_idx;
            }
        }
    }
    
    return CACHE_OK;
}

// ====== 删除 ======

void hnsw_remove(hnsw_index_t* idx, size_t id) {
    if (!idx) return;
    
    for (size_t i = 0; i < idx->node_count; i++) {
        if (idx->nodes[i].id == id && idx->nodes[i].valid) {
            idx->nodes[i].valid = 0;
            if (idx->valid_count > 0) idx->valid_count--;
            
            // 加入 free list
            if (idx->free_count >= idx->free_capacity) {
                size_t new_cap = idx->free_capacity == 0 ? 16 : idx->free_capacity * 2;
                size_t* new_list = realloc(idx->free_list, sizeof(size_t) * new_cap);
                if (new_list) {
                    idx->free_list = new_list;
                    idx->free_capacity = new_cap;
                }
            }
            if (idx->free_count < idx->free_capacity) {
                idx->free_list[idx->free_count++] = i;
            }
            break;
        }
    }
}

// ====== 搜索 ======

size_t hnsw_search(hnsw_index_t* idx, const float* query, int top_k,
                   size_t** out_ids, float** out_scores) {
    if (!idx || !query || top_k <= 0 || !out_ids || !out_scores) return 0;
    
    *out_ids = NULL;
    *out_scores = NULL;
    
    if (idx->node_count == 0 || idx->entry_point == (size_t)-1) return 0;
    
    // 少量数据 fallback 到暴力搜索（< 1000 条）
    if (idx->valid_count < 1000) {
        return hnsw_search_exact(idx, query, top_k, out_ids, out_scores);
    }
    
    // HNSW 近似搜索
    size_t curr_ep = idx->entry_point;
    int top_level = idx->max_level;
    
    // 1. 从顶层贪心下降
    for (int lc = top_level; lc > 0; lc--) {
        curr_ep = hnsw_greedy_search_layer(idx, query, curr_ep, lc);
    }
    
    // 2. 第0层搜索 ef_search 个最近邻居
    int ef = (idx->ef_search > top_k) ? idx->ef_search : top_k;
    size_t* nearest_ids = malloc(sizeof(size_t) * ef);
    float* nearest_dists = malloc(sizeof(float) * ef);
    if (!nearest_ids || !nearest_dists) {
        free(nearest_ids);
        free(nearest_dists);
        return 0;
    }
    
    int found = hnsw_search_layer_nearest(idx, query, curr_ep, 0, ef, nearest_ids, nearest_dists);
    
    // 收集结果
    size_t result_count = (found < top_k) ? (size_t)found : (size_t)top_k;
    if (result_count == 0) {
        free(nearest_ids);
        free(nearest_dists);
        return 0;
    }
    
    *out_ids = malloc(sizeof(size_t) * result_count);
    *out_scores = malloc(sizeof(float) * result_count);
    if (!*out_ids || !*out_scores) {
        free(*out_ids);
        free(*out_scores);
        free(nearest_ids);
        free(nearest_dists);
        return 0;
    }
    
    // nearest_ids 已按距离升序
    for (size_t i = 0; i < result_count; i++) {
        (*out_ids)[i] = idx->nodes[nearest_ids[i]].id;
        (*out_scores)[i] = 1.0f - nearest_dists[i];
    }
    
    free(nearest_ids);
    free(nearest_dists);
    
    return result_count;
}

// ====== 暴力精确搜索 ======

size_t hnsw_search_exact(hnsw_index_t* idx, const float* query, int top_k,
                         size_t** out_ids, float** out_scores) {
    if (!idx || !query || top_k <= 0 || !out_ids || !out_scores) return 0;
    
    *out_ids = NULL;
    *out_scores = NULL;
    
    if (idx->node_count == 0) return 0;
    
    // 分配分数数组
    typedef struct {
        size_t id;
        float dist;
    } score_t;
    
    score_t* scores = malloc(sizeof(score_t) * idx->node_count);
    if (!scores) return 0;
    
    size_t count = 0;
    for (size_t i = 0; i < idx->node_count; i++) {
        if (!idx->nodes[i].valid) continue;
        scores[count].id = idx->nodes[i].id;
        scores[count].dist = hnsw_distance(idx, query, idx->nodes[i].vector);
        count++;
    }
    
    if (count == 0) {
        free(scores);
        return 0;
    }
    
    // 按距离排序（升序）
    if (count > 1) {
        // 使用 qsort 进行全量排序，然后取前 top_k
        // 对于小规模数据，qsort 开销可忽略；对于大规模数据，比选择排序快
        int compare_score(const void* a, const void* b) {
            float da = ((const score_t*)a)->dist;
            float db = ((const score_t*)b)->dist;
            return (da < db) ? -1 : (da > db) ? 1 : 0;
        }
        qsort(scores, count, sizeof(score_t), compare_score);
    }
    
    size_t result_count = count < (size_t)top_k ? count : (size_t)top_k;
    
    *out_ids = malloc(sizeof(size_t) * result_count);
    *out_scores = malloc(sizeof(float) * result_count);
    if (!*out_ids || !*out_scores) {
        free(*out_ids);
        free(*out_scores);
        free(scores);
        return 0;
    }
    
    for (size_t i = 0; i < result_count; i++) {
        (*out_ids)[i] = scores[i].id;
        (*out_scores)[i] = 1.0f - scores[i].dist;
    }
    
    free(scores);
    return result_count;
}

// ====== 统计 ======

size_t hnsw_count(const hnsw_index_t* idx) {
    if (!idx) return 0;
    size_t count = 0;
    for (size_t i = 0; i < idx->node_count; i++) {
        if (idx->nodes[i].valid) count++;
    }
    return count;
}

size_t hnsw_memory_usage(const hnsw_index_t* idx) {
    if (!idx) return 0;
    
    size_t mem = sizeof(hnsw_index_t);
    mem += sizeof(hnsw_node_impl_t) * idx->node_capacity;
    
    for (size_t i = 0; i < idx->node_count; i++) {
        if (idx->nodes[i].vector) {
            mem += sizeof(float) * idx->dim;
        }
        if (idx->nodes[i].neighbors) {
            for (int l = 0; l <= idx->nodes[i].level; l++) {
                mem += sizeof(size_t) * idx->nodes[i].neighbors[l].capacity;
            }
            mem += sizeof(neighbor_list_t) * (idx->nodes[i].level + 1);
        }
    }
    
    mem += sizeof(size_t) * idx->free_capacity;
    
    return mem;
}

int hnsw_get_ef_search(const hnsw_index_t* idx) {
    if (!idx) return HNSW_DEFAULT_EF_SEARCH;
    return idx->ef_search;
}

// ====== Persistence ======

#define HNSW_SERIALIZE_MAGIC 0x48534E48  // "HNSH"
#define HNSW_SERIALIZE_VERSION 1

// Header: 56 bytes
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint64_t dim;
    int32_t M;
    int32_t M_max;
    int32_t ef_construction;
    int32_t ef_search;
    int32_t max_level;
    uint64_t entry_point;
    uint64_t node_count;
    uint64_t free_count;
} hnsw_serialize_header_t;

size_t hnsw_serialize_size(const hnsw_index_t* idx) {
    if (!idx) return 0;
    
    size_t size = sizeof(hnsw_serialize_header_t);
    
    // Nodes
    for (size_t i = 0; i < idx->node_count; i++) {
        hnsw_node_impl_t* node = &idx->nodes[i];
        size += 8 + 4 + 4;  // id + level + valid
        if (node->valid && node->vector) {
            size += sizeof(float) * idx->dim;  // vector
            size += 4;  // num_levels
            for (int l = 0; l <= node->level; l++) {
                size += 8;  // count
                size += sizeof(size_t) * node->neighbors[l].count;  // ids
            }
        }
    }
    
    // Free list
    size += sizeof(uint64_t);  // free_count
    size += sizeof(size_t) * idx->free_count;
    
    return size;
}

size_t hnsw_serialize(const hnsw_index_t* idx, void* buf, size_t buf_size) {
    if (!idx || !buf || buf_size == 0) return 0;
    
    size_t required = hnsw_serialize_size(idx);
    if (buf_size < required) return 0;
    
    char* p = (char*)buf;
    
    // Header
    hnsw_serialize_header_t* hdr = (hnsw_serialize_header_t*)p;
    hdr->magic = HNSW_SERIALIZE_MAGIC;
    hdr->version = HNSW_SERIALIZE_VERSION;
    hdr->dim = idx->dim;
    hdr->M = idx->M;
    hdr->M_max = idx->M_max;
    hdr->ef_construction = idx->ef_construction;
    hdr->ef_search = idx->ef_search;
    hdr->max_level = idx->max_level;
    hdr->entry_point = idx->entry_point;
    hdr->node_count = idx->node_count;
    hdr->free_count = idx->free_count;
    p += sizeof(hnsw_serialize_header_t);
    
    // Nodes
    for (size_t i = 0; i < idx->node_count; i++) {
        hnsw_node_impl_t* node = &idx->nodes[i];
        *(size_t*)p = node->id;
        p += 8;
        *(int32_t*)p = node->level;
        p += 4;
        *(int32_t*)p = node->valid;
        p += 4;
        
        if (node->valid && node->vector) {
            memcpy(p, node->vector, sizeof(float) * idx->dim);
            p += sizeof(float) * idx->dim;
            
            int32_t num_levels = node->level + 1;
            *(int32_t*)p = num_levels;
            p += 4;
            
            for (int l = 0; l < num_levels; l++) {
                *(size_t*)p = node->neighbors[l].count;
                p += 8;
                memcpy(p, node->neighbors[l].ids, sizeof(size_t) * node->neighbors[l].count);
                p += sizeof(size_t) * node->neighbors[l].count;
            }
        }
    }
    
    // Free list
    *(size_t*)p = idx->free_count;
    p += 8;
    memcpy(p, idx->free_list, sizeof(size_t) * idx->free_count);
    p += sizeof(size_t) * idx->free_count;
    
    return p - (char*)buf;
}

hnsw_index_t* hnsw_deserialize(const void* buf, size_t buf_size) {
    if (!buf || buf_size < sizeof(hnsw_serialize_header_t)) return NULL;
    
    const char* p = (const char*)buf;
    
    // Header
    const hnsw_serialize_header_t* hdr = (const hnsw_serialize_header_t*)p;
    if (hdr->magic != HNSW_SERIALIZE_MAGIC || hdr->version != HNSW_SERIALIZE_VERSION) {
        return NULL;
    }
    p += sizeof(hnsw_serialize_header_t);
    
    // Create index
    hnsw_index_t* idx = calloc(1, sizeof(hnsw_index_t));
    if (!idx) return NULL;
    
    idx->dim = hdr->dim;
    idx->M = hdr->M;
    idx->M_max = hdr->M_max;
    idx->ef_construction = hdr->ef_construction;
    idx->ef_search = hdr->ef_search;
    idx->mL = 1.0f / logf((float)idx->M);
    idx->max_level = hdr->max_level;
    idx->entry_point = hdr->entry_point;
    idx->node_count = hdr->node_count;
    idx->node_capacity = hdr->node_count;
    
    // Allocate nodes
    idx->nodes = calloc(idx->node_capacity, sizeof(hnsw_node_impl_t));
    if (!idx->nodes) {
        free(idx);
        return NULL;
    }
    
    // Load nodes
    for (size_t i = 0; i < idx->node_count; i++) {
        hnsw_node_impl_t* node = &idx->nodes[i];
        node->id = *(size_t*)p;
        p += 8;
        node->level = *(int32_t*)p;
        p += 4;
        node->valid = *(int32_t*)p;
        p += 4;
        
        if (node->valid) {
            // Vector
            node->vector = malloc(sizeof(float) * idx->dim);
            if (node->vector) {
                memcpy(node->vector, p, sizeof(float) * idx->dim);
                p += sizeof(float) * idx->dim;
            } else {
                // Memory allocation failed: mark invalid and skip data
                node->valid = 0;
                p += sizeof(float) * idx->dim;
            }
            
            // Neighbors (always read, even if vector failed, to keep stream position)
            int32_t num_levels = *(int32_t*)p;
            p += 4;
            
            if (num_levels > 0 && node->valid) {
                node->neighbors = calloc(num_levels, sizeof(neighbor_list_t));
                if (node->neighbors) {
                    for (int l = 0; l < num_levels; l++) {
                        size_t count = *(size_t*)p;
                        p += 8;
                        if (count > 0) {
                            neighbor_list_init(&node->neighbors[l], count);
                            memcpy(node->neighbors[l].ids, p, sizeof(size_t) * count);
                            node->neighbors[l].count = count;
                            p += sizeof(size_t) * count;
                        }
                    }
                }
            } else if (num_levels > 0) {
                // Skip neighbor data for invalid nodes
                for (int l = 0; l < num_levels; l++) {
                    size_t count = *(size_t*)p;
                    p += 8;
                    p += sizeof(size_t) * count;
                }
            }
        }
    }
    
    // Free list
    size_t free_count = *(size_t*)p;
    p += 8;
    if (free_count > 0) {
        idx->free_list = malloc(sizeof(size_t) * free_count);
        if (idx->free_list) {
            memcpy(idx->free_list, p, sizeof(size_t) * free_count);
            idx->free_count = free_count;
            idx->free_capacity = free_count;
            p += sizeof(size_t) * free_count;
        }
    }
    
    return idx;
}
