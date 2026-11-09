// lite_codesearch 公共 API：全部 JSON 进 / JSON 出，方便 LuaJIT FFI 直接调用。
// 各子步骤（index/vectorize/import/query...）都是从 my_db CLI main() 改名的实现，
// 这里只负责参数整理、目录创建、stdout 捕获与结果封装。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <jansson.h>

#include "cs_internal.h"
#include "cs_compat.h"

static char g_error[1024];

const char* lite_cs_error(void) {
    return g_error;
}

static void set_error(const char* msg) {
    if (!msg) msg = "unknown error";
    strncpy(g_error, msg, sizeof(g_error) - 1);
    g_error[sizeof(g_error) - 1] = '\0';
}

void lite_cs_free(char* p) {
    free(p);
}

static char* json_ok(int rc) {
    json_t* o = json_object();
    json_object_set_new(o, "ok", rc == 0 ? json_true() : json_false());
    json_object_set_new(o, "exit", json_integer(rc));
    char* s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    return s ? s : strdup("{\"ok\":false,\"error\":\"json_dumps failed\"}");
}

static char* json_fail(const char* msg) {
    json_t* o = json_object();
    json_object_set_new(o, "ok", json_false());
    json_object_set_new(o, "error", json_string(msg ? msg : "unknown error"));
    char* s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    return s ? s : strdup("{\"ok\":false,\"error\":\"json_dumps failed\"}");
}

static int mkdir_p(const char* path) {
    if (!path || !*path) return -1;
    char tmp[1024];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    if (tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char* p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

// 捕获子步骤写到 stdout 的内容（目前只有 query 走 JSON stdout）。
static char* run_capture(int (*fn)(int, char**), int argc, char** argv, int* out_rc) {
    fflush(stdout);
    FILE* tmp = tmpfile();
    if (!tmp) {
        int rc = fn(argc, argv);
        if (out_rc) *out_rc = rc;
        return NULL;
    }

    int saved = dup(fileno(stdout));
    if (saved < 0) {
        fclose(tmp);
        int rc = fn(argc, argv);
        if (out_rc) *out_rc = rc;
        return NULL;
    }
    dup2(fileno(tmp), fileno(stdout));

    int rc = fn(argc, argv);
    fflush(stdout);
    dup2(saved, fileno(stdout));
    close(saved);
    if (out_rc) *out_rc = rc;

    if (fseek(tmp, 0, SEEK_END) != 0) {
        fclose(tmp);
        return NULL;
    }
    long sz = ftell(tmp);
    if (sz <= 0) {
        fclose(tmp);
        return NULL;
    }
    rewind(tmp);
    char* buf = malloc((size_t)sz + 1);
    if (!buf) {
        fclose(tmp);
        return NULL;
    }
    size_t n = fread(buf, 1, (size_t)sz, tmp);
    fclose(tmp);
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
    return buf;
}

// ---------------- index / analysis pipeline ----------------

char* lite_cs_index_full(const char* repo, const char* out_dir, int workers,
                         const char* excludes, const char* plugins, int use_fork,
                         const char* skip_kinds, const char* include_dirs) {
    if (!repo || !*repo) return json_fail("repo required");
    if (!out_dir || !*out_dir) return json_fail("out_dir required");
    if (mkdir_p(out_dir) != 0) {
        set_error("cannot create output directory");
        return json_fail("cannot create output directory");
    }
    char wbuf[32];
    if (workers < 1) workers = 1;
    if (workers > 64) workers = 64;
    snprintf(wbuf, sizeof(wbuf), "%d", workers);

    char* argv[16];
    int argc = 0;
    argv[argc++] = (char*)"code_indexer";
    argv[argc++] = (char*)repo;
    argv[argc++] = (char*)out_dir;
    argv[argc++] = wbuf;
    if (excludes && *excludes) {
        argv[argc++] = (char*)"--exclude-dir";
        argv[argc++] = (char*)excludes;
    }
    if (plugins && *plugins) {
        argv[argc++] = (char*)"--plugins";
        argv[argc++] = (char*)plugins;
    }
    if (skip_kinds && *skip_kinds) {
        argv[argc++] = (char*)"--skip-kinds";
        argv[argc++] = (char*)skip_kinds;
    }
    if (include_dirs && *include_dirs) {
        argv[argc++] = (char*)"--include-dirs";
        argv[argc++] = (char*)include_dirs;
    }
    if (use_fork > 0) argv[argc++] = (char*)"--fork";
    else if (use_fork == 0) argv[argc++] = (char*)"--no-fork";
    argv[argc] = NULL;

    int rc = lite_cs_index_main(argc, argv);
    return json_ok(rc);
}

char* lite_cs_index_ext(const char* repo, const char* out_dir, int workers,
                        const char* excludes, const char* plugins, int use_fork,
                        const char* skip_kinds) {
    return lite_cs_index_full(repo, out_dir, workers, excludes, plugins, use_fork,
                              skip_kinds, NULL);
}

char* lite_cs_index_ex(const char* repo, const char* out_dir, int workers,
                       const char* excludes, const char* plugins, int use_fork) {
    return lite_cs_index_ext(repo, out_dir, workers, excludes, plugins, use_fork, NULL);
}

char* lite_cs_index(const char* repo, const char* out_dir, int workers,
                    const char* excludes, const char* plugins) {
    return lite_cs_index_ex(repo, out_dir, workers, excludes, plugins, -1);
}

char* lite_cs_word_freq(const char* analysis_dir) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");
    char* argv[] = {(char*)"word_freq", (char*)analysis_dir, NULL};
    int rc = lite_cs_word_freq_main(2, argv);
    return json_ok(rc);
}

char* lite_cs_vectorize_ex(const char* analysis_dir, const char* model, const char* name,
                           int batch, int fp16) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");
    char* argv[12];
    int argc = 0;
    argv[argc++] = (char*)"batch_embedder";
    argv[argc++] = (char*)analysis_dir;
    argv[argc++] = (char*)"--model";
    argv[argc++] = (char*)((model && *model) ? model : "jina");
    if (name && *name) {
        argv[argc++] = (char*)"--name";
        argv[argc++] = (char*)name;
    }
    char bbuf[16];
    if (batch > 0) {
        if (batch > 4096) batch = 4096;
        snprintf(bbuf, sizeof(bbuf), "%d", batch);
        argv[argc++] = (char*)"--batch";
        argv[argc++] = bbuf;
    }
    if (fp16 > 0) argv[argc++] = (char*)"--fp16";
    else if (fp16 == 0) argv[argc++] = (char*)"--no-fp16";
    argv[argc] = NULL;
    int rc = lite_cs_vectorize_main(argc, argv);
    return json_ok(rc);
}

char* lite_cs_vectorize(const char* analysis_dir, const char* model, const char* name) {
    return lite_cs_vectorize_ex(analysis_dir, model, name, 0, -1);
}

char* lite_cs_callgraph(const char* analysis_dir) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");
    char* argv[] = {(char*)"call_graph", (char*)analysis_dir, NULL};
    int rc = lite_cs_callgraph_main(2, argv);
    return json_ok(rc);
}

char* lite_cs_dataflow(const char* analysis_dir) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");
    char* argv[] = {(char*)"dataflow", (char*)"analyze", (char*)analysis_dir, NULL};
    int rc = lite_cs_dataflow_main(3, argv);
    return json_ok(rc);
}

char* lite_cs_import(const char* analysis_dir, const char* ns,
                     const char* kv_dir, int only_dataflow) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");
    if (!ns || !*ns) return json_fail("namespace required");
    if (!kv_dir || !*kv_dir) return json_fail("kv_dir required");
    if (mkdir_p(kv_dir) != 0) return json_fail("cannot create kv directory");

    char* argv[10];
    int argc = 0;
    argv[argc++] = (char*)"cache_import";
    argv[argc++] = (char*)analysis_dir;
    argv[argc++] = (char*)ns;
    argv[argc++] = (char*)"--cache-dir";
    argv[argc++] = (char*)kv_dir;
    if (only_dataflow) argv[argc++] = (char*)"--only-dataflow";
    argv[argc] = NULL;

    int rc = lite_cs_import_main(argc, argv);
    return json_ok(rc);
}

char* lite_cs_query(const char* query, const char* repo, const char* type,
                    const char* kv_dir, const char* analysis_dir, const char* model,
                    int max_results, int depth, int no_boost,
                    const char* kind, const char* lang, const char* file) {
    if (!query || !*query) return json_fail("query required");
    if (!kv_dir || !*kv_dir) return json_fail("kv_dir required");

    if (max_results <= 0) max_results = 10;
    if (max_results > 100) max_results = 100;
    if (depth < 0) depth = 0;
    if (depth > 5) depth = 5;

    char* argv[32];
    int argc = 0;
    argv[argc++] = (char*)"cache_query";
    argv[argc++] = (char*)query;
    if (repo && *repo) { argv[argc++] = (char*)"--repo"; argv[argc++] = (char*)repo; }
    if (type && *type) { argv[argc++] = (char*)"--type"; argv[argc++] = (char*)type; }
    argv[argc++] = (char*)"--cache-dir"; argv[argc++] = (char*)kv_dir;
    if (analysis_dir && *analysis_dir) {
        argv[argc++] = (char*)"--analysis-dir"; argv[argc++] = (char*)analysis_dir;
    }
    if (model && *model) { argv[argc++] = (char*)"--model"; argv[argc++] = (char*)model; }
    if (kind && *kind) { argv[argc++] = (char*)"--kind"; argv[argc++] = (char*)kind; }
    if (lang && *lang) { argv[argc++] = (char*)"--lang"; argv[argc++] = (char*)lang; }
    if (file && *file) { argv[argc++] = (char*)"--file"; argv[argc++] = (char*)file; }
    char mbuf[32], dbuf[32];
    snprintf(mbuf, sizeof(mbuf), "%d", max_results);
    snprintf(dbuf, sizeof(dbuf), "%d", depth);
    argv[argc++] = (char*)"--max-results"; argv[argc++] = mbuf;
    argv[argc++] = (char*)"--depth"; argv[argc++] = dbuf;
    if (no_boost) argv[argc++] = (char*)"--no-boost";
    argv[argc] = NULL;

    int rc = 0;
    char* out = run_capture(lite_cs_query_main, argc, argv, &rc);
    if (!out) {
        if (rc == 0) return strdup("{\"ok\":true}");
        set_error("query failed");
        return json_fail("query failed");
    }
    return out;
}

// ---------------- 状态检查 ----------------

static long file_size(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    return (long)st.st_size;
}

static long count_lines(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return -1;
    long n = 0;
    int c, prev = '\n';
    while ((c = fgetc(f)) != EOF) {
        if (c == '\n') n++;
        prev = c;
    }
    if (prev != '\n') n++;
    fclose(f);
    return n;
}

char* lite_cs_check(const char* analysis_dir) {
    if (!analysis_dir || !*analysis_dir) return json_fail("analysis_dir required");

    char path[1200];
    json_t* root = json_object();
    json_object_set_new(root, "ok", json_true());
    json_object_set_new(root, "analysis_dir", json_string(analysis_dir));

    json_t* files = json_object();
    const char* names[] = {
        "chunks_meta.jsonl", "chunks_text.txt", "word_freq.json",
        "call_graph.json", "dataflow.json", "plugin_output.jsonl", NULL
    };
    for (int i = 0; names[i]; i++) {
        snprintf(path, sizeof(path), "%s/%s", analysis_dir, names[i]);
        long sz = file_size(path);
        json_t* f = json_object();
        json_object_set_new(f, "exists", sz >= 0 ? json_true() : json_false());
        json_object_set_new(f, "bytes", json_integer(sz > 0 ? sz : 0));
        // 大文件（内核 chunks_meta/dataflow 可达数百 MB）逐字节统计行数会让
        // 每次 query 前的 status 多花十几秒；只对小文件计数，大文件给 -1。
        long lines = 0;
        if (sz > 0 && sz <= 64L * 1024 * 1024) lines = count_lines(path);
        else if (sz > 0) lines = -1;
        json_object_set_new(f, "lines", json_integer(lines));
        json_object_set_new(files, names[i], f);
    }
    json_object_set_new(root, "files", files);

    json_t* vectors = json_array();
    const char* vdirs[2] = {analysis_dir, NULL};
    char vecdir[1200];
    snprintf(vecdir, sizeof(vecdir), "%s/vectors", analysis_dir);
    vdirs[1] = vecdir;
    for (int vi = 0; vi < 2; vi++) {
        DIR* d = opendir(vdirs[vi]);
        if (!d) continue;
        struct dirent* e;
        while ((e = readdir(d)) != NULL) {
            const char* dot = strrchr(e->d_name, '.');
            if (!dot) continue;
            if (strcmp(dot, ".bin") != 0 && strcmp(dot, ".idx") != 0 &&
                strcmp(dot, ".hnsw") != 0) continue;
            snprintf(path, sizeof(path), "%s/%s", vdirs[vi], e->d_name);
            json_t* v = json_object();
            json_object_set_new(v, "name", json_string(e->d_name));
            json_object_set_new(v, "bytes", json_integer(file_size(path)));
            json_array_append_new(vectors, v);
        }
        closedir(d);
    }
    json_object_set_new(root, "vectors", vectors);

    json_t* models = json_object();
    const char* mh = getenv("LITE_CS_MODEL_DIR");
    if (!mh || !*mh) mh = "/opt/models";
    snprintf(path, sizeof(path), "%s/jina-embeddings-v2-base-code/model.onnx", mh);
    json_object_set_new(models, "jina_onnx", json_boolean(file_size(path) > 0));
    snprintf(path, sizeof(path), "%s/jina-embeddings-v2-base-code/vocab.json", mh);
    json_object_set_new(models, "jina_vocab", json_boolean(file_size(path) > 0));
    json_object_set_new(models, "model_dir", json_string(mh));

    const char* ort = getenv("LITE_ORT_LIB");
    if (!ort || !*ort) ort = "/data/venv/onnxruntime-linux-x64-gpu-1.20.1/lib/libonnxruntime.so.1";
    json_object_set_new(models, "onnxruntime", json_boolean(file_size(ort) > 0));
    json_object_set_new(root, "models", models);

    char* s = json_dumps(root, JSON_COMPACT);
    json_decref(root);
    return s ? s : json_fail("json_dumps failed");
}

char* lite_cs_capabilities(void) {
    json_t* o = json_object();
    json_object_set_new(o, "ok", json_true());
    json_object_set_new(o, "version", json_integer(1));
    json_object_set_new(o, "embedding", json_true());
    const char* mh = getenv("LITE_CS_MODEL_DIR");
    if (!mh || !*mh) mh = "/opt/models";
    json_object_set_new(o, "model_dir", json_string(mh));
    const char* ort = getenv("LITE_ORT_LIB");
    if (!ort || !*ort) ort = "/data/venv/onnxruntime-linux-x64-gpu-1.20.1/lib/libonnxruntime.so.1";
    json_object_set_new(o, "onnxruntime", json_string(ort));
    char* s = json_dumps(o, JSON_COMPACT);
    json_decref(o);
    return s ? s : json_fail("json_dumps failed");
}
