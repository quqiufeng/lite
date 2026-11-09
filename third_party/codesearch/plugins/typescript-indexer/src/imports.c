#include <stdlib.h>
#include <string.h>
#include "plugin.h"

static char* string_literal_value(TSNode node, const char *source) {
    char *text = get_node_text(node, source);
    if (!text) return NULL;

    size_t len = strlen(text);
    if (len >= 2 && (
        (text[0] == '"' && text[len-1] == '"') ||
        (text[0] == '\'' && text[len-1] == '\'') ||
        (text[0] == '`' && text[len-1] == '`')
    )) {
        text[len-1] = '\0';
        char *result = strdup(text + 1);
        free(text);
        return result;
    }
    return text;
}

static void extract_import_declaration(parse_context_t *ctx, record_list_t *records, TSNode node) {
    TSNode source_node = ts_node_child_by_field_name(node, "source", 6);
    if (ts_node_is_null(source_node)) return;

    char *source_path = string_literal_value(source_node, ctx->source);
    if (!source_path) return;

    json_t *symbols = json_array();
    const char *kind = "named_import";

    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
        TSNode child = ts_node_child(node, i);
        const char *type = ts_node_type(child);

        if (strcmp(type, "import_clause") == 0) {
            uint32_t clause_count = ts_node_child_count(child);
            for (uint32_t j = 0; j < clause_count; j++) {
                TSNode clause_child = ts_node_child(child, j);
                const char *clause_type = ts_node_type(clause_child);

                if (strcmp(clause_type, "identifier") == 0) {
                    // default import: import foo from './bar'
                    kind = "default_import";
                    char *name = get_node_text(clause_child, ctx->source);
                    json_array_append_new(symbols, json_string(name));
                    free(name);
                } else if (strcmp(clause_type, "named_imports") == 0) {
                    // import { foo, bar } from './baz'
                    uint32_t named_count = ts_node_child_count(clause_child);
                    for (uint32_t k = 0; k < named_count; k++) {
                        TSNode spec = ts_node_child(clause_child, k);
                        if (strcmp(ts_node_type(spec), "import_specifier") == 0) {
                            TSNode name_node = ts_node_child_by_field_name(spec, "name", 4);
                            if (ts_node_is_null(name_node)) name_node = spec;
                            char *name = get_node_text(name_node, ctx->source);
                            json_array_append_new(symbols, json_string(name));
                            free(name);
                        }
                    }
                } else if (strcmp(clause_type, "namespace_import") == 0) {
                    // import * as foo from './bar'
                    kind = "namespace_import";
                    TSNode name_node = ts_node_child_by_field_name(clause_child, "name", 4);
                    if (!ts_node_is_null(name_node)) {
                        char *name = get_node_text(name_node, ctx->source);
                        json_array_append_new(symbols, json_string(name));
                        free(name);
                    }
                }
            }
        }
    }

    if (json_array_size(symbols) == 0) {
        // import './side-effect'
        json_array_append_new(symbols, json_string("*"));
        kind = "side_effect";
    }

    json_t *obj = json_object();
    json_object_set_new(obj, "type", json_string("import_edge"));
    json_object_set_new(obj, "source_file", json_string(ctx->file_path));
    json_object_set_new(obj, "target_file", json_string(source_path));
    json_object_set_new(obj, "symbols", symbols);
    json_object_set_new(obj, "kind", json_string(kind));
    records_push(records, obj);

    free(source_path);
}

static void walk_for_imports(parse_context_t *ctx, record_list_t *records, TSNode node) {
    const char *type = ts_node_type(node);

    if (strcmp(type, "import_declaration") == 0) {
        extract_import_declaration(ctx, records, node);
    }

    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
        TSNode child = ts_node_child(node, i);
        walk_for_imports(ctx, records, child);
    }
}

void extract_import_edges(parse_context_t *ctx, record_list_t *records) {
    walk_for_imports(ctx, records, ctx->root);
}
