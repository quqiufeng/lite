#ifndef LITE_CS_INTERNAL_H
#define LITE_CS_INTERNAL_H

// 从 my_db CLI 工具移植进来的入口（原名 main，库内改名）。
int lite_cs_index_main(int argc, char** argv);
int lite_cs_vectorize_main(int argc, char** argv);
int lite_cs_word_freq_main(int argc, char** argv);
int lite_cs_callgraph_main(int argc, char** argv);
int lite_cs_dataflow_main(int argc, char** argv);
int lite_cs_import_main(int argc, char** argv);
int lite_cs_hnsw_main(int argc, char** argv);
int lite_cs_query_main(int argc, char** argv);

#endif
