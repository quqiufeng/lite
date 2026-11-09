#include <stdbool.h>
#include <string.h>
#include "plugin.h"

bool is_declaration_file(const char *file_path) {
    size_t len = strlen(file_path);
    return len > 5 && strcmp(file_path + len - 5, ".d.ts") == 0;
}

bool is_test_file(const char *file_path) {
    size_t len = strlen(file_path);
    if (len > 8 && strstr(file_path, ".test.") != NULL) return true;
    if (len > 9 && strstr(file_path, ".spec.") != NULL) return true;
    if (strstr(file_path, "__tests__") != NULL) return true;
    return false;
}

bool should_skip_file(const char *file_path) {
    // .d.ts files are skipped by default
    if (is_declaration_file(file_path)) return true;
    if (is_test_file(file_path)) return true;
    if (strstr(file_path, "node_modules") != NULL) return true;
    return false;
}

bool should_skip_node(TSNode node, const char *source) {
    (void)source;
    const char *type = ts_node_type(node);

    // Skip type-only nodes from being chunks
    if (strcmp(type, "type_annotation") == 0) return true;
    if (strcmp(type, "type_arguments") == 0) return true;
    if (strcmp(type, "type_parameters") == 0) return true;

    // Skip tiny getters/setters? Keep for now, filter later if needed
    return false;
}
