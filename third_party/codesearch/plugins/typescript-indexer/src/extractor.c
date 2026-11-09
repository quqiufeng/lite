#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include "plugin.h"

const char* chunk_kind_for_node(const char *node_type) {
    if (strcmp(node_type, "function_declaration") == 0) return "ts_function";
    if (strcmp(node_type, "function_expression") == 0) return "ts_function";
    if (strcmp(node_type, "arrow_function") == 0) return "ts_function";
    if (strcmp(node_type, "method_definition") == 0) return "ts_method";
    if (strcmp(node_type, "class_declaration") == 0) return "ts_class";
    if (strcmp(node_type, "interface_declaration") == 0) return "ts_interface";
    if (strcmp(node_type, "type_alias_declaration") == 0) return "ts_type_alias";
    if (strcmp(node_type, "enum_declaration") == 0) return "ts_enum";
    if (strcmp(node_type, "variable_declarator") == 0) return "ts_variable";
    if (strcmp(node_type, "property_definition") == 0) return "ts_property";
    if (strcmp(node_type, "public_field_definition") == 0) return "ts_property";
    if (strcmp(node_type, "import_declaration") == 0) return "ts_import";
    if (strcmp(node_type, "export_statement") == 0) return "ts_export";
    if (strcmp(node_type, "decorator") == 0) return "ts_decorator";
    if (strcmp(node_type, "module_declaration") == 0) return "ts_namespace";
    return NULL;
}

char* get_node_text(TSNode node, const char *source) {
    uint32_t start = ts_node_start_byte(node);
    uint32_t end = ts_node_end_byte(node);
    size_t len = end - start;
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    memcpy(buf, source + start, len);
    buf[len] = '\0';
    return buf;
}

char* get_signature(TSNode node, const char *source) {
    // Extract first line or first 200 chars as signature
    char *text = get_node_text(node, source);
    if (!text) return NULL;

    size_t len = strlen(text);
    size_t sig_len = len > 200 ? 200 : len;

    // Trim after first newline if it's a long declaration
    for (size_t i = 0; i < sig_len; i++) {
        if (text[i] == '\n' && i > 20) {
            sig_len = i;
            break;
        }
    }

    char *sig = malloc(sig_len + 1);
    if (!sig) {
        free(text);
        return NULL;
    }
    memcpy(sig, text, sig_len);
    sig[sig_len] = '\0';
    free(text);
    return sig;
}

char* get_identifier_name(TSNode node, const char *source) {
    // Try common identifier fields
    TSNode id = ts_node_child_by_field_name(node, "name", 4);
    if (ts_node_is_null(id)) {
        // For variable declarator, identifier is first child
        uint32_t count = ts_node_child_count(node);
        for (uint32_t i = 0; i < count; i++) {
            TSNode child = ts_node_child(node, i);
            if (strcmp(ts_node_type(child), "identifier") == 0 ||
                strcmp(ts_node_type(child), "property_identifier") == 0 ||
                strcmp(ts_node_type(child), "type_identifier") == 0) {
                id = child;
                break;
            }
        }
    }

    if (ts_node_is_null(id)) return NULL;

    uint32_t start = ts_node_start_byte(id);
    uint32_t end = ts_node_end_byte(id);
    size_t len = end - start;
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    memcpy(buf, source + start, len);
    buf[len] = '\0';
    return buf;
}

bool is_exported(TSNode node) {
    TSNode current = node;
    while (!ts_node_is_null(current)) {
        const char *type = ts_node_type(current);
        if (strcmp(type, "export_statement") == 0) return true;
        if (strcmp(type, "program") == 0) break;
        current = ts_node_parent(current);
    }
    return false;
}

static bool is_function_value(TSNode node) {
    const char *type = ts_node_type(node);
    return strcmp(type, "arrow_function") == 0 ||
           strcmp(type, "function_expression") == 0;
}

static bool has_name(TSNode node, const char *source) {
    TSNode id = ts_node_child_by_field_name(node, "name", 4);
    if (!ts_node_is_null(id)) return true;

    // For variable declarator, check if parent var has a name
    TSNode parent = ts_node_parent(node);
    if (!ts_node_is_null(parent) && strcmp(ts_node_type(parent), "variable_declarator") == 0) {
        TSNode var_name = ts_node_child_by_field_name(parent, "name", 4);
        if (!ts_node_is_null(var_name)) return true;
    }
    return false;
}

static bool should_emit_function(TSNode node, const char *source) {
    const char *type = ts_node_type(node);
    if (strcmp(type, "function_declaration") == 0) return true;
    if (strcmp(type, "method_definition") == 0) return true;
    if (strcmp(type, "class_declaration") == 0) return true;
    if (strcmp(type, "interface_declaration") == 0) return true;
    if (strcmp(type, "type_alias_declaration") == 0) return true;
    if (strcmp(type, "enum_declaration") == 0) return true;
    if (strcmp(type, "module_declaration") == 0) return true;

    // For arrow/function expression, only emit if it has a name (assigned to var)
    // and is at top-ish level, not an inline callback
    if (strcmp(type, "arrow_function") == 0 || strcmp(type, "function_expression") == 0) {
        TSNode parent = ts_node_parent(node);
        if (ts_node_is_null(parent)) return false;
        const char *parent_type = ts_node_type(parent);

        // const foo = () => {}
        if (strcmp(parent_type, "variable_declarator") == 0) return true;

        // export default () => {}
        if (strcmp(parent_type, "export_statement") == 0) return true;

        // foo: () => {} in object/class? skip or handle as property
        return false;
    }

    return false;
}

static TSNode get_name_node(TSNode node, const char *source) {
    TSNode null_node = {0};
    TSNode id = ts_node_child_by_field_name(node, "name", 4);
    if (!ts_node_is_null(id)) return id;

    // variable_declarator -> name field
    if (strcmp(ts_node_type(node), "variable_declarator") == 0) {
        TSNode name = ts_node_child_by_field_name(node, "name", 4);
        if (!ts_node_is_null(name)) return name;
    }

    // For arrow function inside variable_declarator, get var name
    TSNode parent = ts_node_parent(node);
    if (!ts_node_is_null(parent) && strcmp(ts_node_type(parent), "variable_declarator") == 0) {
        return ts_node_child_by_field_name(parent, "name", 4);
    }

    return null_node;
}

static bool is_variable_with_function_value(TSNode node) {
    if (strcmp(ts_node_type(node), "variable_declarator") != 0) return false;
    TSNode value = ts_node_child_by_field_name(node, "value", 5);
    if (ts_node_is_null(value)) return false;
    return is_function_value(value);
}

static void emit_chunk(parse_context_t *ctx, record_list_t *records,
                       TSNode node, const char *kind) {
    if (should_skip_node(node, ctx->source)) return;

    TSNode name_node = get_name_node(node, ctx->source);
    char *name;
    if (ts_node_is_null(name_node)) {
        name = strdup("anonymous");
    } else {
        name = get_node_text(name_node, ctx->source);
    }
    if (!name || !name[0]) {
        free(name);
        name = strdup("anonymous");
    }

    char *content = get_node_text(node, ctx->source);
    char *signature = get_signature(node, ctx->source);

    TSPoint start = ts_node_start_point(node);
    TSPoint end = ts_node_end_point(node);

    json_t *obj = json_object();
    json_object_set_new(obj, "type", json_string("chunk"));
    json_object_set_new(obj, "name", json_string(name));
    json_object_set_new(obj, "kind", json_string(kind));
    json_object_set_new(obj, "file", json_string(ctx->file_path));
    json_object_set_new(obj, "line_start", json_integer(start.row + 1));
    json_object_set_new(obj, "line_end", json_integer(end.row + 1));
    json_object_set_new(obj, "language", json_string(get_language_name(ctx->file_path)));
    json_object_set_new(obj, "signature", signature ? json_string(signature) : json_null());
    json_object_set_new(obj, "content", content ? json_string(content) : json_string(""));
    json_object_set_new(obj, "is_export", is_exported(node) ? json_true() : json_false());

    json_t *tags = json_array();
    json_array_append_new(tags, json_string(kind));
    if (is_exported(node)) json_array_append_new(tags, json_string("export"));
    json_object_set_new(obj, "tags", tags);

    records_push(records, obj);

    free(name);
    free(content);
    free(signature);
}

static void walk_for_chunks(parse_context_t *ctx, record_list_t *records, TSNode node) {
    const char *type = ts_node_type(node);
    const char *kind = chunk_kind_for_node(type);

    // Skip variable_declarator if its value is a function (we'll emit the function instead)
    if (strcmp(type, "variable_declarator") == 0 && is_variable_with_function_value(node)) {
        TSNode value = ts_node_child_by_field_name(node, "value", 5);
        const char *func_kind = chunk_kind_for_node(ts_node_type(value));
        if (func_kind) {
            emit_chunk(ctx, records, value, func_kind);
        }
        return; // don't recurse into function body for now
    }

    if (kind && should_emit_function(node, ctx->source)) {
        emit_chunk(ctx, records, node, kind);
    }

    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; i++) {
        TSNode child = ts_node_child(node, i);
        walk_for_chunks(ctx, records, child);
    }
}

void extract_chunks(parse_context_t *ctx, record_list_t *records) {
    walk_for_chunks(ctx, records, ctx->root);
}
