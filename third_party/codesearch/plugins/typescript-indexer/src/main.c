#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "plugin.h"

void print_usage(const char *prog) {
    fprintf(stderr, "Usage: %s --file <path> [--project <path>] [--tsconfig <path>]\n", prog);
}

bool parse_args(int argc, char **argv, plugin_options_t *opts) {
    memset(opts, 0, sizeof(*opts));
    opts->max_file_size = 1024 * 1024; // 1MB default

    const char *max_size_env = getenv("TS_PARSER_MAX_FILE_SIZE");
    if (max_size_env) {
        opts->max_file_size = (size_t)atoll(max_size_env);
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) {
            opts->file_path = argv[++i];
        } else if (strcmp(argv[i], "--project") == 0 && i + 1 < argc) {
            opts->project_root = argv[++i];
        } else if (strcmp(argv[i], "--tsconfig") == 0 && i + 1 < argc) {
            opts->tsconfig_path = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return false;
        }
    }

    if (!opts->file_path) {
        print_usage(argv[0]);
        return false;
    }

    return true;
}

static char* read_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "[ts-plugin] Failed to open file: %s\n", path);
        return NULL;
    }

    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (len < 0 || len > (long)(1024 * 1024 * 16)) {
        fprintf(stderr, "[ts-plugin] File too large or empty: %s\n", path);
        fclose(fp);
        return NULL;
    }

    char *buf = malloc((size_t)len + 1);
    if (!buf) {
        fclose(fp);
        return NULL;
    }

    size_t read = fread(buf, 1, (size_t)len, fp);
    buf[read] = '\0';
    fclose(fp);

    *out_len = read;
    return buf;
}

int main(int argc, char **argv) {
    plugin_options_t opts;
    if (!parse_args(argc, argv, &opts)) {
        return 1;
    }

    if (should_skip_file(opts.file_path)) {
        return 0;
    }

    size_t source_len = 0;
    char *source = read_file(opts.file_path, &source_len);
    if (!source) {
        return 1;
    }

    if (source_len > opts.max_file_size) {
        fprintf(stderr, "[ts-plugin] File exceeds max size: %s\n", opts.file_path);
        free(source);
        return 1;
    }

    parse_context_t *ctx = parser_create(opts.file_path, source, source_len);
    if (!ctx) {
        free(source);
        return 1;
    }

    ctx->project_root = opts.project_root;

    record_list_t records;
    records_init(&records);

    extract_chunks(ctx, &records);
    extract_call_edges(ctx, &records);
    extract_import_edges(ctx, &records);

    records_print(&records);
    records_free(&records);

    parser_destroy(ctx);
    free(source);

    return 0;
}
