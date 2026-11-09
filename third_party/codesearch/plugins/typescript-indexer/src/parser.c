#include <stdlib.h>
#include <string.h>
#include "plugin.h"

// Forward declarations from tree-sitter grammar libraries
extern const TSLanguage *tree_sitter_typescript(void);
extern const TSLanguage *tree_sitter_tsx(void);

parse_context_t* parser_create(const char *file_path, const char *source, size_t source_len) {
    parse_context_t *ctx = calloc(1, sizeof(parse_context_t));
    if (!ctx) return NULL;

    ctx->file_path = file_path;

    size_t copy_len = source_len;
    ctx->source = malloc(copy_len + 1);
    if (!ctx->source) {
        free(ctx);
        return NULL;
    }
    memcpy(ctx->source, source, copy_len);
    ctx->source[copy_len] = '\0';
    ctx->source_len = copy_len;

    ctx->parser = ts_parser_new();
    if (!ctx->parser) {
        free(ctx->source);
        free(ctx);
        return NULL;
    }

    const char *lang = get_language_name(file_path);
    if (strcmp(lang, "tsx") == 0) {
        ts_parser_set_language(ctx->parser, tree_sitter_tsx());
    } else {
        // typescript also handles .js/.jsx for now
        ts_parser_set_language(ctx->parser, tree_sitter_typescript());
    }

    ctx->tree = ts_parser_parse_string(ctx->parser, NULL, ctx->source, (uint32_t)copy_len);
    if (!ctx->tree) {
        parser_destroy(ctx);
        return NULL;
    }

    ctx->root = ts_tree_root_node(ctx->tree);
    return ctx;
}

void parser_destroy(parse_context_t *ctx) {
    if (!ctx) return;
    if (ctx->tree) ts_tree_delete(ctx->tree);
    if (ctx->parser) ts_parser_delete(ctx->parser);
    free(ctx->source);
    free(ctx);
}

const char* get_node_type(TSNode node) {
    return ts_node_type(node);
}

TSPoint node_start_point(TSNode node) {
    return ts_node_start_point(node);
}

TSPoint node_end_point(TSNode node) {
    return ts_node_end_point(node);
}

const char* get_language_name(const char *file_path) {
    size_t len = strlen(file_path);
    if (len > 4 && strcmp(file_path + len - 4, ".tsx") == 0) return "tsx";
    if (len > 3 && strcmp(file_path + len - 3, ".ts") == 0) return "typescript";
    if (len > 4 && strcmp(file_path + len - 4, ".jsx") == 0) return "javascript";
    return "javascript";
}
