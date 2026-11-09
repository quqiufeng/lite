#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <math.h>
#include <time.h>
#include <stdint.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/wait.h>
#include "onnx_embedder.h"
#include "cs_compat.h"
#include "cs_internal.h"

#define DIM 768
#define MAX_SEQ 512
#define BATCH_SIZE 128
#define MAX_TEXT_LEN 16384

static int env_flag(const char* name) {
    const char* v = getenv(name);
    return v && *v && strcmp(v, "0") != 0;
}

typedef struct {
    char* name;
    char* text;
    uint64_t hash;
} item_t;

static uint64_t fnv1a64(const void* data, size_t len) {
    const unsigned char* p = (const unsigned char*)data;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// 将非法 UTF-8 字节替换为 '?'（原地）。
// 背景：中文等注释被 chunk 窗口从多字节字符中间截断会留下非法 UTF-8，
// Rust tokenizer(tokenizers-cpp) 遇非法 UTF-8 会 panic 并 abort 整个进程，
// 导致整个向量化任务失败。此处做防御性清洗，保证任何输入都不会崩溃。
static void sanitize_utf8(char* s) {
    unsigned char* p = (unsigned char*)s;
    unsigned char* o = p;
    while (*p) {
        unsigned char c = *p;
        int len;
        if (c < 0x80) len = 1;
        else if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        else { *o++ = '?'; p++; continue; }

        int ok = 1;
        for (int i = 1; i < len; i++) {
            if ((p[i] & 0xC0) != 0x80) { ok = 0; break; }
        }
        // 拒绝过长编码（overlong）与非法代理区（ASCII 安全检查）
        if (ok && len == 2 && c < 0xC2) ok = 0;
        if (ok && len == 4 && c > 0xF4) ok = 0;

        if (!ok) { *o++ = '?'; p++; continue; }
        for (int i = 0; i < len; i++) *o++ = p[i];
        p += len;
    }
    *o = '\0';
}

// Free an item batch
static void free_items(item_t* items, int count) {
    for (int i = 0; i < count; i++) {
        free(items[i].name);
        free(items[i].text);
    }
}

// 长度分桶：按文本长度排序的索引比较器（长度≈token 数）
static item_t* g_sort_items;
static int cmp_len(const void* a, const void* b) {
    int ia = *(const int*)a, ib = *(const int*)b;
    size_t la = strlen(g_sort_items[ia].text);
    size_t lb = strlen(g_sort_items[ib].text);
    if (la < lb) return -1;
    if (la > lb) return 1;
    return ia - ib;
}

// Load up to `max_items` items from the text/meta file pair.
// Returns number of items loaded. 0 means EOF or error.
static int load_items_batch(FILE* text_fp, FILE* meta_fp,
                             item_t* items, int max_items) {
    char* text_line = NULL;
    char* meta_line = NULL;
    size_t text_len = 0, meta_len = 0;
    int n = 0;

    while (n < max_items) {
        ssize_t text_read = getline(&text_line, &text_len, text_fp);
        ssize_t meta_read = getline(&meta_line, &meta_len, meta_fp);
        if (text_read == -1 || meta_read == -1) break;

        // Extract name from meta JSON: "name":"..."
        const char* p = strstr(meta_line, "\"name\":\"");
        if (!p) continue;
        p += 8;
        const char* p_end = strchr(p, '"');
        if (!p_end) continue;

        size_t name_len = p_end - p;
        if (name_len == 0 || name_len > 255) continue;

        items[n].name = malloc(name_len + 1);
        if (!items[n].name) break;
        memcpy(items[n].name, p, name_len);
        items[n].name[name_len] = '\0';

        // Copy text (strip trailing newline/cr)
        if (text_read > 0 && text_line[text_read-1] == '\n') text_line[--text_read] = '\0';
        if (text_read > 0 && text_line[text_read-1] == '\r') text_line[--text_read] = '\0';
        size_t copy_len = (text_read < MAX_TEXT_LEN) ? text_read : (MAX_TEXT_LEN - 1);
        items[n].text = malloc(copy_len + 1);
        if (!items[n].text) { free(items[n].name); break; }
        memcpy(items[n].text, text_line, copy_len);
        items[n].text[copy_len] = '\0';
        sanitize_utf8(items[n].text);
        items[n].hash = fnv1a64(items[n].text, strlen(items[n].text));

        n++;
    }

    free(text_line);
    free(meta_line);
    return n;
}

// Append vectors to existing .bin / .idx files
static void append_vectors(const char* bin_file, const char* idx_file,
                            item_t* items, float** vectors, int count,
                            int is_first) {
    FILE* bin_fp = fopen(bin_file, is_first ? "wb" : "ab");
    FILE* idx_fp = fopen(idx_file, is_first ? "w" : "a");
    if (!bin_fp || !idx_fp) {
        if (bin_fp) fclose(bin_fp);
        if (idx_fp) fclose(idx_fp);
        return;
    }

    if (is_first) {
        // Write header: count + dim (will be updated at end)
        uint32_t h_count = 0;
        uint32_t h_dim = DIM;
        fwrite(&h_count, 4, 1, bin_fp);
        fwrite(&h_dim, 4, 1, bin_fp);
    }

    // Seek to end of existing data (after header for first batch)
    fseek(bin_fp, 0, SEEK_END);
    size_t offset = ftell(bin_fp);
    if (offset < 8) offset = 8; // minimum: header size

    for (int i = 0; i < count; i++) {
        uint32_t name_len = strlen(items[i].name);
        fwrite(&name_len, 4, 1, bin_fp);
        fwrite(items[i].name, 1, name_len, bin_fp);

        fprintf(idx_fp, "\"%s\":%zu\n", items[i].name, offset + 4 + name_len);

        // Normalize
        float vec[DIM];
        memcpy(vec, vectors[i], DIM * sizeof(float));
        float norm = 0;
        for (int j = 0; j < DIM; j++) norm += vec[j] * vec[j];
        norm = sqrtf(norm);
        if (norm > 1e-12) {
            for (int j = 0; j < DIM; j++) vec[j] /= norm;
        }
        fwrite(vec, sizeof(float), DIM, bin_fp);
        offset += 4 + name_len + DIM * sizeof(float);
    }

    fclose(bin_fp);
    fclose(idx_fp);
}

// Rewrite header with final count
static void update_header(const char* bin_file, int total_count) {
    FILE* fp = fopen(bin_file, "r+b");
    if (fp) {
        fseek(fp, 0, SEEK_SET);
        fwrite(&total_count, 4, 1, fp);
        fclose(fp);
    }
}

// ---------------- Incremental cache ----------------
// Sidecar `<prefix>.hash` 记录每条向量对应的 chunk 文本哈希。下次向量化时
// 同一目录里 name+hash 都命中的 chunk 直接复用旧向量，模型完全不加载。
#define CS_HASH_MAGIC "CSH1"

typedef struct {
    char* name;
    uint64_t hash;
    size_t offset;
} old_entry_t;

static int cmp_old_entry(const void* a, const void* b) {
    const old_entry_t* x = (const old_entry_t*)a;
    const old_entry_t* y = (const old_entry_t*)b;
    int c = strcmp(x->name, y->name);
    if (c != 0) return c;
    if (x->hash < y->hash) return -1;
    if (x->hash > y->hash) return 1;
    return 0;
}

static void free_old_entries(old_entry_t* e, int n) {
    if (!e) return;
    for (int i = 0; i < n; i++) free(e[i].name);
    free(e);
}

static uint64_t model_tag(const char* model_path) {
    struct stat st;
    char buf[640];
    if (stat(model_path, &st) != 0) {
        snprintf(buf, sizeof(buf), "%s", model_path);
    } else {
        snprintf(buf, sizeof(buf), "%s|%lld|%lld", model_path,
                 (long long)st.st_size, (long long)st.st_mtime);
    }
    return fnv1a64(buf, strlen(buf));
}

static int load_old_store(const char* bin_file, const char* hash_file,
                          uint64_t tag, FILE** out_bin,
                          old_entry_t** out_entries, int* out_count) {
    *out_bin = NULL;
    *out_entries = NULL;
    *out_count = 0;

    FILE* bf = fopen(bin_file, "rb");
    FILE* hf = fopen(hash_file, "rb");
    if (!bf || !hf) {
        if (bf) fclose(bf);
        if (hf) fclose(hf);
        return 0;
    }

    uint32_t bcount = 0, bdim = 0;
    char magic[4];
    uint64_t htag = 0;
    uint32_t hdim = 0, reserved = 0;
    if (fread(&bcount, 4, 1, bf) != 1 || fread(&bdim, 4, 1, bf) != 1 ||
        fread(magic, 1, 4, hf) != 4 || fread(&htag, 8, 1, hf) != 1 ||
        fread(&hdim, 4, 1, hf) != 1 || fread(&reserved, 4, 1, hf) != 1 ||
        memcmp(magic, CS_HASH_MAGIC, 4) != 0 || htag != tag ||
        bdim != DIM || hdim != DIM || bcount == 0) {
        fclose(bf);
        fclose(hf);
        return 0;
    }

    old_entry_t* entries = calloc(bcount, sizeof(old_entry_t));
    if (!entries) {
        fclose(bf);
        fclose(hf);
        return 0;
    }

    int ok = 1;
    for (uint32_t i = 0; i < bcount; i++) {
        uint32_t nl = 0;
        if (fread(&nl, 4, 1, bf) != 1 || nl == 0 || nl > 255) { ok = 0; break; }
        char name[256];
        if (fread(name, 1, nl, bf) != nl) { ok = 0; break; }
        name[nl] = '\0';

        off_t off = ftello(bf);
        if (off < 0 || fseeko(bf, (off_t)DIM * (off_t)sizeof(float), SEEK_CUR) != 0) {
            ok = 0;
            break;
        }

        uint32_t hnl = 0;
        uint64_t h = 0;
        char hname[256];
        if (fread(&hnl, 4, 1, hf) != 1 || hnl != nl ||
            fread(hname, 1, hnl, hf) != hnl ||
            fread(&h, 8, 1, hf) != 1 || memcmp(name, hname, nl) != 0) {
            ok = 0;
            break;
        }

        entries[i].name = strdup(name);
        entries[i].hash = h;
        entries[i].offset = (size_t)off;
        if (!entries[i].name) { ok = 0; break; }
    }
    fclose(hf);

    if (!ok) {
        fclose(bf);
        free_old_entries(entries, bcount);
        return 0;
    }

    qsort(entries, bcount, sizeof(old_entry_t), cmp_old_entry);
    *out_bin = bf;
    *out_entries = entries;
    *out_count = (int)bcount;
    return 1;
}

static old_entry_t* find_old_entry(old_entry_t* entries, int n,
                                   const char* name, uint64_t hash) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        int c = strcmp(entries[mid].name, name);
        if (c < 0) lo = mid + 1;
        else if (c > 0) hi = mid - 1;
        else {
            int start = mid;
            while (start > 0 && strcmp(entries[start - 1].name, name) == 0) start--;
            for (int i = start; i < n && strcmp(entries[i].name, name) == 0; i++) {
                if (entries[i].hash == hash) return &entries[i];
            }
            return NULL;
        }
    }
    return NULL;
}

static void append_hashes(FILE* hf, item_t* items, int count) {
    for (int i = 0; i < count; i++) {
        uint32_t nl = (uint32_t)strlen(items[i].name);
        fwrite(&nl, 4, 1, hf);
        fwrite(items[i].name, 1, nl, hf);
        fwrite(&items[i].hash, sizeof(uint64_t), 1, hf);
    }
}

int lite_cs_vectorize_main(int argc, char** argv) {
    if (argc < 2) {
        printf("C Batch Vector Generator (streaming, low-memory)\n");
        printf("Usage: %s <cache_dir> [--model mpnet|jina] [--name project_name] [--batch N] [--fp16]\n", argv[0]);
        return 1;
    }

    const char* cache_dir = argv[1];
    const char* model_type = "jina";
    const char* custom_name = NULL;
    int batch_size = BATCH_SIZE;
    // Jina 有 model_fp16.onnx 时默认用它：GPU 上明显快于 FP32，向量差异可忽略。
    // 显式 LITE_CS_FP16=0 / --no-fp16 可关；模型缺失时自动回退 model.onnx。
    int use_fp16 = 1;
    const char* fp16_env = getenv("LITE_CS_FP16");
    if (fp16_env && *fp16_env) use_fp16 = env_flag("LITE_CS_FP16");

    const char* env_batch = getenv("LITE_CS_BATCH");
    if (env_batch && *env_batch) {
        int b = atoi(env_batch);
        if (b >= 1 && b <= 4096) batch_size = b;
    }

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) model_type = argv[++i];
        else if (strcmp(argv[i], "--name") == 0 && i + 1 < argc) custom_name = argv[++i];
        else if (strcmp(argv[i], "--batch") == 0 && i + 1 < argc) {
            int b = atoi(argv[++i]);
            if (b >= 1 && b <= 4096) batch_size = b;
        } else if (strcmp(argv[i], "--fp16") == 0) {
            use_fp16 = 1;
        } else if (strcmp(argv[i], "--no-fp16") == 0) {
            use_fp16 = 0;
        }
    }

    char text_file[512], meta_file[512];
    snprintf(text_file, sizeof(text_file), "%s/chunks_text.txt", cache_dir);
    snprintf(meta_file, sizeof(meta_file), "%s/chunks_meta.jsonl", cache_dir);

    FILE* text_fp = fopen(text_file, "r");
    FILE* meta_fp = fopen(meta_file, "r");
    if (!text_fp || !meta_fp) {
        if (text_fp) fclose(text_fp);
        if (meta_fp) fclose(meta_fp);
        fprintf(stderr, "Failed to open %s or %s\n", text_file, meta_file);
        return 1;
    }

    const char* model_home = getenv("LITE_CS_MODEL_DIR");
    if (!model_home || !*model_home) model_home = "/opt/models";
    char model_path[512], vocab_path[512];
    int max_seq = MAX_SEQ;
    if (strcmp(model_type, "jina") == 0) {
        char base_dir[512];
        snprintf(base_dir, sizeof(base_dir), "%s/jina-embeddings-v2-base-code", model_home);
        const char* model_file = getenv("LITE_CS_MODEL_FILE");
        if (model_file && *model_file) {
            if (model_file[0] == '/') snprintf(model_path, sizeof(model_path), "%s", model_file);
            else snprintf(model_path, sizeof(model_path), "%s/%s", base_dir, model_file);
        } else if (use_fp16) {
            snprintf(model_path, sizeof(model_path), "%s/model_fp16.onnx", base_dir);
            if (access(model_path, R_OK) != 0) {
                // /opt/models 里 model.onnx 常是软链；到真实文件同目录找 model_fp16.onnx。
                char flat[512], resolved[PATH_MAX];
                snprintf(flat, sizeof(flat), "%s/model.onnx", base_dir);
                if (realpath(flat, resolved)) {
                    char* slash = strrchr(resolved, '/');
                    if (slash) {
                        *slash = '\0';
                        snprintf(model_path, sizeof(model_path), "%s/model_fp16.onnx", resolved);
                    }
                }
            }
            if (access(model_path, R_OK) != 0) {
                fprintf(stderr, "[WARN] model_fp16.onnx not found, falling back to model.onnx\n");
                snprintf(model_path, sizeof(model_path), "%s/model.onnx", base_dir);
            }
        } else {
            snprintf(model_path, sizeof(model_path), "%s/model.onnx", base_dir);
        }
        snprintf(vocab_path, sizeof(vocab_path), "%s/vocab.json", base_dir);
    } else {
        snprintf(model_path, sizeof(model_path), "%s/all-mpnet-base-v2/model.onnx", model_home);
        snprintf(vocab_path, sizeof(vocab_path), "%s/all-mpnet-base-v2/vocab.txt", model_home);
        max_seq = 128;
    }

    // Auto-detect project name
    const char* repo_name = strrchr(cache_dir, '/');
    repo_name = repo_name ? repo_name + 1 : cache_dir;
    char safe_name[256];
    if (custom_name) {
        strncpy(safe_name, custom_name, sizeof(safe_name) - 1);
    } else {
        strncpy(safe_name, repo_name, sizeof(safe_name) - 1);
        char* suffix = strstr(safe_name, "_cache");
        if (suffix) *suffix = '\0';
        if (strlen(safe_name) == 0) strcpy(safe_name, "unknown");
    }
    safe_name[sizeof(safe_name) - 1] = '\0';

    // Create vectors/ directory
    char vec_dir[512];
    snprintf(vec_dir, sizeof(vec_dir), "%s/vectors", cache_dir);
    mkdir(vec_dir, 0755);

    char bin_file[512], idx_file[512], hash_file[512];
    snprintf(bin_file, sizeof(bin_file), "%s/code_local_%s.jina.bin", vec_dir, safe_name);
    snprintf(idx_file, sizeof(idx_file), "%s/code_local_%s.jina.idx", vec_dir, safe_name);
    snprintf(hash_file, sizeof(hash_file), "%s/code_local_%s.jina.hash", vec_dir, safe_name);

    // 先写临时文件，全部成功后再 rename；中断不会破坏已有索引。
    char bin_tmp[640], idx_tmp[640], hash_tmp[640];
    snprintf(bin_tmp, sizeof(bin_tmp), "%s.tmp.%d", bin_file, (int)getpid());
    snprintf(idx_tmp, sizeof(idx_tmp), "%s.tmp.%d", idx_file, (int)getpid());
    snprintf(hash_tmp, sizeof(hash_tmp), "%s.tmp.%d", hash_file, (int)getpid());
    unlink(bin_tmp);
    unlink(idx_tmp);
    unlink(hash_tmp);

    // 增量复用：同名且文本哈希一致的 chunk 直接拷旧向量，模型不再加载。
    uint64_t tag = model_tag(model_path);
    FILE* old_bin = NULL;
    old_entry_t* old_entries = NULL;
    int old_count = 0;
    int have_old = load_old_store(bin_file, hash_file, tag,
                                  &old_bin, &old_entries, &old_count);
    if (have_old) {
        printf("Incremental cache: %d vectors available\n", old_count);
    }
    onnx_embedder_t* embedder = NULL;
    FILE* hash_fp = NULL;
    int hash_header_written = 0;
    int embed_disabled = 0;

    // Streaming: process in batches
    // Streaming + length-bucketing: 读取一个窗口 → 按文本长度排序 → 同长度组批
    // （减少 padding，多数批从 512 降到 ~192/256，显著降低 GPU 计算）
    printf("Encoding (streaming + length-bucketed, batch_size=%d)...\n", batch_size);
    #define EMB_WINDOW 2048
    item_t* window = malloc(EMB_WINDOW * sizeof(item_t));
    int* order = malloc(EMB_WINDOW * sizeof(int));
    char* failed = malloc(EMB_WINDOW);
    if (!window || !order || !failed) { fprintf(stderr, "OOM\n"); return 1; }

    clock_t start = clock();
    int total_processed = 0;   // items seen
    int total_written = 0;     // items successfully embedded + written
    int is_first = 1;
    int batch_id = 0;
    int failed_batches = 0;
    int failed_items = 0;
    int hnsw_failed = 0;
    int reused_total = 0;
    int embedded_total = 0;

    while (1) {
        int n = load_items_batch(text_fp, meta_fp, window, EMB_WINDOW);
        if (n == 0) break;
        total_processed += n;

        g_sort_items = window;
        for (int i = 0; i < n; i++) { order[i] = i; failed[i] = 0; }
        qsort(order, n, sizeof(int), cmp_len);

        float* winvec = malloc((size_t)n * DIM * sizeof(float));
        char* cached = calloc(n, 1);
        if (!winvec || !cached) { free(winvec); free(cached); free_items(window, n); break; }

        // 先用增量缓存填好能复用的位置，剩下缺失的才进模型。
        for (int i = 0; i < n; i++) {
            old_entry_t* old = have_old
                ? find_old_entry(old_entries, old_count, window[i].name, window[i].hash)
                : NULL;
            if (old &&
                fseeko(old_bin, (off_t)old->offset, SEEK_SET) == 0 &&
                fread(winvec + (size_t)i * DIM, sizeof(float), DIM, old_bin) == (size_t)DIM) {
                cached[i] = 1;
                reused_total++;
            }
        }

        for (int base = 0; base < n; base += batch_size) {
            int m = 0;
            for (int j = base; j < n && j < base + batch_size; j++) {
                if (!cached[order[j]]) m++;
            }
            if (m == 0) continue;

            const char** texts = malloc(m * sizeof(char*));
            float* vecbuf = malloc((size_t)m * DIM * sizeof(float));
            if (!texts || !vecbuf) {
                free(texts); free(vecbuf);
                failed_items += m;
                for (int j = base; j < n && j < base + batch_size; j++) {
                    if (!cached[order[j]]) failed[order[j]] = 1;
                }
                continue;
            }
            int k = 0;
            for (int j = base; j < n && j < base + batch_size; j++) {
                int orig = order[j];
                if (!cached[orig]) texts[k++] = window[orig].text;
            }
            batch_id++;

            if (embed_disabled) {
                failed_items += m;
                for (int j = base; j < n && j < base + batch_size; j++) {
                    if (!cached[order[j]]) failed[order[j]] = 1;
                }
                free(texts); free(vecbuf);
                continue;
            }

            if (!embedder) {
                printf("Loading %s embedder...\n", model_type);
                embedder = onnx_embedder_init(model_path, vocab_path, max_seq, DIM);
                if (!embedder) {
                    fprintf(stderr, "Failed to load embedder: %s\n", onnx_embedder_error());
                    embed_disabled = 1;
                    failed_items += m;
                    for (int j = base; j < n && j < base + batch_size; j++) {
                        if (!cached[order[j]]) failed[order[j]] = 1;
                    }
                    free(texts); free(vecbuf);
                    continue;
                }
            }

            if (onnx_embedder_encode_batch(embedder, texts, m, vecbuf) != 0) {
                // Fail loud: never write zero vectors (silently destroys search)
                fprintf(stderr, "  [ERROR] batch %d encode failed (n=%d) - skipped\n", batch_id, m);
                failed_batches++;
                failed_items += m;
                for (int j = base; j < n && j < base + batch_size; j++) {
                    if (!cached[order[j]]) failed[order[j]] = 1;
                }
            } else {
                embedded_total += m;
                k = 0;
                for (int j = base; j < n && j < base + batch_size; j++) {
                    int orig = order[j];
                    if (cached[orig]) continue;
                    memcpy(winvec + (size_t)orig * DIM, vecbuf + (size_t)k * DIM,
                           (size_t)DIM * sizeof(float));
                    k++;
                }
            }
            free(texts);
            free(vecbuf);
        }

        // 按原始顺序写出成功项（.idx 记录 name→offset，故顺序可重排，只需一致）
        item_t* ok_items = malloc((size_t)n * sizeof(item_t));
        float** ok_vecs = malloc((size_t)n * sizeof(float*));
        if (ok_items && ok_vecs) {
            int ok = 0;
            for (int i = 0; i < n; i++) {
                if (!failed[i]) {
                    ok_items[ok] = window[i];
                    ok_vecs[ok] = winvec + (size_t)i * DIM;
                    ok++;
                }
            }
            if (ok > 0) {
                append_vectors(bin_tmp, idx_tmp, ok_items, ok_vecs, ok, is_first);
                if (!hash_fp) {
                    hash_fp = fopen(hash_tmp, "wb");
                    if (hash_fp && !hash_header_written) {
                        fwrite(CS_HASH_MAGIC, 1, 4, hash_fp);
                        fwrite(&tag, 8, 1, hash_fp);
                        uint32_t hdim = DIM, zero = 0;
                        fwrite(&hdim, 4, 1, hash_fp);
                        fwrite(&zero, 4, 1, hash_fp);
                        hash_header_written = 1;
                    }
                }
                if (hash_fp) append_hashes(hash_fp, ok_items, ok);
                is_first = 0;
                total_written += ok;
            }
        } else {
            failed_items += n;
        }
        free(ok_items);
        free(ok_vecs);
        free(winvec);
        free(cached);

        free_items(window, n);

        // Progress
        double elapsed = (double)(clock() - start) / CLOCKS_PER_SEC;
        printf("  Progress: %d/%d items (%.0f items/s, reused %d, batch %d)\n",
               total_written, total_processed,
               total_processed / (elapsed > 0 ? elapsed : 1), reused_total, batch_id);
    }

    free(window);
    free(order);
    free(failed);
    fclose(text_fp);
    fclose(meta_fp);
    if (old_bin) fclose(old_bin);
    if (hash_fp) fclose(hash_fp);
    free_old_entries(old_entries, old_count);

    // 全部命中缓存且没有失败：旧 bin/idx/hnsw 仍然有效，直接跳过重写和重建。
    int unchanged = (failed_items == 0 && embedded_total == 0 &&
                     reused_total == total_processed && total_processed > 0 &&
                     old_count == total_processed);
    if (unchanged) {
        unlink(bin_tmp);
        unlink(idx_tmp);
        unlink(hash_tmp);
        printf("Unchanged: %d vectors reused; skip rewrite and HNSW rebuild\n", reused_total);
        onnx_embedder_free(embedder);
        return 0;
    }

    if (total_written == 0) {
        fprintf(stderr, "ERROR: no vectors written (%d/%d items failed)\n",
                failed_items, total_processed);
        onnx_embedder_free(embedder);
        unlink(bin_tmp);
        unlink(idx_tmp);
        unlink(hash_tmp);
        return 2;
    }

    // Update header, then atomically replace old files.
    update_header(bin_tmp, total_written);
    if (rename(bin_tmp, bin_file) != 0 || rename(idx_tmp, idx_file) != 0) {
        fprintf(stderr, "ERROR: failed to replace vector files: %s\n", strerror(errno));
        unlink(bin_tmp);
        unlink(idx_tmp);
        unlink(hash_tmp);
        onnx_embedder_free(embedder);
        return 2;
    }
    if (hash_header_written) rename(hash_tmp, hash_file);

    double elapsed = (double)(clock() - start) / CLOCKS_PER_SEC;
    printf("Done in %.1fs (%.0f items/s): %d/%d written (reused %d, embedded %d)\n",
           elapsed, total_processed / (elapsed > 0 ? elapsed : 1),
           total_written, total_processed, reused_total, embedded_total);
    printf("Saved vectors to %s\n", bin_file);
    printf("Saved index to %s\n", idx_file);

    // Build HNSW index in-process（库内不再 fork/exec 外部 CLI）。
    printf("Building HNSW index...\n");
    const char* threads = getenv("LITE_CS_HNSW_THREADS");
    if (!threads || !*threads) threads = "8";
    const char* ef = getenv("LITE_CS_HNSW_EF");
    const char* m = getenv("LITE_CS_HNSW_M");
    {
        char* hargv[10];
        int hargc = 0;
        hargv[hargc++] = (char*)"build_hnsw_index";
        hargv[hargc++] = bin_file;
        hargv[hargc++] = (char*)"--threads";
        hargv[hargc++] = (char*)threads;
        if (ef && *ef) { hargv[hargc++] = (char*)"--ef-construction"; hargv[hargc++] = (char*)ef; }
        if (m && *m) { hargv[hargc++] = (char*)"--m"; hargv[hargc++] = (char*)m; }
        hargv[hargc] = NULL;
        if (lite_cs_hnsw_main(hargc, hargv) != 0) {
            fprintf(stderr, "[HNSW] build failed\n");
            hnsw_failed = 1;
        }
    }

    onnx_embedder_free(embedder);

    if (failed_items > 0) {
        fprintf(stderr, "ERROR: %d/%d items failed to embed across %d batches; vectors incomplete\n",
                failed_items, total_processed, failed_batches);
    }
    if (hnsw_failed) {
        fprintf(stderr, "ERROR: HNSW index build failed\n");
    }

    return (failed_items > 0 || hnsw_failed) ? 2 : 0;
}
