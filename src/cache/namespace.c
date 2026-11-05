#include "cache_internal.h"
#include <string.h>
#include <stdlib.h>

// 辅助：比较 namespace 子节点名（用于排序/二分）
static int ns_name_cmp(const char* a, size_t alen, const char* b, size_t blen) {
    size_t m = alen < blen ? alen : blen;
    int c = memcmp(a, b, m);
    if (c) return c;
    if (alen < blen) return -1;
    if (alen > blen) return 1;
    return 0;
}

// 辅助：查找或创建子节点
// children 按 name 排序，二分查找 O(log n)。
// 修复：旧实现用 child->path(完整路径) 与 name(单个分量) 比较，长度必然不等，
// 去重永不命中 → 每个 key 都新建节点、namespace 树爆炸 → 导入 O(n²)。
static cache_ns_node_t* find_or_create_child(cache_ns_node_t* parent, 
                                              const char* name, size_t name_len) {
    size_t parent_len = strlen(parent->path);
    size_t sep_len = (parent_len > 0) ? 1 : 0;

    // 二分查找
    size_t lo = 0, hi = parent->child_count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        cache_ns_node_t* child = parent->children[mid];
        const char* cname = child->path + parent_len + sep_len;
        size_t clen = strlen(child->path) - (parent_len + sep_len);
        int c = ns_name_cmp(cname, clen, name, name_len);
        if (c == 0) return child;
        if (c < 0) lo = mid + 1; else hi = mid;
    }
    
    // 扩容
    if (parent->child_count >= parent->child_capacity) {
        size_t new_cap = parent->child_capacity * 2;
        if (new_cap < 4) new_cap = 4;
        cache_ns_node_t** new_children = realloc(parent->children, 
                                                  sizeof(cache_ns_node_t*) * new_cap);
        if (!new_children) return NULL;
        parent->children = new_children;
        parent->child_capacity = new_cap;
    }
    
    // 创建新节点
    cache_ns_node_t* child = calloc(1, sizeof(cache_ns_node_t));
    if (!child) return NULL;
    
    // 构建完整路径（parent 可能是根节点 ""，此时不加额外的 '/'）
    child->path = malloc(parent_len + sep_len + name_len + 1);
    if (!child->path) {
        free(child);
        return NULL;
    }
    
    if (parent_len > 0) {
        memcpy(child->path, parent->path, parent_len);
        child->path[parent_len] = '/';
    }
    memcpy(child->path + parent_len + sep_len, name, name_len);
    child->path[parent_len + sep_len + name_len] = '\0';
    
    // 插入到 lo 位置，保持排序
    memmove(&parent->children[lo + 1], &parent->children[lo],
            (parent->child_count - lo) * sizeof(cache_ns_node_t*));
    parent->children[lo] = child;
    parent->child_count++;
    return child;
}

// 辅助：从 key 提取 namespace 路径
// key 如 "/coding/cpp/move-semantics" → ns = "/coding/cpp", name = "move-semantics"
// key 如 "simple_key" → ns = "" (根), name = "simple_key"
static void extract_namespace(const char* key, size_t key_len,
                               char* ns_out, size_t ns_cap,
                               const char** name_out, size_t* name_len_out) {
    // 找最后一个 '/'
    const char* last_slash = NULL;
    for (size_t i = 0; i < key_len; i++) {
        if (key[i] == '/') last_slash = &key[i];
    }
    
    if (last_slash) {
        // 有 namespace
        size_t ns_len = last_slash - key;
        if (ns_len >= ns_cap) ns_len = ns_cap - 1;
        memcpy(ns_out, key, ns_len);
        ns_out[ns_len] = '\0';
        *name_out = last_slash + 1;
        *name_len_out = key_len - ns_len - 1;
    } else {
        // 无 namespace，在根下
        ns_out[0] = '\0';
        *name_out = key;
        *name_len_out = key_len;
    }
}

// 辅助：获取或创建 namespace 节点（通过完整路径）
static cache_ns_node_t* get_or_create_ns_node(cache_ns_node_t* root, const char* ns_path) {
    if (!ns_path || ns_path[0] == '\0') return root;
    
    cache_ns_node_t* current = root;
    const char* p = ns_path;
    
    // 跳过开头的 '/'
    if (*p == '/') p++;
    
    while (*p) {
        // 找到下一个 '/'
        const char* end = p;
        while (*end && *end != '/') end++;
        
        size_t name_len = end - p;
        cache_ns_node_t* child = find_or_create_child(current, p, name_len);
        if (!child) return NULL;
        
        current = child;
        p = end;
        if (*p == '/') p++;
    }
    
    return current;
}

// 辅助：查找 namespace 节点（不创建）
static cache_ns_node_t* find_ns_node(cache_ns_node_t* root, const char* ns_path) {
    if (!ns_path || ns_path[0] == '\0') return root;
    
    cache_ns_node_t* current = root;
    const char* p = ns_path;
    
    if (*p == '/') p++;
    
    while (*p) {
        const char* end = p;
        while (*end && *end != '/') end++;
        
        size_t name_len = end - p;
        cache_ns_node_t* found = NULL;
        for (size_t i = 0; i < current->child_count; i++) {
            cache_ns_node_t* child = current->children[i];
            // 提取 child 的短名（最后一个 '/' 后的部分）
            const char* child_name = strrchr(child->path, '/');
            if (child_name) child_name++;
            else child_name = child->path;
            
            if (strlen(child_name) == name_len && memcmp(child_name, p, name_len) == 0) {
                found = child;
                break;
            }
        }
        
        if (!found) return NULL;
        current = found;
        p = end;
        if (*p == '/') p++;
    }
    
    return current;
}

// 初始化 namespace 树
int cache_ns_init(cache_t* cache) {
    if (!cache) return -1;
    
    cache->ns_root = calloc(1, sizeof(cache_ns_node_t));
    if (!cache->ns_root) return -1;
    
    cache->ns_root->path = strdup("");
    if (!cache->ns_root->path) {
        free(cache->ns_root);
        cache->ns_root = NULL;
        return -1;
    }
    
    return 0;
}

// 添加 entry 到 namespace 索引
int cache_ns_add(cache_t* cache, const char* key, size_t entry_offset) {
    if (!cache || !key || !cache->ns_root) return -1;
    
    size_t key_len = strlen(key);
    char ns_path[1024];
    const char* name;
    size_t name_len;
    
    extract_namespace(key, key_len, ns_path, sizeof(ns_path), &name, &name_len);
    
    // 获取或创建 namespace 节点
    cache_ns_node_t* ns = get_or_create_ns_node(cache->ns_root, ns_path);
    if (!ns) return -1;
    
    // 扩容 entry 数组
    if (ns->entry_count >= ns->entry_capacity) {
        size_t new_cap = ns->entry_capacity * 2;
        if (new_cap < 16) new_cap = 16;
        size_t* new_offsets = realloc(ns->entry_offsets, sizeof(size_t) * new_cap);
        if (!new_offsets) return -1;
        ns->entry_offsets = new_offsets;
        ns->entry_capacity = new_cap;
    }
    
    ns->entry_offsets[ns->entry_count++] = entry_offset;
    return 0;
}

// 从 namespace 中移除 entry
int cache_ns_remove(cache_t* cache, const char* key) {
    if (!cache || !key || !cache->ns_root) return -1;
    
    size_t key_len = strlen(key);
    char ns_path[1024];
    const char* name;
    size_t name_len;
    
    extract_namespace(key, key_len, ns_path, sizeof(ns_path), &name, &name_len);
    
    cache_ns_node_t* ns = find_ns_node(cache->ns_root, ns_path);
    if (!ns) return -1;
    
    // 在 entry_offsets 中查找并删除
    for (size_t i = 0; i < ns->entry_count; i++) {
        // 需要比较 key 来确认是哪个 entry
        size_t offset = ns->entry_offsets[i];
        cache_entry_header_t* h = (cache_entry_header_t*)((char*)cache->pool.base + offset);
        const char* entry_key = (char*)cache->pool.base + offset + sizeof(cache_entry_header_t);
        
        if (h->key_len == key_len && memcmp(entry_key, key, key_len) == 0) {
            // 删除：将最后一个移到当前位置
            ns->entry_offsets[i] = ns->entry_offsets[ns->entry_count - 1];
            ns->entry_count--;
            return 0;
        }
    }
    
    return -1;  // 未找到
}

// 查找 namespace 节点
cache_ns_node_t* cache_ns_find(cache_t* cache, const char* ns_path) {
    if (!cache || !cache->ns_root) return NULL;
    return find_ns_node(cache->ns_root, ns_path);
}

// 辅助：递归释放 namespace 树
static void destroy_ns_tree(cache_ns_node_t* node) {
    if (!node) return;
    
    // 递归释放子节点
    for (size_t i = 0; i < node->child_count; i++) {
        destroy_ns_tree(node->children[i]);
    }
    
    free(node->children);
    free(node->entry_offsets);
    free(node->path);
    free(node);
}

// 释放 namespace 索引
void cache_ns_destroy(cache_t* cache) {
    if (!cache || !cache->ns_root) return;
    
    destroy_ns_tree(cache->ns_root);
    cache->ns_root = NULL;
}
