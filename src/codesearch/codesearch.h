#ifndef LITE_CODESEARCH_H
#define LITE_CODESEARCH_H

#ifdef __cplusplus
extern "C" {
#endif

// 所有函数返回 malloc 出来的 JSON 字符串，调用方用 lite_cs_free 释放。
// 失败时也返回 JSON（{"ok":false,"error":"..."}），不会返回 NULL（除 OOM）。

char* lite_cs_index(const char* repo, const char* out_dir, int workers,
                    const char* excludes, const char* plugins);
char* lite_cs_index_ex(const char* repo, const char* out_dir, int workers,
                       const char* excludes, const char* plugins, int use_fork);
char* lite_cs_index_ext(const char* repo, const char* out_dir, int workers,
                        const char* excludes, const char* plugins, int use_fork,
                        const char* skip_kinds);
char* lite_cs_index_full(const char* repo, const char* out_dir, int workers,
                         const char* excludes, const char* plugins, int use_fork,
                         const char* skip_kinds, const char* include_dirs);
char* lite_cs_word_freq(const char* analysis_dir);
char* lite_cs_vectorize(const char* analysis_dir, const char* model, const char* name);
char* lite_cs_vectorize_ex(const char* analysis_dir, const char* model, const char* name,
                           int batch, int fp16);
char* lite_cs_callgraph(const char* analysis_dir);
char* lite_cs_dataflow(const char* analysis_dir);
char* lite_cs_dataflow_query(const char* query, const char* kv_dir, const char* ns,
                             int max_results);
char* lite_cs_import(const char* analysis_dir, const char* ns,
                     const char* kv_dir, int only_dataflow);

char* lite_cs_query(const char* query, const char* repo, const char* type,
                    const char* kv_dir, const char* analysis_dir, const char* model,
                    int max_results, int depth, int no_boost,
                    const char* kind, const char* lang, const char* file,
                    const char* path_prefix, const char* def_filter);

char* lite_cs_check(const char* analysis_dir);
char* lite_cs_capabilities(void);
const char* lite_cs_error(void);
void lite_cs_free(char* p);

#ifdef __cplusplus
}
#endif

#endif
