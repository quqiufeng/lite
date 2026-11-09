#include <stdlib.h>
#include <string.h>
#include "plugin.h"

static char* get_callee_name(TSNode call_expr, const char *source) {
    TSNode func = ts_node_child_by_field_name(call_expr, "function", 8);
    if (ts_node_is_null(func)) return NULL;

    char *text = get_node_text(func, source);
    if (!text) return NULL;

    // Trim whitespace/newlines
    size_t len = strlen(text);
    while (len > 0 && (text[len-1] == '\n' || text[len-1] == ' ' || text[len-1] == '\t')) {
        text[--len] = '\0';
    }

    if (len == 0) {
        free(text);
        return NULL;
    }
    return text;
}

static TSNode find_enclosing_function(TSNode node) {
    TSNode current = node;
    while (!ts_node_is_null(current)) {
        const char *type = ts_node_type(current);
        if (strcmp(type, "function_declaration") == 0 ||
            strcmp(type, "function_expression") == 0 ||
            strcmp(type, "arrow_function") == 0 ||
            strcmp(type, "method_definition") == 0 ||
            strcmp(type, "class_declaration") == 0) {
            return current;
        }
        current = ts_node_parent(current);
    }
    return current; // null
}

static char* get_function_name(TSNode func, const char *source) {
    TSNode null_node = {0};
    (void)null_node;

    // For arrow/function expression assigned to variable, use variable name
    if (strcmp(ts_node_type(func), "arrow_function") == 0 ||
        strcmp(ts_node_type(func), "function_expression") == 0) {
        TSNode var = ts_node_parent(func);
        if (!ts_node_is_null(var) && strcmp(ts_node_type(var), "variable_declarator") == 0) {
            TSNode name = ts_node_child_by_field_name(var, "name", 4);
            if (!ts_node_is_null(name)) {
                return get_node_text(name, source);
            }
        }
    }

    return get_identifier_name(func, source);
}

static void walk_for_calls(parse_context_t *ctx, record_list_t *records, TSNode node) {
    const char *type = ts_node_type(node);

    if (strcmp(type, "call_expression") == 0) {
        TSNode enclosing = find_enclosing_function(node);
        if (!ts_node_is_null(enclosing)) {
            char *caller_name = get_function_name(enclosing, ctx->source);
            char *callee_name = get_callee_name(node, ctx->source);

            // Skip anonymous inline callers
            if (caller_name && strcmp(caller_name, "anonymous") != 0 && callee_name) {
                TSPoint point = ts_node_start_point(node);

                json_t *obj = json_object();
                json_object_set_new(obj, "type", json_string("call_edge"));
                json_object_set_new(obj, "caller", json_string(caller_name));
                json_object_set_new(obj, "caller_file", json_string(ctx->file_path));
                json_object_set_new(obj, "caller_line", json_integer(point.row + 1));
                json_object_set_new(obj, "callee", json_string(callee_name));
                json_object_set_new(obj, "callee_file", json_null());
                json_object_set_new(obj, "callee_line", json_null());
                json_object_set_new(obj, "kind", json_string("direct"));
                records_push(records, obj);
            }

            free(caller_name);
            free(callee_name);
        }
    }

    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
        TSNode child = ts_node_child(node, i);
        walk_for_calls(ctx, records, child);
    }
}

void extract_call_edges(parse_context_t *ctx, record_list_t *records) {
    walk_for_calls(ctx, records, ctx->root);
}
