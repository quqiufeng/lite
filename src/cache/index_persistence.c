#include "cache_index.h"
#include "cache_internal.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))
#define INDEX_FILE_NAME "mem.idx"

// ====== Namespace Tree Persistence ======

static size_t ns_node_size(cache_ns_node_t* node) {
    if (!node) return 0;
    size_t size = 4 + strlen(node->path);  // path_len + path
    size += 8 + node->entry_count * sizeof(size_t);  // entry_count + offsets
    size += 8;  // child_count
    for (size_t i = 0; i < node->child_count; i++) {
        size += ns_node_size(node->children[i]);
    }
    return size;
}

static size_t ns_serialize_size(cache_t* cache) {
    if (!cache || !cache->ns_root) return 0;
    return ns_node_size(cache->ns_root);
}

static size_t write_ns_node(cache_ns_node_t* node, char* buf) {
    if (!node) return 0;
    char* p = buf;
    
    uint32_t path_len = strlen(node->path);
    *(uint32_t*)p = path_len;
    p += 4;
    memcpy(p, node->path, path_len);
    p += path_len;
    
    *(size_t*)p = node->entry_count;
    p += 8;
    memcpy(p, node->entry_offsets, node->entry_count * sizeof(size_t));
    p += node->entry_count * sizeof(size_t);
    
    *(size_t*)p = node->child_count;
    p += 8;
    
    for (size_t i = 0; i < node->child_count; i++) {
        p += write_ns_node(node->children[i], p);
    }
    
    return p - buf;
}

static size_t write_ns_index(cache_t* cache, void* buf) {
    if (!cache || !cache->ns_root) return 0;
    return write_ns_node(cache->ns_root, (char*)buf);
}

static cache_ns_node_t* read_ns_node(const char** p) {
    cache_ns_node_t* node = calloc(1, sizeof(cache_ns_node_t));
    if (!node) return NULL;
    
    uint32_t path_len = *(uint32_t*)(*p);
    *p += 4;
    
    node->path = malloc(path_len + 1);
    if (node->path) {
        memcpy(node->path, *p, path_len);
        node->path[path_len] = '\0';
    }
    *p += path_len;
    
    node->entry_count = *(size_t*)(*p);
    *p += 8;
    
    if (node->entry_count > 0) {
        node->entry_offsets = malloc(node->entry_count * sizeof(size_t));
        if (node->entry_offsets) {
            memcpy(node->entry_offsets, *p, node->entry_count * sizeof(size_t));
        }
        node->entry_capacity = node->entry_count;
        *p += node->entry_count * sizeof(size_t);
    }
    
    size_t child_count = *(size_t*)(*p);
    *p += 8;
    
    if (child_count > 0) {
        node->children = calloc(child_count, sizeof(cache_ns_node_t*));
        node->child_capacity = child_count;
        
        for (size_t i = 0; i < child_count; i++) {
            node->children[i] = read_ns_node(p);
            node->child_count++;
        }
    }
    
    return node;
}

// Calculate total size needed for all indexes
static size_t calculate_index_size(cache_t* cache, size_t* hash_size,
                                   size_t* sorted_size, size_t* vector_size,
                                   size_t* hnsw_size, size_t* ns_size) {
    *hash_size = 0;
    *sorted_size = 0;
    *vector_size = 0;
    *hnsw_size = 0;
    *ns_size = 0;
    
    // Hash index
    if (cache->hash.bucket_count > 0) {
        *hash_size = 16 + cache->hash.bucket_count * sizeof(cache_hash_bucket_t);
    }
    
    // Sorted array
    if (cache->sorted.count > 0) {
        *sorted_size = 24 + cache->sorted.count * sizeof(size_t);
    }
    
    // Vector index
    if (cache->vector_index.count > 0) {
        *vector_size = 16 + cache->vector_index.count * sizeof(cache_vector_entry_t);
    }
    
    // HNSW index
    if (cache->vector_index.use_hnsw && cache->vector_index.hnsw) {
        *hnsw_size = hnsw_serialize_size(cache->vector_index.hnsw);
    }
    
    // Namespace tree
    *ns_size = ns_serialize_size(cache);
    
    // Header + entries
    size_t header_size = sizeof(cache_index_file_header_t);
    int index_count = 0;
    if (*hash_size > 0) index_count++;
    if (*sorted_size > 0) index_count++;
    if (*vector_size > 0) index_count++;
    if (*hnsw_size > 0) index_count++;
    if (*ns_size > 0) index_count++;
    
    size_t entries_size = index_count * sizeof(cache_index_entry_t);
    size_t data_size = *hash_size + *sorted_size + *vector_size + *hnsw_size + *ns_size;
    
    return header_size + entries_size + data_size;
}

// Write hash index data to buffer
// Returns number of bytes written
static size_t write_hash_index(cache_t* cache, void* buf) {
    if (cache->hash.bucket_count == 0) return 0;
    
    char* p = (char*)buf;
    
    // bucket_count
    *(size_t*)p = cache->hash.bucket_count;
    p += 8;
    
    // size
    *(size_t*)p = cache->hash.size;
    p += 8;
    
    // buckets array
    if (cache->hash.buckets_offset > 0) {
        cache_hash_bucket_t* buckets = (cache_hash_bucket_t*)
            ((char*)cache->pool.base + cache->hash.buckets_offset);
        memcpy(p, buckets, cache->hash.bucket_count * sizeof(cache_hash_bucket_t));
        p += cache->hash.bucket_count * sizeof(cache_hash_bucket_t);
    }
    
    return p - (char*)buf;
}

// Write sorted array data to buffer
// Forward declaration from sorted_array.c
extern void cache_sorted_ensure_sorted(cache_t* cache);

static size_t write_sorted_index(cache_t* cache, void* buf) {
    if (cache->sorted.count == 0) return 0;
    
    // Ensure sorted before saving
    cache_sorted_ensure_sorted(cache);
    
    char* p = (char*)buf;
    
    *(size_t*)p = cache->sorted.count;
    p += 8;
    
    *(size_t*)p = cache->sorted.capacity;
    p += 8;
    
    *(uint32_t*)p = 0;  // dirty = 0 (already sorted)
    p += 4;
    
    *(uint32_t*)p = 0;  // padding
    p += 4;
    
    memcpy(p, cache->sorted.offsets, cache->sorted.count * sizeof(size_t));
    p += cache->sorted.count * sizeof(size_t);
    
    return p - (char*)buf;
}

// Write vector index data to buffer
static size_t write_vector_index(cache_t* cache, void* buf) {
    if (cache->vector_index.count == 0) return 0;
    
    char* p = (char*)buf;
    
    *(size_t*)p = cache->vector_index.count;
    p += 8;
    
    *(size_t*)p = cache->vector_index.capacity;
    p += 8;
    
    memcpy(p, cache->vector_index.entries,
           cache->vector_index.count * sizeof(cache_vector_entry_t));
    p += cache->vector_index.count * sizeof(cache_vector_entry_t);
    
    return p - (char*)buf;
}

int cache_index_save(cache_t* cache) {
    if (!cache) return -1;
    
    char path[512];
    char tmp_path[520];
    snprintf(path, sizeof(path), "%s/%s", cache->db_dir, INDEX_FILE_NAME);
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path);
    
    size_t hash_size, sorted_size, vector_size, hnsw_size, ns_size;
    size_t total_size = calculate_index_size(cache, &hash_size, &sorted_size, &vector_size, &hnsw_size, &ns_size);
    
    if (total_size <= sizeof(cache_index_file_header_t)) {
        // Nothing to save
        return 0;
    }
    
    // Create temp file
    int fd = open(tmp_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        CACHE_LOG( "[CACHE] Failed to create index temp file: %s\n", strerror(errno));
        return -1;
    }
    
    // Set file size
    if (ftruncate(fd, total_size) < 0) {
        close(fd);
        unlink(tmp_path);
        return -1;
    }
    
    // mmap for writing
    void* base = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    
    if (base == MAP_FAILED) {
        unlink(tmp_path);
        return -1;
    }
    
    // Write file header
    cache_index_file_header_t* header = (cache_index_file_header_t*)base;
    header->magic = CACHE_INDEX_MAGIC;
    header->version = CACHE_INDEX_VERSION;
    header->total_size = total_size;
    header->reserved = 0;
    
    // Count indexes
    int index_count = 0;
    if (hash_size > 0) index_count++;
    if (sorted_size > 0) index_count++;
    if (vector_size > 0) index_count++;
    if (hnsw_size > 0) index_count++;
    if (ns_size > 0) index_count++;
    header->index_count = index_count;
    
    // Index entries start after header
    cache_index_entry_t* entries = (cache_index_entry_t*)
        ((char*)base + sizeof(cache_index_file_header_t));
    
    // Data starts after all entries
    char* data_ptr = (char*)base + sizeof(cache_index_file_header_t)
        + index_count * sizeof(cache_index_entry_t);
    
    int entry_idx = 0;
    
    // Write hash index
    if (hash_size > 0) {
        cache_index_entry_t* entry = &entries[entry_idx++];
        entry->type = INDEX_TYPE_HASH;
        entry->data_offset = data_ptr - (char*)base;
        entry->data_size = hash_size;
        entry->entry_count = cache->hash.bucket_count;
        entry->reserved = 0;
        entry->reserved2 = 0;
        
        size_t written = write_hash_index(cache, data_ptr);
        data_ptr += written;
    }
    
    // Write sorted array
    if (sorted_size > 0) {
        cache_index_entry_t* entry = &entries[entry_idx++];
        entry->type = INDEX_TYPE_SORTED;
        entry->data_offset = data_ptr - (char*)base;
        entry->data_size = sorted_size;
        entry->entry_count = cache->sorted.count;
        entry->reserved = 0;
        entry->reserved2 = 0;
        
        size_t written = write_sorted_index(cache, data_ptr);
        data_ptr += written;
    }
    
    // Write vector index
    if (vector_size > 0) {
        cache_index_entry_t* entry = &entries[entry_idx++];
        entry->type = INDEX_TYPE_VECTOR;
        entry->data_offset = data_ptr - (char*)base;
        entry->data_size = vector_size;
        entry->entry_count = cache->vector_index.count;
        entry->reserved = 0;
        entry->reserved2 = 0;
        
        size_t written = write_vector_index(cache, data_ptr);
        data_ptr += written;
    }
    
    // Write HNSW index
    if (hnsw_size > 0) {
        cache_index_entry_t* entry = &entries[entry_idx++];
        entry->type = INDEX_TYPE_HNSW;
        entry->data_offset = data_ptr - (char*)base;
        entry->data_size = hnsw_size;
        entry->entry_count = hnsw_count(cache->vector_index.hnsw);
        entry->reserved = 0;
        entry->reserved2 = 0;
        
        size_t written = hnsw_serialize(cache->vector_index.hnsw, data_ptr, hnsw_size);
        data_ptr += written;
    }
    
    // Write namespace tree
    if (ns_size > 0) {
        cache_index_entry_t* entry = &entries[entry_idx++];
        entry->type = INDEX_TYPE_TAG;  // Use TAG type for namespace (no dedicated type yet)
        entry->type = 6;  // Custom type for namespace
        entry->data_offset = data_ptr - (char*)base;
        entry->data_size = ns_size;
        entry->entry_count = 0;  // Tree structure, no simple count
        entry->reserved = 0;
        entry->reserved2 = 0;
        
        size_t written = write_ns_index(cache, data_ptr);
        data_ptr += written;
    }
    
    // Sync to disk
    msync(base, total_size, MS_SYNC);
    munmap(base, total_size);
    
    // Atomic rename
    if (rename(tmp_path, path) < 0) {
        unlink(tmp_path);
        return -1;
    }
    
    CACHE_LOG( "[CACHE] Index saved: %s (%zu bytes, %d indexes)\n", path, total_size, index_count);
    
    return 0;
}

// 释放已加载的索引结构（用于加载后发现偏移非法时回滚）
static void discard_loaded_index(cache_t* cache) {
    if (cache->sorted.offsets) {
        free(cache->sorted.offsets);
        cache->sorted.offsets = NULL;
        cache->sorted.count = 0;
        cache->sorted.capacity = 0;
        cache->sorted.dirty = 0;
    }
    if (cache->vector_index.entries) {
        free(cache->vector_index.entries);
        cache->vector_index.entries = NULL;
        cache->vector_index.count = 0;
        cache->vector_index.capacity = 0;
    }
    if (cache->vector_index.hnsw) {
        hnsw_destroy(cache->vector_index.hnsw);
        cache->vector_index.hnsw = NULL;
        cache->vector_index.use_hnsw = 0;
    }
    if (cache->ns_root) {
        cache_ns_destroy(cache);
    }
    cache->hash.buckets_offset = 0;
    cache->hash.bucket_count = 0;
    cache->hash.size = 0;
    // 回滚后上层会扫描重建，统计值必须归零，否则会重复累加
    cache->memory_used = 0;
    cache->entry_count = 0;
}

// 校验持久化 sorted 索引引用的 entry 偏移是否仍落在 pool 内且头部完好。
// cache.bin 被截断/损坏后，旧索引会引用越界偏移，直接使用会 SIGSEGV。
static int loaded_offsets_valid(cache_t* cache) {
    if (cache->sorted.count == 0) return 1;  // 无条目，交给上层重建
    size_t used = cache->pool.used;
    for (size_t i = 0; i < cache->sorted.count; i++) {
        size_t off = cache->sorted.offsets[i];
        if (off < CACHE_HEADER_SIZE || off + CACHE_ENTRY_HEADER_ALIGNED > used) return 0;
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, off);
        if (h->key_len == 0 || h->key_len > CACHE_MAX_KEY_LEN ||
            h->value_len > CACHE_MAX_VALUE_LEN) return 0;
        if (off + cache_entry_total_size(h) > used) return 0;
    }
    return 1;
}

// 校验持久化的 hash 索引：节点链必须落在 pool 内、指向的 entry 头部完好、
// 未被标记删除，且 key 确实哈希到它所在的桶。
//
// 历史 bug：write_hash_index 把 pool 里的 bucket 数组原样落盘，节点可能指向
// 已被标记 CACHE_ENTRY_DELETED 的 entry。重开后 cache_hash_lookup 不检查 flags，
// cache_get 命中墓碑后返回 NULL —— 表现为「记忆丢了」。
static int loaded_hash_valid(cache_t* cache, const cache_hash_bucket_t* buckets,
                             size_t bucket_count, size_t saved_size) {
    size_t used = cache->pool.used;
    if (bucket_count == 0) return saved_size == 0;
    if (used < CACHE_HEADER_SIZE) return saved_size == 0;
    size_t nodes = 0;

    for (size_t i = 0; i < bucket_count; i++) {
        size_t off = buckets[i].entry_offset;
        size_t guard = 0;
        while (off) {
            if ((off % MYDB_ALIGN) != 0) return 0;
            if (off < CACHE_HEADER_SIZE || off + sizeof(cache_hash_bucket_t) > used) return 0;
            if (++guard > saved_size + 1) return 0;  // 环或异常长链

            cache_hash_bucket_t* node = (cache_hash_bucket_t*)CACHE_PTR(cache, off);
            size_t eoff = node->entry_offset;
            if (eoff < CACHE_HEADER_SIZE || eoff + CACHE_ENTRY_HEADER_ALIGNED > used) return 0;

            cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, eoff);
            if (h->key_len == 0 || h->key_len > CACHE_MAX_KEY_LEN ||
                h->value_len > CACHE_MAX_VALUE_LEN) return 0;
            if (eoff + cache_entry_total_size(h) > used) return 0;
            if (h->flags & CACHE_ENTRY_DELETED) return 0;  // 指向墓碑

            const char* key = (const char*)CACHE_PTR(cache, eoff + sizeof(cache_entry_header_t));
            if (cache_hash_fnv1a(key, h->key_len) % bucket_count != i) return 0;

            nodes++;
            off = node->next_offset;
        }
    }
    return nodes == saved_size;
}

// 加载路径从不重算 cache->memory_used（只有扫描重建会累加），导致带索引启动后
// memory_used 恒为 0 —— 淘汰逻辑因此永不触发，pool 只会一路增长。
// 这里线性走一遍 pool，重算 used 与 live entry 数，并核对 hash 里的节点数：
// 节点数对不上说明有活 entry 没被索引到（数据在、但查不到），回退重建。
static size_t rebuild_usage_from_pool(cache_t* cache) {
    size_t offset = CACHE_HEADER_SIZE;
    size_t used = 0;
    size_t live = 0;
    while (offset + sizeof(cache_entry_header_t) <= cache->pool.used) {
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
        if (h->key_len == 0 || h->key_len > CACHE_MAX_KEY_LEN ||
            h->value_len > CACHE_MAX_VALUE_LEN) {
            offset += MYDB_ALIGN;
            continue;
        }
        size_t total = cache_entry_total_size(h);
        if (offset + total > cache->pool.used) break;
        if (!(h->flags & CACHE_ENTRY_DELETED)) {
            used += total;
            live++;
        }
        offset += total;
    }
    cache->memory_used = used;
    cache->entry_count = live;
    return live;
}

int cache_index_load(cache_t* cache) {
    if (!cache) return -1;
    int fast_read = (cache->open_flags & CACHE_OPEN_FAST_READ) != 0;
    
    // 清理旧索引数据，防止内存泄漏
    if (cache->sorted.offsets) {
        free(cache->sorted.offsets);
        cache->sorted.offsets = NULL;
        cache->sorted.count = 0;
        cache->sorted.capacity = 0;
    }
    if (cache->vector_index.entries) {
        free(cache->vector_index.entries);
        cache->vector_index.entries = NULL;
        cache->vector_index.count = 0;
        cache->vector_index.capacity = 0;
    }
    if (cache->vector_index.hnsw) {
        hnsw_destroy(cache->vector_index.hnsw);
        cache->vector_index.hnsw = NULL;
        cache->vector_index.use_hnsw = 0;
    }
    if (cache->ns_root) {
        // 使用递归函数释放 namespace 树
        // 这里需要调用 namespace.c 中的 destroy_ns_tree，但它是 static 的
        // 我们在 cache.c 中通过 cache_ns_destroy 暴露
        cache_ns_destroy(cache);
    }
    cache->hash.buckets_offset = 0;
    cache->hash.bucket_count = 0;
    cache->hash.size = 0;
    
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", cache->db_dir, INDEX_FILE_NAME);
    
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        // No index file, not an error - will rebuild
        return -1;
    }
    
    struct stat st;
    if (fstat(fd, &st) < 0) {
        close(fd);
        return -1;
    }
    
    size_t file_size = st.st_size;
    if (file_size < sizeof(cache_index_file_header_t)) {
        close(fd);
        return -1;
    }
    
    // mmap the entire file
    void* base = mmap(NULL, file_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    
    if (base == MAP_FAILED) {
        return -1;
    }
    
    // Validate header
    cache_index_file_header_t* header = (cache_index_file_header_t*)base;
    if (header->magic != CACHE_INDEX_MAGIC || header->version != CACHE_INDEX_VERSION) {
        munmap(base, file_size);
        return -1;
    }
    
    if (header->total_size != file_size) {
        munmap(base, file_size);
        return -1;
    }
    
    uint32_t index_count = header->index_count;
    
    // Process each index entry
    cache_index_entry_t* entries = (cache_index_entry_t*)
        ((char*)base + sizeof(cache_index_file_header_t));
    
    for (uint32_t i = 0; i < index_count; i++) {
        cache_index_entry_t* entry = &entries[i];
        void* data = (char*)base + entry->data_offset;
        
        switch (entry->type) {
            case INDEX_TYPE_HASH: {
                if (entry->data_size >= 16 && entry->entry_count > 0) {
                    size_t bucket_count = *(size_t*)data;
                    size_t hash_size = *(size_t*)((char*)data + 8);
                    size_t buckets_data_size = bucket_count * sizeof(cache_hash_bucket_t);

                    // 落盘内容必须先自洽：容量合法、字节数不超过本条索引的数据区
                    if (bucket_count == 0 || buckets_data_size / sizeof(cache_hash_bucket_t) != bucket_count ||
                        buckets_data_size > entry->data_size - 16 ||
                        (!fast_read &&
                         !loaded_hash_valid(cache, (const cache_hash_bucket_t*)((char*)data + 16),
                                            bucket_count, hash_size))) {
                        CACHE_LOG( "[CACHE] persisted hash index is stale/unusable, discarding\n");
                        munmap(base, file_size);
                        discard_loaded_index(cache);
                        return -1;
                    }

                    // Allocate buckets in pool (since existing code uses CACHE_PTR)
                    size_t pool_offset = pool_alloc_offset(&cache->pool, buckets_data_size);
                    if (pool_offset) {
                        void* pool_buckets = (char*)cache->pool.base + pool_offset;
                        memcpy(pool_buckets, (char*)data + 16, buckets_data_size);
                        cache->hash.bucket_count = bucket_count;
                        cache->hash.size = hash_size;
                        cache->hash.buckets_offset = pool_offset;
                    }
                }
                break;
            }
            
            case INDEX_TYPE_SORTED: {
                if (entry->data_size >= 24 && entry->entry_count > 0) {
                    size_t count = *(size_t*)data;
                    size_t offsets_size = count * sizeof(size_t);
                    
                    // Allocate offsets array (malloc, like original)
                    size_t* offsets = malloc(offsets_size);
                    if (offsets) {
                        memcpy(offsets, (char*)data + 24, offsets_size);
                        cache->sorted.count = count;
                        cache->sorted.capacity = count;
                        cache->sorted.dirty = 0;
                        cache->sorted.offsets = offsets;
                    }
                }
                break;
            }
            
            case INDEX_TYPE_VECTOR: {
                if (entry->data_size >= 16 && entry->entry_count > 0) {
                    size_t count = *(size_t*)data;
                    size_t entries_size = count * sizeof(cache_vector_entry_t);
                    
                    // Allocate entries array (malloc, like original)
                    cache_vector_entry_t* entries = malloc(entries_size);
                    if (entries) {
                        memcpy(entries, (char*)data + 16, entries_size);
                        cache->vector_index.count = count;
                        cache->vector_index.capacity = count;
                        cache->vector_index.entries = entries;
                    }
                }
                break;
            }
            
            case INDEX_TYPE_HNSW: {
                if (entry->data_size > 0) {
                    hnsw_index_t* hnsw = hnsw_deserialize(data, entry->data_size);
                    if (hnsw) {
                        cache->vector_index.hnsw = hnsw;
                        cache->vector_index.use_hnsw = 1;
                    }
                }
                break;
            }
            
            case 6: {  // Namespace tree
                if (entry->data_size > 0) {
                    const char* p = (const char*)data;
                    cache->ns_root = read_ns_node(&p);
                }
                break;
            }
            
            default:
                CACHE_LOG( "[CACHE] Unknown index type: %d\n", entry->type);
                break;
        }
    }
    
    if (!fast_read) {
        // 校验加载的偏移，非法则回滚并让上层重建
        if (!loaded_offsets_valid(cache)) {
            CACHE_LOG( "[CACHE] persisted index references invalid offsets, discarding\n");
            munmap(base, file_size);
            discard_loaded_index(cache);
            return -1;
        }

        // 重算 memory_used / entry_count（见 rebuild_usage_from_pool 注释），
        // 并核对 hash 节点数：活 entry 比索引多 → 有数据查不到，弃用索引交给扫描重建。
        size_t live = rebuild_usage_from_pool(cache);
        if (live != cache->hash.size) {
            CACHE_LOG("[CACHE] hash index covers %zu of %zu live entries, discarding\n",
                      cache->hash.size, live);
            munmap(base, file_size);
            discard_loaded_index(cache);
            return -1;
        }
    } else {
        // 只读快速路径：不扫描 mem.bin；内存统计用索引里的数量即可。
        cache->memory_used = cache->pool.used;
        cache->entry_count = cache->hash.size;
    }

    // Store mmap info for cleanup
    cache->index_mmap_base = base;
    cache->index_mmap_size = file_size;
    cache->index_loaded = 1;
    
    CACHE_LOG( "[CACHE] Index loaded from %s (%zu bytes, %d indexes)\n",
           path, file_size, index_count);
    
    return 0;
}

void cache_index_unload(cache_t* cache) {
    if (!cache) return;
    
    if (cache->index_mmap_base && cache->index_mmap_size > 0) {
        munmap(cache->index_mmap_base, cache->index_mmap_size);
        cache->index_mmap_base = NULL;
        cache->index_mmap_size = 0;
    }
    
    cache->index_loaded = 0;
}

int cache_index_exists(const char* db_dir) {
    if (!db_dir) return 0;
    
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", db_dir, INDEX_FILE_NAME);
    
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}
