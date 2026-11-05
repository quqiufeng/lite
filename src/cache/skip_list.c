#include "cache_internal.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ====== 随机层数生成 ======
static int random_level(void) {
    int level = 1;
    // 使用简单随机数（C 标准库）
    // 每层概率 0.5
    while (level < CACHE_SKIPLIST_MAX_LEVEL && (rand() & 1)) {
        level++;
    }
    return level;
}

// ====== 跳表创建/销毁 ======

cache_skiplist_t* cache_skiplist_create(void) {
    cache_skiplist_t* sl = malloc(sizeof(cache_skiplist_t));
    if (!sl) return NULL;
    
    sl->head = malloc(sizeof(cache_skiplist_node_t));
    if (!sl->head) {
        free(sl);
        return NULL;
    }
    
    sl->head->offset = 0;
    sl->head->key = NULL;
    sl->head->key_len = 0;
    sl->head->level = CACHE_SKIPLIST_MAX_LEVEL;
    sl->head->forward = calloc(CACHE_SKIPLIST_MAX_LEVEL, sizeof(cache_skiplist_node_t*));
    if (!sl->head->forward) {
        free(sl->head);
        free(sl);
        return NULL;
    }
    
    sl->max_level = 1;
    sl->size = 0;
    
    return sl;
}

static void free_node(cache_skiplist_node_t* node) {
    if (!node) return;
    free(node->key);
    free(node->forward);
    free(node);
}

void cache_skiplist_destroy(cache_skiplist_t* sl) {
    if (!sl) return;
    
    cache_skiplist_node_t* current = sl->head->forward[0];
    while (current) {
        cache_skiplist_node_t* next = current->forward[0];
        free_node(current);
        current = next;
    }
    
    free_node(sl->head);
    free(sl);
}

// ====== 比较函数（比较 entry 的 key）======
static int compare_keys(cache_t* cache, size_t offset_a, const char* key_b, size_t key_b_len) {
    cache_entry_header_t* ha = (cache_entry_header_t*)CACHE_PTR(cache, offset_a);
    const char* key_a = (const char*)CACHE_PTR(cache, offset_a + sizeof(cache_entry_header_t));
    
    size_t min_len = ha->key_len < key_b_len ? ha->key_len : key_b_len;
    int cmp = memcmp(key_a, key_b, min_len);
    if (cmp != 0) return cmp;
    if (ha->key_len < key_b_len) return -1;
    if (ha->key_len > key_b_len) return 1;
    return 0;
}

// ====== 查找 ======
cache_skiplist_node_t* cache_skiplist_find(cache_skiplist_t* sl, const char* key, size_t key_len) {
    if (!sl || !key) return NULL;
    
    cache_skiplist_node_t* current = sl->head;
    
    for (int i = sl->max_level - 1; i >= 0; i--) {
        while (current->forward[i] && 
               (current->forward[i]->key && strncmp(current->forward[i]->key, key, key_len) < 0)) {
            current = current->forward[i];
        }
    }
    
    current = current->forward[0];
    if (current && current->key && strlen(current->key) == key_len && strncmp(current->key, key, key_len) == 0) {
        return current;
    }
    
    return NULL;
}

// ====== 插入 ======
int cache_skiplist_insert(cache_t* cache, cache_skiplist_t* sl, size_t entry_offset, const char* key, size_t key_len) {
    if (!cache || !sl || !key) return CACHE_ERR_INVAL;
    
    cache_skiplist_node_t* update[CACHE_SKIPLIST_MAX_LEVEL];
    cache_skiplist_node_t* current = sl->head;
    
    // 找到每一层的前驱节点
    for (int i = sl->max_level - 1; i >= 0; i--) {
        while (current->forward[i] && 
               compare_keys(cache, current->forward[i]->offset, key, key_len) < 0) {
            current = current->forward[i];
        }
        update[i] = current;
    }
    
    current = current->forward[0];
    
    // 如果 key 已存在，更新 offset
    if (current && compare_keys(cache, current->offset, key, key_len) == 0) {
        current->offset = entry_offset;
        return CACHE_OK;
    }
    
    // 创建新节点
    int level = random_level();
    if (level > sl->max_level) {
        for (int i = sl->max_level; i < level; i++) {
            update[i] = sl->head;
        }
        sl->max_level = level;
    }
    
    cache_skiplist_node_t* new_node = malloc(sizeof(cache_skiplist_node_t));
    if (!new_node) return CACHE_ERR_NOMEM;
    
    new_node->offset = entry_offset;
    new_node->key = malloc(key_len + 1);
    if (!new_node->key) {
        free(new_node);
        return CACHE_ERR_NOMEM;
    }
    memcpy(new_node->key, key, key_len);
    new_node->key[key_len] = '\0';
    new_node->key_len = key_len;
    new_node->level = level;
    new_node->forward = calloc(level, sizeof(cache_skiplist_node_t*));
    if (!new_node->forward) {
        free(new_node->key);
        free(new_node);
        return CACHE_ERR_NOMEM;
    }
    
    // 更新前向指针
    for (int i = 0; i < level; i++) {
        new_node->forward[i] = update[i]->forward[i];
        update[i]->forward[i] = new_node;
    }
    
    sl->size++;
    return CACHE_OK;
}

// ====== 删除 ======
void cache_skiplist_remove(cache_skiplist_t* sl, const char* key, size_t key_len) {
    if (!sl || !key) return;
    
    cache_skiplist_node_t* update[CACHE_SKIPLIST_MAX_LEVEL];
    cache_skiplist_node_t* current = sl->head;
    
    for (int i = sl->max_level - 1; i >= 0; i--) {
        while (current->forward[i] && 
               (current->forward[i]->key && strncmp(current->forward[i]->key, key, key_len) < 0)) {
            current = current->forward[i];
        }
        update[i] = current;
    }
    
    current = current->forward[0];
    
    if (current && current->key && strlen(current->key) == key_len && strncmp(current->key, key, key_len) == 0) {
        for (int i = 0; i < sl->max_level; i++) {
            if (update[i]->forward[i] != current) break;
            update[i]->forward[i] = current->forward[i];
        }
        
        free_node(current);
        sl->size--;
        
        // 调整 max_level
        while (sl->max_level > 1 && sl->head->forward[sl->max_level - 1] == NULL) {
            sl->max_level--;
        }
    }
}

// ====== 从 sorted array 批量构建跳表 ======
void cache_skiplist_build(cache_t* cache, cache_skiplist_t* sl) {
    if (!cache || !sl) return;
    
    // 清空现有跳表
    cache_skiplist_node_t* current = sl->head->forward[0];
    while (current) {
        cache_skiplist_node_t* next = current->forward[0];
        free_node(current);
        current = next;
    }
    
    for (int i = 0; i < CACHE_SKIPLIST_MAX_LEVEL; i++) {
        sl->head->forward[i] = NULL;
    }
    sl->max_level = 1;
    sl->size = 0;
    
    // 确保 sorted array 已排序
    cache_sorted_rebuild(cache);
    
    // 批量插入
    for (size_t i = 0; i < cache->sorted.count; i++) {
        size_t offset = cache->sorted.offsets[i];
        if (!offset) continue;
        
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
        if (h->flags & CACHE_ENTRY_DELETED) continue;
        
        const char* key = (const char*)CACHE_PTR(cache, offset + sizeof(cache_entry_header_t));
        cache_skiplist_insert(cache, sl, offset, key, h->key_len);
    }
}
