#include "cache_internal.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define CACHE_PTR(cache, offset) ((void*)((char*)(cache)->pool.base + (offset)))

// ====== Tag Hash 函数（FNV-1a）======
static uint64_t tag_hash(const char* tag, size_t len) {
    uint64_t hash = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        hash ^= (unsigned char)tag[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

// ====== Tag 提取（从 value 中）======
// 只索引显式 `"tags": [...]` 字段。旧实现把整个 value（JSON 键名、消息正文）
// 按 token 全量切分，导致每条消息都要建几百个 tag：既费 CPU/内存，又因为
// tag 索引不持久化而与重启后的行为不一致。lite 的事实/笔记本来就写显式 tags，
// 其余内容由 recall 的前缀扫描覆盖。

// 在 JSON 文本里定位 "tags" 字段的值起点（冒号之后）。
static const char* find_tags_value(const char* v, size_t n) {
    for (size_t i = 0; i + 5 < n; i++) {
        if (v[i] != '"' || v[i + 5] != '"') continue;
        if (memcmp(v + i + 1, "tags", 4) != 0) continue;
        size_t j = i + 6;
        while (j < n) {
            char c = v[j];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { j++; continue; }
            break;
        }
        if (j < n && v[j] == ':') return v + j + 1;
    }
    return NULL;
}

#define TAG_MAX_COUNT 64
#define TAG_MAX_LEN   128

// 从 value 中提取显式 tags 数组，返回 tag 字符串数组
// 调用者负责释放返回的字符串数组和每个字符串
static char** extract_tags(const char* value, size_t value_len, size_t* out_count) {
    *out_count = 0;
    if (!value || value_len == 0) return NULL;

    const char* p = find_tags_value(value, value_len);
    const char* end = value + value_len;
    if (!p) return NULL;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    if (p >= end || *p != '[') return NULL;

    char** tags = malloc(sizeof(char*) * TAG_MAX_COUNT);
    if (!tags) return NULL;

    size_t count = 0;
    p++;
    while (p < end && count < TAG_MAX_COUNT) {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
        if (p >= end || *p == ']') break;
        if (*p != '"') {
            // 非字符串元素：跳到下一个分隔符
            while (p < end && *p != ',' && *p != ']') p++;
            continue;
        }
        p++;
        char buf[TAG_MAX_LEN + 1];
        size_t len = 0;
        while (p < end && *p != '"') {
            char c = *p++;
            if (c == '\\' && p < end) {
                c = *p++;
                switch (c) {
                    case 'n': c = '\n'; break;
                    case 't': c = '\t'; break;
                    case 'r': c = '\r'; break;
                    case 'b': c = '\b'; break;
                    case 'f': c = '\f'; break;
                    default: break;  // \" \\ \/ 原样保留
                }
            }
            if (len < TAG_MAX_LEN) buf[len++] = c;
        }
        if (p < end && *p == '"') p++;
        if (len < 2) continue;
        buf[len] = '\0';
        char* t = malloc(len + 1);
        if (!t) continue;
        memcpy(t, buf, len + 1);
        tags[count++] = t;
    }

    if (count == 0) {
        free(tags);
        return NULL;
    }
    *out_count = count;
    return tags;
}

static void free_tags(char** tags, size_t count) {
    if (!tags) return;
    for (size_t i = 0; i < count; i++) {
        free(tags[i]);
    }
    free(tags);
}

// ====== Tag 索引操作 ======

int cache_tag_index_init(cache_t* cache) {
    if (!cache) return CACHE_ERR_INVAL;
    
    cache_tag_index_t* idx = &cache->tag_index;
    idx->bucket_count = CACHE_TAG_INDEX_SIZE;
    idx->size = 0;
    idx->buckets = calloc(idx->bucket_count, sizeof(cache_tag_entry_t*));
    
    if (!idx->buckets) return CACHE_ERR_NOMEM;
    return CACHE_OK;
}

void cache_tag_index_destroy(cache_t* cache) {
    if (!cache) return;
    
    cache_tag_index_t* idx = &cache->tag_index;
    if (!idx->buckets) return;
    
    for (size_t i = 0; i < idx->bucket_count; i++) {
        cache_tag_entry_t* entry = idx->buckets[i];
        while (entry) {
            cache_tag_entry_t* next = entry->next;
            free(entry->tag);
            free(entry->offsets);
            free(entry);
            entry = next;
        }
    }
    
    free(idx->buckets);
    idx->buckets = NULL;
    idx->bucket_count = 0;
    idx->size = 0;
}

// 扩容 tag hash 表（负载因子 >= 1.0）。
// 修复：初始仅 64 个 bucket 且永不扩容，海量唯一 token 会让链长线性增长，
// find_or_create_tag 退化为 O(n)，整个导入 O(n²)（内核 6.9 万 chunks 实测）。
static int cache_tag_index_resize(cache_tag_index_t* idx, size_t new_count) {
    if (new_count <= idx->bucket_count) return 0;
    cache_tag_entry_t** new_buckets = calloc(new_count, sizeof(cache_tag_entry_t*));
    if (!new_buckets) return -1;

    for (size_t i = 0; i < idx->bucket_count; i++) {
        cache_tag_entry_t* entry = idx->buckets[i];
        while (entry) {
            cache_tag_entry_t* next = entry->next;
            uint64_t h = tag_hash(entry->tag, strlen(entry->tag));
            size_t b = h & (new_count - 1);
            entry->next = new_buckets[b];
            new_buckets[b] = entry;
            entry = next;
        }
    }

    free(idx->buckets);
    idx->buckets = new_buckets;
    idx->bucket_count = new_count;
    return 0;
}

// 查找或创建 tag entry
static cache_tag_entry_t* find_or_create_tag(cache_tag_index_t* idx, const char* tag, size_t tag_len) {
    // 负载因子控制：tag 数达到 bucket 数即翻倍（保持 2 的幂）
    if (idx->bucket_count > 0 && idx->size >= idx->bucket_count) {
        cache_tag_index_resize(idx, idx->bucket_count * 2);
    }

    uint64_t h = tag_hash(tag, tag_len);
    size_t bucket = h & (idx->bucket_count - 1);
    
    // 查找现有 entry
    cache_tag_entry_t* entry = idx->buckets[bucket];
    while (entry) {
        if (strlen(entry->tag) == tag_len && memcmp(entry->tag, tag, tag_len) == 0) {
            return entry;
        }
        entry = entry->next;
    }
    
    // 创建新 entry
    entry = malloc(sizeof(cache_tag_entry_t));
    if (!entry) return NULL;
    
    entry->tag = malloc(tag_len + 1);
    if (!entry->tag) {
        free(entry);
        return NULL;
    }
    memcpy(entry->tag, tag, tag_len);
    entry->tag[tag_len] = '\0';
    entry->offsets = NULL;
    entry->count = 0;
    entry->capacity = 0;
    entry->next = idx->buckets[bucket];
    idx->buckets[bucket] = entry;
    idx->size++;
    
    return entry;
}

// 从 tag entry 中移除指定 offset
static void remove_offset_from_tag(cache_tag_entry_t* entry, size_t offset) {
    if (!entry || entry->count == 0) return;
    
    size_t write = 0;
    for (size_t i = 0; i < entry->count; i++) {
        if (entry->offsets[i] != offset) {
            entry->offsets[write++] = entry->offsets[i];
        }
    }
    entry->count = write;
}

int cache_tag_index_add(cache_t* cache, size_t entry_offset, const char* value, size_t value_len) {
    if (!cache || !value || value_len == 0) return CACHE_ERR_INVAL;
    
    size_t tag_count = 0;
    char** tags = extract_tags(value, value_len, &tag_count);
    if (!tags || tag_count == 0) return CACHE_OK;  // 没有可索引的 tag
    
    for (size_t i = 0; i < tag_count; i++) {
        size_t tag_len = strlen(tags[i]);
        if (tag_len < 2) continue;  // 跳过短 tag
        
        cache_tag_entry_t* entry = find_or_create_tag(&cache->tag_index, tags[i], tag_len);
        if (!entry) continue;  // 内存不足，跳过
        
        // 注意：这里**不能**线性扫描 entry->offsets 去重。
        // 公共 token（如 struct/return）的 offsets 列表会增长到 O(n)，
        // 每次插入都扫描 → 整个导入退化为 O(n²)（实测 6 万 chunks 后每万块翻倍）。
        // 重复由 cache_set 更新路径先 remove 旧条目保证，这里直接追加（均摊 O(1)）。
        
        // 扩容
        if (entry->count >= entry->capacity) {
            size_t new_cap = entry->capacity == 0 ? 4 : entry->capacity * 2;
            size_t* new_offsets = realloc(entry->offsets, sizeof(size_t) * new_cap);
            if (!new_offsets) continue;  // 内存不足，跳过
            entry->offsets = new_offsets;
            entry->capacity = new_cap;
        }
        
        entry->offsets[entry->count++] = entry_offset;
    }
    
    free_tags(tags, tag_count);
    return CACHE_OK;
}

int cache_tag_index_remove(cache_t* cache, size_t entry_offset, const char* value, size_t value_len) {
    if (!cache || !value || value_len == 0) return CACHE_OK;  // 没有 tag 需要移除
    
    size_t tag_count = 0;
    char** tags = extract_tags(value, value_len, &tag_count);
    if (!tags || tag_count == 0) return CACHE_OK;
    
    for (size_t i = 0; i < tag_count; i++) {
        size_t tag_len = strlen(tags[i]);
        if (tag_len < 2) continue;
        
        uint64_t h = tag_hash(tags[i], tag_len);
        size_t bucket = h & (cache->tag_index.bucket_count - 1);
        
        cache_tag_entry_t* entry = cache->tag_index.buckets[bucket];
        while (entry) {
            if (strlen(entry->tag) == tag_len && strcmp(entry->tag, tags[i]) == 0) {
                remove_offset_from_tag(entry, entry_offset);
                break;
            }
            entry = entry->next;
        }
    }
    
    free_tags(tags, tag_count);
    return CACHE_OK;
}

int cache_tag_index_search(cache_t* cache, const char* tag, size_t** out_offsets, size_t* out_count) {
    if (!cache || !tag || !out_offsets || !out_count) return CACHE_ERR_INVAL;
    
    *out_offsets = NULL;
    *out_count = 0;
    
    size_t tag_len = strlen(tag);
    if (tag_len < 2) return CACHE_ERR_INVAL;
    
    uint64_t h = tag_hash(tag, tag_len);
    size_t bucket = h & (cache->tag_index.bucket_count - 1);
    
    cache_tag_entry_t* entry = cache->tag_index.buckets[bucket];
    while (entry) {
        if (strcmp(entry->tag, tag) == 0) {
            // 复制 offsets
            if (entry->count > 0) {
                size_t* offsets = malloc(sizeof(size_t) * entry->count);
                if (!offsets) return CACHE_ERR_NOMEM;
                memcpy(offsets, entry->offsets, sizeof(size_t) * entry->count);
                *out_offsets = offsets;
                *out_count = entry->count;
            }
            return CACHE_OK;
        }
        entry = entry->next;
    }
    
    return CACHE_OK;  // 未找到，返回空
}

// 全量重建 tag 索引（用于 compact 或 recovery 后）
void cache_tag_index_rebuild(cache_t* cache) {
    if (!cache) return;
    
    // 清空现有索引
    cache_tag_index_destroy(cache);
    cache_tag_index_init(cache);
    
    // 遍历所有 entry，重新建立索引
    uint64_t now = cache_now_ms();
    size_t offset = CACHE_HEADER_SIZE;
    while (offset + sizeof(cache_entry_header_t) <= cache->pool.used) {
        cache_entry_header_t* h = (cache_entry_header_t*)CACHE_PTR(cache, offset);
        
        // 跳过无效 entry
        if (h->key_len == 0 || h->key_len > CACHE_MAX_KEY_LEN ||
            h->value_len > CACHE_MAX_VALUE_LEN ||
            (h->flags & CACHE_ENTRY_DELETED)) {
            offset += MYDB_ALIGN;
            continue;
        }
        
        // 检查是否过期
        if (h->expire_at > 0 && h->expire_at < now) {
            offset += cache_entry_total_size(h);
            continue;
        }
        
        // 获取 value
        const char* value = (const char*)CACHE_PTR(cache, offset + sizeof(cache_entry_header_t) + h->key_len + 1);
        
        // 添加到索引
        cache_tag_index_add(cache, offset, value, h->value_len);
        
        offset += cache_entry_total_size(h);
    }
}
