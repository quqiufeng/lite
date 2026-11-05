#ifndef CACHE_INDEX_H
#define CACHE_INDEX_H

#include "cache_internal.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Index file magic
#define CACHE_INDEX_MAGIC     0x5849594D  // "MYIX" little-endian
#define CACHE_INDEX_VERSION   1

// Index types
#define INDEX_TYPE_HASH       1
#define INDEX_TYPE_SORTED     2
#define INDEX_TYPE_VECTOR     3
#define INDEX_TYPE_TAG        4
#define INDEX_TYPE_HNSW       5

// Index file header (24 bytes)
typedef struct __attribute__((packed)) {
    uint32_t magic;           // "MYIX"
    uint32_t version;         // 1
    uint64_t total_size;      // Total file size
    uint32_t index_count;     // Number of index entries
    uint32_t reserved;
} cache_index_file_header_t;

// Index entry header (36 bytes)
typedef struct __attribute__((packed)) {
    uint32_t type;            // Index type
    uint32_t reserved;
    uint64_t data_offset;     // Offset to data in file
    uint64_t data_size;       // Size of data
    uint64_t entry_count;     // Number of entries
    uint64_t reserved2;
} cache_index_entry_t;

// Hash index data layout:
//   bucket_count (8)
//   size (8)
//   buckets[] (16 bytes each)

// Sorted array data layout:
//   count (8)
//   capacity (8)
//   dirty (4)
//   padding (4)
//   offsets[] (8 bytes each)

// Vector index data layout:
//   count (8)
//   capacity (8)
//   entries[] (24 bytes each)

// ====== Save/Load API ======

// Save all indexes to index.bin
// Returns 0 on success, -1 on error
int cache_index_save(cache_t* cache);

// Load all indexes from index.bin (zero-copy mmap)
// Returns 0 on success, -1 on error (caller should rebuild)
int cache_index_load(cache_t* cache);

// Free mmap resources
void cache_index_unload(cache_t* cache);

// Check if index file exists and is valid
int cache_index_exists(const char* db_dir);

#ifdef __cplusplus
}
#endif

#endif /* CACHE_INDEX_H */
