#ifndef TS_INDEXER_PLUGIN_H
#define TS_INDEXER_PLUGIN_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <jansson.h>
#include "tree_sitter/api.h"

typedef struct {
    const char *file_path;
    const char *project_root;
    const char *tsconfig_path;
    size_t max_file_size;
} plugin_options_t;

typedef struct {
    char *source;
    size_t source_len;
    TSParser *parser;
    TSTree *tree;
    TSNode root;
    const char *file_path;
    const char *project_root;
} parse_context_t;

typedef enum {
    REC_CHUNK,
    REC_CALL_EDGE,
    REC_IMPORT_EDGE,
    REC_METADATA
} record_type_t;

typedef struct record_node {
    json_t *json;
    struct record_node *next;
} record_node_t;

typedef struct {
    record_node_t *head;
    record_node_t *tail;
    size_t count;
} record_list_t;

/* main.c */
bool parse_args(int argc, char **argv, plugin_options_t *opts);
void print_usage(const char *prog);

/* parser.c */
parse_context_t* parser_create(const char *file_path, const char *source, size_t source_len);
void parser_destroy(parse_context_t *ctx);
const char* get_node_type(TSNode node);
TSPoint node_start_point(TSNode node);
TSPoint node_end_point(TSNode node);
const char* get_language_name(const char *file_path);

/* extractor.c */
void extract_chunks(parse_context_t *ctx, record_list_t *records);
const char* chunk_kind_for_node(const char *node_type);
char* get_node_text(TSNode node, const char *source);
char* get_signature(TSNode node, const char *source);
char* get_identifier_name(TSNode node, const char *source);
bool is_exported(TSNode node);

/* callgraph.c */
void extract_call_edges(parse_context_t *ctx, record_list_t *records);

/* imports.c */
void extract_import_edges(parse_context_t *ctx, record_list_t *records);

/* filters.c */
bool should_skip_file(const char *file_path);
bool should_skip_node(TSNode node, const char *source);
bool is_declaration_file(const char *file_path);
bool is_test_file(const char *file_path);

/* output.c */
void records_init(record_list_t *records);
void records_push(record_list_t *records, json_t *obj);
void records_print(record_list_t *records);
void records_free(record_list_t *records);

#endif
