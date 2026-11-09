#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <fcntl.h>
#include "cache.h"
#include "cs_compat.h"

// 原版把临时文件写死成 /tmp/code_indexer_*_<worker>，两个 lite 实例
// 同时索引不同仓库会互相覆盖。文件名带上**父进程** pid 后再拼接 worker/序号；
// fork 模式下子进程 getpid() 会变，必须用主进程预先记下的 g_tmp_pid。
static int g_tmp_pid = 0;
static void lite_cs_tmp(char* out, size_t n, const char* what, int a, int b) {
    snprintf(out, n, "/tmp/lite_cs_%d_%s_%d_%d.tmp",
             g_tmp_pid ? g_tmp_pid : (int)getpid(), what, a, b);
}

#define MAX_PATH_LEN 2048

// UTF-8 边界对齐：返回 <= off 的最大位置，使 s[ret] 不是 UTF-8 续接字节(0b10xxxxxx)。
// 用于 chunk 窗口切分，避免把多字节字符（如中文注释）从中间截断产生非法 UTF-8。
static int utf8_floor(const char* s, int off) {
    while (off > 0 && ((unsigned char)s[off] & 0xC0) == 0x80) off--;
    return off;
}

// UTF-8 边界对齐（向后）：给定长度 take，若 content[off+take] 是续接字节则回退 take，
// 保证切片 content[off, off+take) 以完整字符结尾。
static int utf8_floor_len(const char* content, int off, int take) {
    while (take > 0 && ((unsigned char)content[off + take] & 0xC0) == 0x80) take--;
    return take > 0 ? take : 1;
}

// 插件配置
#define MAX_PLUGINS 8
#define MAX_EXTENSIONS 16
#define MAX_PLUGIN_ARGS 8

typedef struct {
    char name[64];
    char command[MAX_PATH_LEN];
    char args[MAX_PLUGIN_ARGS][MAX_PATH_LEN];
    int arg_count;
    char extensions[MAX_EXTENSIONS][16];
    int ext_count;
    int priority;
    int enabled;
} plugin_t;

static plugin_t g_plugins[MAX_PLUGINS];
static int g_plugin_count = 0;
static char g_plugin_registry[MAX_PATH_LEN] = {0};
// --skip-kinds：逗号分隔，按 ctags kind 过滤（header/file/enumerator/macro...）。
static char g_skip_kinds[256] = {0};

static int kind_is_skipped(const char* kind) {
    if (!kind || !kind[0] || !g_skip_kinds[0]) return 0;
    size_t n = strlen(kind);
    const char* p = g_skip_kinds;
    while (*p) {
        while (*p == ',' || *p == ' ') p++;
        const char* e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        while (len > 0 && p[len - 1] == ' ') len--;
        if (len == n && strncmp(p, kind, n) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

// 源文件信息
typedef struct {
    char* path;
} source_file_t;

// Worker 分配
typedef struct {
    const char* repo_path;
    char** files;
    int file_count;
    int capacity;
} worker_t;

// 文件扩展名检测
static int json_extract_str(const char* json, const char* key, char* out, int max_len);
static int json_extract_int(const char* json, const char* key);
static int json_extract_bool(const char* json, const char* key);
static int json_extract_first_array_str(const char* json, const char* key, char* out, int max_len);

static int json_extract_bool(const char* json, const char* key) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (strncmp(p, "true", 4) == 0) return 1;
    return 0;
}

// Plugin registry loading
static void json_unescape_str(const char* src, char* dst, int max_len) {
    int j = 0;
    for (int i = 0; src[i] && j < max_len - 1; i++) {
        if (src[i] == '\\' && src[i+1]) {
            i++;
            switch (src[i]) {
                case 'n': dst[j++] = '\n'; break;
                case 't': dst[j++] = '\t'; break;
                case 'r': dst[j++] = '\r'; break;
                case '\\': dst[j++] = '\\'; break;
                case '"': dst[j++] = '"'; break;
                default: dst[j++] = src[i]; break;
            }
        } else {
            dst[j++] = src[i];
        }
    }
    dst[j] = '\0';
}

static const char* json_extract_array_str(const char* json, const char* key,
                                          int index, char* out, int max_len) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '[') return NULL;
    p++;
    int i = 0;
    while (*p) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p == ']') return NULL;
        if (*p == '"') {
            p++;
            const char* start = p;
            int len = 0;
            while (*p && *p != '"') {
                if (*p == '\\' && *(p+1)) { p += 2; len += 2; }
                else { p++; len++; }
            }
            if (i == index) {
                char raw[1024];
                int copy_len = len < (int)sizeof(raw) - 1 ? len : (int)sizeof(raw) - 1;
                memcpy(raw, start, copy_len);
                raw[copy_len] = '\0';
                json_unescape_str(raw, out, max_len);
                return out;
            }
            if (*p == '"') p++;
        } else {
            // skip non-string primitive
            while (*p && *p != ',' && *p != ']') p++;
        }
        i++;
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p == ',') p++;
    }
    return NULL;
}

static int json_extract_array_count(const char* json, const char* key) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '[') return 0;
    p++;
    int count = 0;
    int depth = 0;
    while (*p) {
        if (*p == '[') depth++;
        else if (*p == ']') {
            if (depth == 0) break;
            depth--;
        } else if (*p == '"') {
            p++;
            while (*p && *p != '"') { if (*p == '\\' && *(p+1)) p++; p++; }
        } else if (*p == ',' && depth == 0) {
            count++;
        }
        p++;
    }
    return count + 1;
}

static int json_extract_first_array_str(const char* json, const char* key, char* out, int max_len) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '[') return 0;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return 0;
    p++;
    int i = 0;
    while (*p && *p != '"' && i < max_len - 1) {
        if (*p == '\\' && *(p+1)) {
            p++;
            switch (*p) {
                case 'n': out[i++] = '\n'; break;
                case 't': out[i++] = '\t'; break;
                case 'r': out[i++] = '\r'; break;
                case '\\': out[i++] = '\\'; break;
                case '"': out[i++] = '"'; break;
                default: out[i++] = *p; break;
            }
        } else {
            out[i++] = *p;
        }
        p++;
    }
    out[i] = '\0';
    return i;
}

static int load_plugin_registry(const char* registry_path) {
    FILE* fp = fopen(registry_path, "r");
    if (!fp) return -1;
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char* buf = malloc(size + 1);
    if (!buf) { fclose(fp); return -1; }
    size_t nread = fread(buf, 1, size, fp);
    buf[nread] = '\0';
    fclose(fp);

    // Support both top-level plugin.json (single object) and registry (array under "plugins")
    const char* plugins_pos = strstr(buf, "\"plugins\"");
    const char* p;
    int is_registry = 0;
    if (plugins_pos) {
        plugins_pos = strstr(plugins_pos, "[");
        if (!plugins_pos) { free(buf); return -1; }
        p = plugins_pos + 1;
        is_registry = 1;
    } else {
        // Single plugin object: ensure it has required fields
        p = buf;
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p != '{' || !strstr(buf, "\"command\"")) { free(buf); return -1; }
    }

    // 插件 JSON 里的相对 command 以 registry 文件所在目录为基准，
    // 这样仓库自带的插件（third_party/codesearch/plugins/...）不依赖绝对路径。
    char plugin_base[MAX_PATH_LEN];
    snprintf(plugin_base, sizeof(plugin_base), "%s", registry_path);
    char* last_slash = strrchr(plugin_base, '/');
    if (last_slash) *last_slash = '\0';
    else snprintf(plugin_base, sizeof(plugin_base), ".");

    int plugin_idx = 0;
    while (*p && plugin_idx < MAX_PLUGINS) {
        // Find next object
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p != '{') break;

        // Extract object boundaries (naive)
        const char* obj_start = p;
        int depth = 0;
        do {
            if (*p == '{') depth++;
            else if (*p == '}') depth--;
            else if (*p == '"') {
                p++;
                while (*p && *p != '"') { if (*p == '\\' && *(p+1)) p++; p++; }
            }
            p++;
        } while (*p && depth > 0);
        int obj_len = p - obj_start;
        char* obj = malloc(obj_len + 1);
        memcpy(obj, obj_start, obj_len);
        obj[obj_len] = '\0';

        plugin_t* pl = &g_plugins[plugin_idx];
        memset(pl, 0, sizeof(plugin_t));

        char enabled_buf[16] = {0};
        json_extract_str(obj, "enabled", enabled_buf, sizeof(enabled_buf));
        pl->enabled = (enabled_buf[0] == '\0' || strcmp(enabled_buf, "true") == 0);

        json_extract_str(obj, "name", pl->name, sizeof(pl->name));

        // "command" may be a string or a single-element array;
        // relative paths resolve against the plugin registry directory.
        char command_str[MAX_PATH_LEN] = {0};
        json_extract_str(obj, "command", command_str, sizeof(command_str));
        if (!command_str[0]) {
            json_extract_first_array_str(obj, "command", command_str, sizeof(command_str));
        }
        if (command_str[0]) {
            if (command_str[0] == '/') {
                snprintf(pl->command, sizeof(pl->command), "%s", command_str);
            } else {
                snprintf(pl->command, sizeof(pl->command), "%s/%s", plugin_base, command_str);
            }
        }

        pl->priority = json_extract_int(obj, "priority");
        if (pl->priority == 0) pl->priority = 100;

        // Args
        pl->arg_count = 0;
        int arg_count = json_extract_array_count(obj, "args");
        for (int a = 0; a < arg_count && a < MAX_PLUGIN_ARGS; a++) {
            json_extract_array_str(obj, "args", a, pl->args[a], sizeof(pl->args[a]));
            pl->arg_count++;
        }

        // Extensions
        pl->ext_count = 0;
        int ext_count = json_extract_array_count(obj, "extensions");
        for (int e = 0; e < ext_count && e < MAX_EXTENSIONS; e++) {
            json_extract_array_str(obj, "extensions", e, pl->extensions[e], sizeof(pl->extensions[e]));
            pl->ext_count++;
        }

        free(obj);
        if (pl->enabled && pl->command[0]) plugin_idx++;

        if (!is_registry) break; // single object: only one plugin

        while (*p && isspace((unsigned char)*p)) p++;
        if (*p == ',') p++;
    }

    free(buf);
    g_plugin_count = plugin_idx;
    return g_plugin_count;
}

static plugin_t* find_plugin_for_file(const char* filepath) {
    const char* ext = strrchr(filepath, '.');
    if (!ext) return NULL;
    int best_priority = -1;
    plugin_t* best = NULL;
    for (int i = 0; i < g_plugin_count; i++) {
        plugin_t* pl = &g_plugins[i];
        if (!pl->enabled) continue;
        for (int e = 0; e < pl->ext_count; e++) {
            if (strcmp(ext, pl->extensions[e]) == 0) {
                if (pl->priority > best_priority) {
                    best_priority = pl->priority;
                    best = pl;
                }
            }
        }
    }
    return best;
}

static int run_plugin(plugin_t* pl, const char* repo_path, const char* file_path,
                      const char* output_file) {
    char file_arg[MAX_PATH_LEN];
    char project_arg[MAX_PATH_LEN];
    snprintf(file_arg, sizeof(file_arg), "%s", file_path);
    snprintf(project_arg, sizeof(project_arg), "%s", repo_path);

    char* argv[MAX_PLUGIN_ARGS + 2];
    argv[0] = pl->command;
    int argc = 1;
    for (int a = 0; a < pl->arg_count; a++) {
        if (strcmp(pl->args[a], "{file}") == 0) argv[argc++] = file_arg;
        else if (strcmp(pl->args[a], "{project}") == 0) argv[argc++] = project_arg;
        else argv[argc++] = pl->args[a];
    }
    argv[argc] = NULL;

    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork plugin");
        return 1;
    }
    if (pid == 0) {
        int fd = open(output_file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror("open plugin output"); exit(1); }
        dup2(fd, STDOUT_FILENO);
        close(fd);
        int fd2 = open("/dev/null", O_WRONLY);
        if (fd2 >= 0) {
            dup2(fd2, STDERR_FILENO);
            close(fd2);
        }
        execv(pl->command, argv);
        perror("execv plugin");
        exit(1);
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

// 源文件信息
static int is_source_file(const char* filename) {
    const char* ext = strrchr(filename, '.');
    if (!ext) return 0;
    return (
        strcmp(ext, ".c") == 0 || strcmp(ext, ".h") == 0 ||
        strcmp(ext, ".cpp") == 0 || strcmp(ext, ".cc") == 0 ||
        strcmp(ext, ".cxx") == 0 || strcmp(ext, ".hpp") == 0 ||
        strcmp(ext, ".py") == 0 || strcmp(ext, ".js") == 0 ||
        strcmp(ext, ".ts") == 0 || strcmp(ext, ".go") == 0 ||
        strcmp(ext, ".rs") == 0 || strcmp(ext, ".java") == 0 ||
        strcmp(ext, ".rb") == 0 || strcmp(ext, ".php") == 0 ||
        strcmp(ext, ".sh") == 0 || strcmp(ext, ".lua") == 0 ||
        strcmp(ext, ".swift") == 0 || strcmp(ext, ".scala") == 0 ||
        strcmp(ext, ".cu") == 0 ||
        strcmp(ext, ".cuh") == 0 ||
        strcmp(ext, ".metal") == 0 ||
        strcmp(ext, ".r") == 0 || strcmp(ext, ".R") == 0
    );
}

// Noise 目录
static const char** g_exclude_dirs = NULL;
static int g_exclude_count = 0;

// --include-dirs：把默认 noise 列表里的目录重新放回来（例如 src/core/tools）。
static char g_include_dirs[512] = {0};

static int dir_is_included(const char* name) {
    if (!name || !name[0] || !g_include_dirs[0]) return 0;
    size_t n = strlen(name);
    const char* p = g_include_dirs;
    while (*p) {
        while (*p == ',' || *p == ' ') p++;
        const char* e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        while (len > 0 && p[len - 1] == ' ') len--;
        if (len == n && strncmp(p, name, n) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

static int is_noise_dir(const char* name) {
    if (dir_is_included(name)) return 0;
    static const char* noise[] = {
        "thirdparty", "3rdparty", "third_party", "third-party",
        "external", "deps", "dependencies", "vendor",
        "build", "cmake-build", "CMakeFiles", "out", "obj", "dist",
        "test", "tests", "testing", "gtest", "googletest",
        "examples", "demo", "demos", "sample", "samples",
        "docs", "doc", "documentation", "website",
        "scripts", "tools", "utils", "benchmark", "benchmarks",
        ".git", "node_modules", "__pycache__", ".pytest_cache",
        NULL
    };
    for (int i = 0; noise[i]; i++) {
        if (strcmp(name, noise[i]) == 0) return 1;
    }
    return 0;
}

// 递归扫描目录
static void scan_directory(const char* base_path, const char* current_path,
                           source_file_t** files, int* count, int* capacity) {
    DIR* dir = opendir(current_path);
    if (!dir) return;
    
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        
        if (is_noise_dir(entry->d_name)) continue;
        
        // Also check runtime exclude list
        int excluded = 0;
        if (g_exclude_dirs) {
            for (int e = 0; e < g_exclude_count; e++) {
                if (strcmp(entry->d_name, g_exclude_dirs[e]) == 0) {
                    excluded = 1;
                    break;
                }
            }
        }
        if (excluded) continue;
        
        char fullpath[MAX_PATH_LEN];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", current_path, entry->d_name);
        
        struct stat st;
        if (stat(fullpath, &st) != 0) continue;
        
        if (S_ISDIR(st.st_mode)) {
            scan_directory(base_path, fullpath, files, count, capacity);
        } else if (S_ISREG(st.st_mode) && is_source_file(entry->d_name)) {
            if (*count >= *capacity) {
                int new_cap = *capacity * 2;
                source_file_t* new_files = realloc(*files, new_cap * sizeof(source_file_t));
                if (!new_files) continue;
                *files = new_files;
                *capacity = new_cap;
            }
            (*files)[*count].path = strdup(fullpath);
            (*count)++;
        }
    }
    closedir(dir);
}

// JSON 字段提取
static int json_extract_str(const char* json, const char* key, char* out, int max_len) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return 0;
    p++;
    int i = 0;
    while (*p && *p != '"' && i < max_len - 1) {
        if (*p == '\\' && *(p+1)) {
            p++;
            switch (*p) {
                case 'n': out[i++] = '\n'; break;
                case 't': out[i++] = '\t'; break;
                case 'r': out[i++] = '\r'; break;
                case '\\': out[i++] = '\\'; break;
                case '"': out[i++] = '"'; break;
                default: out[i++] = *p; break;
            }
        } else {
            out[i++] = *p;
        }
        p++;
    }
    out[i] = '\0';
    return i;
}

static int json_extract_int(const char* json, const char* key) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p == '"') p++;
    int val = 0;
    int sign = 1;
    if (*p == '-') { sign = -1; p++; }
    while (*p && isdigit((unsigned char)*p)) {
        val = val * 10 + (*p - '0');
        p++;
    }
    return sign * val;
}

static const char* detect_language(const char* filepath) {
    const char* ext = strrchr(filepath, '.');
    if (!ext) return "unknown";
    if (strcmp(ext, ".c") == 0) return "c";
    if (strcmp(ext, ".h") == 0) return "c";
    if (strcmp(ext, ".cpp") == 0 || strcmp(ext, ".cc") == 0 || 
        strcmp(ext, ".cxx") == 0 || strcmp(ext, ".hpp") == 0) return "cpp";
    if (strcmp(ext, ".py") == 0) return "python";
    if (strcmp(ext, ".js") == 0) return "javascript";
    if (strcmp(ext, ".ts") == 0) return "typescript";
    if (strcmp(ext, ".go") == 0) return "go";
    if (strcmp(ext, ".rs") == 0) return "rust";
    if (strcmp(ext, ".java") == 0) return "java";
    return "unknown";
}

static int needs_range(const char* kind) {
    return kind[0] && (
        strcmp(kind, "function") == 0 || strcmp(kind, "method") == 0 ||
        strcmp(kind, "func") == 0 ||
        strcmp(kind, "class") == 0 || strcmp(kind, "struct") == 0 ||
        strcmp(kind, "union") == 0 || strcmp(kind, "enum") == 0 ||
        strcmp(kind, "namespace") == 0
    );
}

static int find_end_line(const char* filepath, int start_line) {
    FILE* fp = fopen(filepath, "r");
    if (!fp) return start_line;
    
    int current_line = 0;
    int brace_depth = 0;
    int in_string = 0;
    int string_char = 0;
    int found_open = 0;
    char line[4096];
    
    // Phase 1: read lines from start_line, looking for '{'
    while (fgets(line, sizeof(line), fp)) {
        current_line++;
        if (current_line < start_line) continue;
        
        // Check if this is a declaration (ends with ; before any {)
        char* semicolon = strchr(line, ';');
        char* brace = strchr(line, '{');
        
        if (!found_open && semicolon && (!brace || semicolon < brace)) {
            // It's a declaration, skip
            fclose(fp);
            return 0;  // 0 means no body (declaration only)
        }
        
        // Process the line character by character
        char* p = line;
        while (*p) {
            if (!in_string) {
                if (*p == '"' || *p == '\'') {
                    in_string = 1; string_char = *p;
                } else if (*p == '/' && *(p+1) == '/') {
                    break;  // C++ style comment
                } else if (*p == '/' && *(p+1) == '*') {
                    in_string = 2;  // Multi-line comment start
                } else if (*p == '{') {
                    brace_depth++;
                    found_open = 1;
                } else if (*p == '}') {
                    if (brace_depth > 0) {
                        brace_depth--;
                        if (brace_depth == 0 && found_open) {
                            fclose(fp);
                            return current_line;
                        }
                    }
                }
            } else if (in_string == 2) {
                if (*p == '*' && *(p+1) == '/') { in_string = 0; p++; }
            } else {
                if (*p == string_char && *(p-1) != '\\') in_string = 0;
            }
            p++;
        }
        
        // Safety limits
        if (!found_open && current_line > start_line + 10) {
            // No opening brace found within 10 lines, likely a declaration
            fclose(fp);
            return 0;
        }
        if (found_open && current_line > start_line + 500) {
            fclose(fp);
            return current_line;
        }
    }
    
    fclose(fp);
    return current_line;
}

static int path_has_ext(const char* path, const char* ext) {
    size_t lp = strlen(path), le = strlen(ext);
    return lp > le && strcmp(path + lp - le, ext) == 0;
}

// ctags 的 Lua parser 只认 `function` 这个词，字符串里出现也会当定义：
// `type = "function",`、`tc["function"]`、`~= "function"` 都会产出垃圾 tag
// （tag 名变成 type / fn / ~）。只保留 pattern 里"带引号之外"的 function。
// 另外匿名函数（`pcall(function()`）也会产 tag，ctags 拿前面的标识符当名字：
// `local okf, fn = pcall(function()` → tag 名 `fn`，`then pcall(function()` → `~`。
// 判据：function 左边（跳过空白）是 `(` 或 `,` 就是传参的匿名函数，名字不可信，跳过。
// 只看 function 前后是不是引号不够：`"must return { run = function(args) }"` 里
// function 两侧都是空格/花括号，仍在字符串内。所以逐字符走一遍，跟踪引号状态
// （含 `\"` 转义），只在字符串外认 function。
static int lua_tag_is_definition(const char* tagline) {
    char pat[1024];
    if (json_extract_str(tagline, "pattern", pat, sizeof(pat)) <= 0) return 1;
    char quote = 0;
    for (size_t i = 0; pat[i]; i++) {
        char c = pat[i];
        if (quote) {                                        // 字符串内
            if (c == '\\' && pat[i + 1]) { i++; continue; }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' || c == '\'') { quote = c; continue; }
        if (strncmp(pat + i, "function", 8) != 0) continue;
        char next = pat[i + 8];
        if ((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') ||
            (next >= '0' && next <= '9') || next == '_') continue;  // functionality 之类
        const char* b = pat + i;
        while (b > pat && (b[-1] == ' ' || b[-1] == '\t')) b--;
        char prev = (b == pat) ? ' ' : b[-1];
        if (prev == '(' || prev == ',') continue;           // 传参的匿名函数
        return 1;                                           // 字符串外的真定义
    }
    return 0;
}

// `.lua` 没有花括号：按块关键字算深度（function/if/do/repeat ↔ end/until）。
// ctags 的 Lua parser 不吐 end 字段，走 find_end_line（只认 `{`）要么退化成
// 单行空 chunk、要么把下一个函数的 `{ 0 }` 当成函数体，整个 Lua 语料在语义
// 检索里等于不存在（lite 自己就是 Lua 仓库，所以这条不能省）。
static int find_end_line_lua(const char* filepath, int start_line) {
    FILE* fp = fopen(filepath, "r");
    if (!fp) return 0;
    int line_no = 0, depth = 0, found = 0, last = 0;
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        line_no++;
        if (line_no < start_line) continue;
        last = line_no;
        if (line_no > start_line + 1000) break;
        for (const char* p = line; *p; ) {
            if (p[0] == '-' && p[1] == '-') break;                 // 行注释
            if (*p == '"' || *p == '\'') {                          // 字符串
                char q = *p++;
                while (*p && *p != q) { if (*p == '\\' && p[1]) p++; p++; }
                if (*p) p++;
                continue;
            }
            if (isalpha((unsigned char)*p) || *p == '_') {
                char w[16];
                int n = 0;
                const char* q = p;
                while ((isalnum((unsigned char)*q) || *q == '_') && n < 15) w[n++] = *q++;
                w[n] = '\0';
                p = q;
                // for/while 的 `do` 就算一个开口，不能把 for/while 也数进去
                if (!strcmp(w, "function") || !strcmp(w, "if") ||
                    !strcmp(w, "do") || !strcmp(w, "repeat")) { depth++; found = 1; }
                else if (!strcmp(w, "end") || !strcmp(w, "until")) { if (depth > 0) depth--; }
                continue;
            }
            p++;
        }
        if (found && depth == 0) { fclose(fp); return line_no; }
        if (!found && line_no > start_line + 5) break;
    }
    fclose(fp);
    return found ? last : 0;
}

static int extract_content_fp(FILE* fp, int start_line, int end_line, 
                                char* out, int max_len) {
    if (!fp) return 0;
    
    int current_line = 0;
    int pos = 0;
    char line[4096];
    
    // Reset to beginning if we need to read from earlier lines
    rewind(fp);
    
    while (fgets(line, sizeof(line), fp) && current_line < end_line) {
        current_line++;
        if (current_line < start_line) continue;
        int len = strlen(line);
        if (pos + len < max_len - 1) {
            memcpy(out + pos, line, len);
            pos += len;
        } else break;
    }
    
    out[pos] = '\0';
    return pos;
}

static int json_escape_str(const char* src, char* dst, int max_len) {
    int j = 0;
    for (int i = 0; src[i] && j < max_len - 1; i++) {
        char c = src[i];
        if (c == '"' || c == '\\') {
            if (j < max_len - 2) { dst[j++] = '\\'; dst[j++] = c; }
        } else if (c == '\n') {
            if (j < max_len - 3) { dst[j++] = '\\'; dst[j++] = 'n'; }
        } else if (c == '\r') {
            if (j < max_len - 3) { dst[j++] = '\\'; dst[j++] = 'r'; }
        } else if (c == '\t') {
            if (j < max_len - 3) { dst[j++] = '\\'; dst[j++] = 't'; }
        } else if ((unsigned char)c < 0x20) {
            int n = snprintf(dst + j, max_len - j, "\\u%04x", (unsigned char)c);
            if (n > 0) j += n;
        } else {
            dst[j++] = c;
        }
    }
    dst[j] = '\0';
    return j;
}

// 从函数名所在行回溯到声明开头（含返回类型/限定符行，如 "static void"/"ngx_int_t"）
static int decl_start(char** file_lines, int count, int line) {
    int s = line;
    while (s > 1 && s - 1 <= count) {
        const char* p = file_lines[s - 2];
        while (*p == ' ' || *p == '\t' || *p == '\r') p++;
        if (*p == '\0' || *p == '#' || *p == '/' || *p == '*') break;   // 空/预处理/注释
        int punct = 0;
        for (const char* q = p; *q; q++)
            if (*q == ';' || *q == '{' || *q == '}' || *q == '(' || *q == ')') { punct = 1; break; }
        if (punct) break;
        s--;
    }
    return s;
}

static void write_chunk(FILE* fp, FILE* text_fp, FILE* meta_fp,
                        const char* name, const char* file,
                        const char* kind, int line_start, int line_end,
                        const char* lang, const char* signature,
                        const char* content, const char* docstring) {
    char esc_name[512], esc_file[1024], esc_kind[64], esc_sig[4096];
    char esc_content[65536], esc_doc[8192];

    json_escape_str(name, esc_name, sizeof(esc_name));
    json_escape_str(file, esc_file, sizeof(esc_file));
    json_escape_str(kind, esc_kind, sizeof(esc_kind));
    json_escape_str(signature, esc_sig, sizeof(esc_sig));
    json_escape_str(content, esc_content, sizeof(esc_content));
    json_escape_str(docstring, esc_doc, sizeof(esc_doc));

    fprintf(fp, "{\"name\":\"%s\",\"file\":\"%s\",\"kind\":\"%s\","
            "\"line_start\":%d,\"line_end\":%d,\"language\":\"%s\","
            "\"signature\":\"%s\",\"content\":\"%s\",\"docstring\":\"%s\"}\n",
            esc_name, esc_file, esc_kind, line_start, line_end, lang, esc_sig, esc_content, esc_doc);

    // Write content as plain text (one line per chunk, for vector generation)
    if (text_fp) {
        // Replace newlines with spaces for single-line format
        for (const char* p = content; *p; p++) {
            fputc((*p == '\n' || *p == '\r') ? ' ' : *p, text_fp);
        }
        fputc('\n', text_fp);
    }

    // Write metadata (for search)
    if (meta_fp) {
        fprintf(meta_fp, "{\"name\":\"%s\",\"file\":\"%s\",\"kind\":\"%s\","
                "\"line_start\":%d,\"line_end\":%d,\"language\":\"%s\","
                "\"signature\":\"%s\",\"content\":\"%s\",\"docstring\":\"%s\"}\n",
                esc_name, esc_file, esc_kind, line_start, line_end, lang, esc_sig, esc_content, esc_doc);
    }
}

static int worker_process(worker_t* worker, int worker_id) {
    printf("[Worker %d] Processing %d files...\n", worker_id, worker->file_count);

    char chunk_file[256];
    lite_cs_tmp(chunk_file, sizeof(chunk_file), "chunks", worker_id, 0);
    unlink(chunk_file);
    FILE* chunk_fp = fopen(chunk_file, "w");
    if (!chunk_fp) {
        fprintf(stderr, "[Worker %d] Failed to create chunk file: %s\n", worker_id, strerror(errno));
        return 1;
    }

    char text_file[256];
    lite_cs_tmp(text_file, sizeof(text_file), "text", worker_id, 0);
    unlink(text_file);
    FILE* text_fp = fopen(text_file, "w");

    char meta_file[256];
    lite_cs_tmp(meta_file, sizeof(meta_file), "meta", worker_id, 0);
    unlink(meta_file);
    FILE* meta_fp = fopen(meta_file, "w");

    char plugin_raw_file[256];
    lite_cs_tmp(plugin_raw_file, sizeof(plugin_raw_file), "plugin_raw", worker_id, 0);
    unlink(plugin_raw_file);
    FILE* plugin_raw_fp = NULL;
    if (g_plugin_count > 0) {
        plugin_raw_fp = fopen(plugin_raw_file, "w");
    }

    int chunk_count = 0;
    int plugin_chunk_count = 0;
    int ctags_chunk_count = 0;

    // Separate files by plugin vs ctags
    char** plugin_files = NULL;
    int plugin_file_count = 0;
    int plugin_capacity = 0;
    char** ctags_files = NULL;
    int ctags_file_count = 0;
    int ctags_capacity = 0;

    for (int i = 0; i < worker->file_count; i++) {
        const char* path = worker->files[i];
        plugin_t* pl = find_plugin_for_file(path);
        if (pl) {
            if (plugin_file_count >= plugin_capacity) {
                int new_cap = plugin_capacity == 0 ? 256 : plugin_capacity * 2;
                char** new_arr = realloc(plugin_files, new_cap * sizeof(char*));
                if (!new_arr) continue;
                plugin_files = new_arr;
                plugin_capacity = new_cap;
            }
            plugin_files[plugin_file_count++] = (char*)path;
        } else {
            if (ctags_file_count >= ctags_capacity) {
                int new_cap = ctags_capacity == 0 ? 256 : ctags_capacity * 2;
                char** new_arr = realloc(ctags_files, new_cap * sizeof(char*));
                if (!new_arr) continue;
                ctags_files = new_arr;
                ctags_capacity = new_cap;
            }
            ctags_files[ctags_file_count++] = (char*)path;
        }
    }

    // Process plugin files one by one (plugins already handle per-file parsing)
    for (int i = 0; i < plugin_file_count; i++) {
        const char* filepath = plugin_files[i];
        plugin_t* pl = find_plugin_for_file(filepath);
        if (!pl) continue;

        char plugin_out[256];
        lite_cs_tmp(plugin_out, sizeof(plugin_out), "plugin", worker_id, i);
        unlink(plugin_out);

        int ret = run_plugin(pl, worker->repo_path, filepath, plugin_out);
        if (ret != 0) {
            fprintf(stderr, "[Worker %d] Plugin %s failed for %s: %d\n", worker_id, pl->name, filepath, ret);
            unlink(plugin_out);
            continue;
        }

        FILE* plugin_fp = fopen(plugin_out, "r");
        if (!plugin_fp) {
            unlink(plugin_out);
            continue;
        }

        char line[131072];
        while (fgets(line, sizeof(line), plugin_fp)) {
            char type[32] = {0};
            json_extract_str(line, "type", type, sizeof(type));
            if (strcmp(type, "chunk") != 0) {
                if (plugin_raw_fp) fputs(line, plugin_raw_fp);
                continue;
            }

            char name[256] = {0};
            char file_path[512] = {0};
            char kind[64] = {0};
            char signature[4096] = {0};
            char content[65536] = {0};
            int line_start = json_extract_int(line, "line_start");
            int line_end = json_extract_int(line, "line_end");

            json_extract_str(line, "name", name, sizeof(name));
            json_extract_str(line, "file", file_path, sizeof(file_path));
            json_extract_str(line, "kind", kind, sizeof(kind));
            json_extract_str(line, "signature", signature, sizeof(signature));
            json_extract_str(line, "content", content, sizeof(content));

            if (!name[0] || !file_path[0] || !line_start) continue;

            const char* lang = detect_language(file_path);
            if (line_end <= line_start) line_end = line_start;

            write_chunk(chunk_fp, text_fp, meta_fp, name, file_path, kind,
                        line_start, line_end, lang, signature, content, "");
            plugin_chunk_count++;
        }
        fclose(plugin_fp);
        unlink(plugin_out);
    }

    if (plugin_raw_fp) fclose(plugin_raw_fp);
    chunk_count += plugin_chunk_count;

    // Process remaining files with ctags
    if (ctags_file_count > 0) {
        char file_list[256];
        lite_cs_tmp(file_list, sizeof(file_list), "files", worker_id, 0);
        unlink(file_list);
        FILE* list_fp = fopen(file_list, "w");
        if (!list_fp) {
            fprintf(stderr, "[Worker %d] Failed to create file list\n", worker_id);
            fclose(chunk_fp);
            if (text_fp) fclose(text_fp);
            if (meta_fp) fclose(meta_fp);
            free(plugin_files);
            free(ctags_files);
            return 1;
        }
        for (int i = 0; i < ctags_file_count; i++) {
            fprintf(list_fp, "%s\n", ctags_files[i]);
        }
        fclose(list_fp);

        char output_file[256];
        lite_cs_tmp(output_file, sizeof(output_file), "worker", worker_id, 0);

        char cmd[1024];
        snprintf(cmd, sizeof(cmd),
            "ctags-universal --output-format=json --fields=+nKzSe "
            "--extras=+r+f --sort=no -L %s > %s 2>/dev/null",
            file_list, output_file);
        unlink(output_file);

        int ret = system(cmd);
        unlink(file_list);

        if (ret != 0) {
            fprintf(stderr, "[Worker %d] ctags failed: %d\n", worker_id, ret);
        } else {
            FILE* ctags_fp = fopen(output_file, "r");
            if (ctags_fp) {
                char line[131072];
                char fullpath[2048];
                char content[32768];

                FILE* current_fp = NULL;
                char current_file[512] = {0};
                char* file_buffer = NULL;
                size_t file_buffer_size = 0;
                char** file_lines = NULL;
                int file_line_count = 0;

                while (fgets(line, sizeof(line), ctags_fp)) {
                    char name[256] = {0};
                    char filepath[512] = {0};
                    char kind[64] = {0};
                    char signature[2048] = {0};

                    char type_check[32] = {0};
                    json_extract_str(line, "_type", type_check, sizeof(type_check));
                    if (strcmp(type_check, "tag") != 0) continue;

                    json_extract_str(line, "name", name, sizeof(name));

                    char scope[256] = {0};
                    json_extract_str(line, "scope", scope, sizeof(scope));
                    if (scope[0]) {
                        char scoped_name[512];
                        snprintf(scoped_name, sizeof(scoped_name), "%s::%s", scope, name);
                        strncpy(name, scoped_name, sizeof(name) - 1);
                        name[sizeof(name) - 1] = '\0';
                    }

                    json_extract_str(line, "path", filepath, sizeof(filepath));
                    json_extract_str(line, "kind", kind, sizeof(kind));
                    json_extract_str(line, "signature", signature, sizeof(signature));
                    int line_num = json_extract_int(line, "line");
                    int end_line = json_extract_int(line, "end");

                    if (!name[0] || !filepath[0] || !line_num) continue;
                    if (kind_is_skipped(kind)) continue;
                    // ctags 的 Lua parser 会把字符串里的 "function" 当定义：`type = "function",`
                    // 会产出名为 type/fn/~ 的垃圾 tag（lite 自己就有 199 个）。只认裸 function。
                    if (path_has_ext(filepath, ".lua") && !lua_tag_is_definition(line)) continue;

                    if (filepath[0] == '/') {
                        strncpy(fullpath, filepath, sizeof(fullpath) - 1);
                        fullpath[sizeof(fullpath) - 1] = '\0';
                    } else {
                        snprintf(fullpath, sizeof(fullpath), "%s/%s", worker->repo_path, filepath);
                    }
                    const char* lang = detect_language(filepath);
                    int is_lua = path_has_ext(fullpath, ".lua");

                    content[0] = '\0';

                    if (needs_range(kind)) {
                        if (end_line <= line_num) {
                            if (current_fp) { fclose(current_fp); current_fp = NULL; current_file[0] = '\0'; }
                            // 不要在这里 free file_buffer/file_lines：它们是本文件的缓存，
                            // current_file 仍指向同一文件，下一次不会重读 → 指针变空，
                            // 该文件后续所有 tag 的 content 都会是空的（Lua 无 `end` 字段，
                            // 每个 tag 都会走到这里，整份文件除第一个函数外全空）。
                            if (is_lua)
                                end_line = find_end_line_lua(fullpath, line_num);
                            else
                                end_line = find_end_line(fullpath, line_num);
                            if (end_line == 0) end_line = line_num;
                        }
                        // Lua 单行定义（`function M.x() end` / `M.sync = function() end`）
                        // end_line == line_num，仍要把这一行当 content，否则检索看不见它。
                        if (end_line > line_num || (is_lua && end_line == line_num)) {
                            if (strcmp(filepath, current_file) != 0) {
                                if (current_fp) { fclose(current_fp); current_fp = NULL; }
                                if (file_buffer) { free(file_buffer); file_buffer = NULL; }
                                if (file_lines) { free(file_lines); file_lines = NULL; }
                                file_line_count = 0;

                                strncpy(current_file, filepath, sizeof(current_file) - 1);
                                current_file[sizeof(current_file) - 1] = '\0';

                                struct stat st;
                                if (stat(fullpath, &st) == 0 && st.st_size > 0 && st.st_size < 2*1024*1024) {
                                    FILE* fp = fopen(fullpath, "r");
                                    if (fp) {
                                        file_buffer = malloc(st.st_size + 1);
                                        if (file_buffer) {
                                            size_t n = fread(file_buffer, 1, st.st_size, fp);
                                            file_buffer[n] = '\0';
                                            file_buffer_size = n;

                                            int count = 1;
                                            for (size_t i = 0; i < n; i++) {
                                                if (file_buffer[i] == '\n') count++;
                                            }
                                            file_lines = malloc(count * sizeof(char*));
                                            if (file_lines) {
                                                file_lines[0] = file_buffer;
                                                int idx = 1;
                                                for (size_t i = 0; i < n && idx < count; i++) {
                                                    if (file_buffer[i] == '\n') {
                                                        file_buffer[i] = '\0';
                                                        file_lines[idx] = file_buffer + i + 1;
                                                        idx++;
                                                    }
                                                }
                                                file_line_count = count;
                                            }
                                        }
                                        fclose(fp);
                                    }
                                } else {
                                    current_fp = fopen(fullpath, "r");
                                }
                            }

                            if (file_lines && line_num <= file_line_count) {
                                int cstart = decl_start(file_lines, file_line_count, line_num);
                                if (cstart < line_num) {   // 把返回类型/限定符补进 signature
                                    char pre[1024] = {0};
                                    for (int l = cstart; l < line_num; l++) {
                                        if (strlen(pre) + strlen(file_lines[l-1]) + 2 < sizeof(pre)) {
                                            strcat(pre, file_lines[l-1]);
                                            strcat(pre, " ");
                                        }
                                    }
                                    char ns[2048];
                                    snprintf(ns, sizeof(ns), "%s%s%s", pre, name, signature);
                                    strncpy(signature, ns, sizeof(signature) - 1);
                                    signature[sizeof(signature) - 1] = '\0';
                                }
                                int pos = 0;
                                for (int l = cstart; l <= end_line && l <= file_line_count; l++) {
                                    int len = strlen(file_lines[l-1]);
                                    if (pos + len < sizeof(content) - 2) {
                                        memcpy(content + pos, file_lines[l-1], len);
                                        pos += len;
                                        content[pos++] = '\n';
                                    }
                                }
                                if (pos > 0) content[pos] = '\0';
                            } else if (current_fp) {
                                extract_content_fp(current_fp, line_num, end_line, content, sizeof(content));
                            }
                        }
                    } else {
                        end_line = line_num;
                    }

                    // 宏/typedef/struct/union/enum：读【完整定义】
                    if (content[0] == '\0' &&
                        (strcmp(kind, "macro") == 0 || strcmp(kind, "typedef") == 0 ||
                         strcmp(kind, "enum") == 0 || strcmp(kind, "struct") == 0 ||
                         strcmp(kind, "union") == 0 || strcmp(kind, "enumerator") == 0)) {
                        FILE* lf = fopen(fullpath, "r");
                        if (lf) {
                            if (strcmp(kind, "macro") == 0 || strcmp(kind, "enumerator") == 0) {
                                // 单行（#define 以 '\' 续行则拼接）
                                char ln[8192];
                                int cur = 1;
                                while (fgets(ln, sizeof(ln), lf)) {
                                    if (cur == line_num) {
                                        size_t ll = strlen(ln);
                                        while (ll < sizeof(ln) && ll >= 2 && ln[ll - 2] == '\\' &&
                                               fgets(ln + strlen(ln), sizeof(ln) - strlen(ln), lf)) {
                                            ll = strlen(ln);
                                        }
                                        strncpy(content, ln, sizeof(content) - 1);
                                        content[sizeof(content) - 1] = '\0';
                                        break;
                                    }
                                    cur++;
                                }
                            } else {
                                // typedef/struct/union/enum：回退到声明起点(typedef/struct/{…)，前进到 ';'，取完整定义
                                rewind(lf);
                                char** lines = malloc(60000 * sizeof(char*));
                                int nl = 0;
                                char lb[8192];
                                while (nl < 60000 && fgets(lb, sizeof(lb), lf)) {
                                    lines[nl++] = strdup(lb);
                                }
                                if (line_num >= 1 && line_num <= nl) {
                                    int sidx = line_num - 1;
                                    int st = sidx;
                                    while (st > 0 && (sidx - st) <= 500) {
                                        char* L = lines[st];
                                        if (strstr(L, "typedef") || strstr(L, "struct") ||
                                            strstr(L, "union") || strstr(L, "enum") || strchr(L, '{'))
                                            break;
                                        st--;
                                    }
                                    int en = sidx;
                                    while (en < nl && !strchr(lines[en], ';')) en++;
                                    if (en >= nl) en = sidx;
                                    size_t pos = 0;
                                    for (int l = st; l <= en && pos < sizeof(content) - 2; l++) {
                                        size_t len = strlen(lines[l]);
                                        if (pos + len >= sizeof(content) - 1) break;
                                        memcpy(content + pos, lines[l], len);
                                        pos += len;
                                    }
                                    content[pos] = '\0';
                                }
                                for (int i = 0; i < nl; i++) free(lines[i]);
                                free(lines);
                            }
                            fclose(lf);
                        }
                    }

                    if (!content[0] && signature[0]) {
                        snprintf(content, sizeof(content), "%s %s;", name, signature);
                    }

                    if (strlen(content) > 16000) {
                        content[utf8_floor(content, 16000)] = '\0';
                        char* last_nl = strrchr(content, '\n');
                        if (last_nl) *(last_nl + 1) = '\0';
                    }

                    if (strcmp(kind, "member") == 0 || strcmp(kind, "field") == 0 ||
                        strcmp(kind, "variable") == 0 ||
                        strcmp(kind, "local") == 0 || strcmp(kind, "parameter") == 0) {
                        continue;
                    }
                    // 注意：macro 不再跳过 —— 宏/头文件内联是"构件"，语料需要它们

                    int content_len = strlen(content);
                    if (content_len > 2000) {
                        int window_size = 1500;
                        int overlap = 500;
                        int offset = 0;
                        int part = 0;

                        while (offset < content_len) {
                            if (part == 0) {
                                // 首个 chunk = 完整函数（供语料生成/检索；向量端自行截断），无 Part 标记
                                write_chunk(chunk_fp, text_fp, meta_fp, name, filepath, kind,
                                            line_num, end_line, lang, signature, content, "");
                                ctags_chunk_count++;
                                offset += (window_size > overlap) ? (window_size - overlap) : window_size;
                                offset = utf8_floor(content, offset);
                                part++;
                                if (part >= 5) break;
                                continue;
                            }
                            char chunk_content[4096];
                            int remaining = content_len - offset;
                            int take = (remaining > window_size) ? window_size : remaining;
                            // 不把多字节 UTF-8 字符从中间截断（否则留下非法 UTF-8）
                            if (offset + take < content_len) {
                                take = utf8_floor_len(content, offset, take);
                            }

                            if (signature[0]) {
                                snprintf(chunk_content, sizeof(chunk_content), "%s // Part %d\n",
                                         signature, part + 1);
                            } else {
                                snprintf(chunk_content, sizeof(chunk_content), "%s // Part %d\n",
                                         name, part + 1);
                            }

                            int prefix_len = strlen(chunk_content);
                            int max_content = sizeof(chunk_content) - prefix_len - 1;
                            if (take > max_content) take = max_content;

                            memcpy(chunk_content + prefix_len, content + offset, take);
                            chunk_content[prefix_len + take] = '\0';

                            if (offset + take < content_len) {
                                char* last_nl = strrchr(chunk_content, '\n');
                                if (last_nl) {
                                    *(last_nl + 1) = '\0';
                                    take = (last_nl - chunk_content) - prefix_len + 1;
                                }
                            }

                            write_chunk(chunk_fp, text_fp, meta_fp, name, filepath, kind,
                                        line_num, end_line, lang, signature, chunk_content, "");
                            ctags_chunk_count++;

                            offset += (take > overlap) ? (take - overlap) : take;
                            offset = utf8_floor(content, offset);
                            part++;

                            if (part >= 5) break;
                        }
                    } else {
                        write_chunk(chunk_fp, text_fp, meta_fp, name, filepath, kind, line_num, end_line,
                                    lang, signature, content, "");
                        ctags_chunk_count++;
                    }
                }

                if (current_fp) fclose(current_fp);
                if (file_buffer) free(file_buffer);
                if (file_lines) free(file_lines);
                fclose(ctags_fp);
                unlink(output_file);
            } else {
                fprintf(stderr, "[Worker %d] Failed to open ctags output\n", worker_id);
            }
        }
    }

    chunk_count += ctags_chunk_count;

    fclose(chunk_fp);
    if (text_fp) fclose(text_fp);
    if (meta_fp) fclose(meta_fp);

    free(plugin_files);
    free(ctags_files);

    printf("[Worker %d] Done: %d chunks (%d plugin, %d ctags) -> %s\n",
           worker_id, chunk_count, plugin_chunk_count, ctags_chunk_count, chunk_file);
    return 0;
}

int lite_cs_index_main(int argc, char** argv) {
    if (g_tmp_pid == 0) g_tmp_pid = (int)getpid();
    if (argc < 2) {
        printf("High-performance code indexer (C + multiprocess + plugins)\n");
        printf("Usage: %s <repo_path> [cache_dir] [num_workers] [options]\n", argv[0]);
        printf("\nOptions:\n");
        printf("  --exclude-dir dir1,dir2,...  Directories to skip\n");
        printf("  --plugins path/to/plugin.json  Plugin registry JSON\n");
        printf("  --skip-kinds header,file,macro  Skip selected ctags kinds\n");
        printf("  --include-dirs tools,utils     Re-include dirs from default noise list\n");
        printf("\nExample:\n");
        printf("  %s /opt/linux /memory 8\n", argv[0]);
        printf("  %s /opt/opencode /memory 8 --plugins third_party/codesearch/plugins/typescript-indexer/plugin.json\n", argv[0]);
        return 1;
    }
    
    const char* repo_path = argv[1];
    const char* cache_dir = "/memory";
    int num_workers = sysconf(_SC_NPROCESSORS_ONLN);
    int fork_opt = -1;
    
    // Parse optional args
    int arg_pos = 2;
    while (arg_pos < argc) {
        if (strcmp(argv[arg_pos], "--exclude-dir") == 0 && arg_pos + 1 < argc) {
            static const char* exclude_list[64];
            int count = 0;
            arg_pos++;
            char* token = strtok(argv[arg_pos], ",");
            while (token && count < 64) {
                exclude_list[count++] = token;
                token = strtok(NULL, ",");
            }
            g_exclude_dirs = exclude_list;
            g_exclude_count = count;
            arg_pos++;
        } else if (strcmp(argv[arg_pos], "--plugins") == 0 && arg_pos + 1 < argc) {
            arg_pos++;
            strncpy(g_plugin_registry, argv[arg_pos], sizeof(g_plugin_registry) - 1);
            g_plugin_registry[sizeof(g_plugin_registry) - 1] = '\0';
            arg_pos++;
        } else if (strcmp(argv[arg_pos], "--skip-kinds") == 0 && arg_pos + 1 < argc) {
            arg_pos++;
            strncpy(g_skip_kinds, argv[arg_pos], sizeof(g_skip_kinds) - 1);
            g_skip_kinds[sizeof(g_skip_kinds) - 1] = '\0';
            arg_pos++;
        } else if (strcmp(argv[arg_pos], "--include-dirs") == 0 && arg_pos + 1 < argc) {
            arg_pos++;
            strncpy(g_include_dirs, argv[arg_pos], sizeof(g_include_dirs) - 1);
            g_include_dirs[sizeof(g_include_dirs) - 1] = '\0';
            arg_pos++;
        } else if (strcmp(argv[arg_pos], "--fork") == 0) {
            fork_opt = 1;
            arg_pos++;
        } else if (strcmp(argv[arg_pos], "--no-fork") == 0) {
            fork_opt = 0;
            arg_pos++;
        } else if (arg_pos + 1 < argc && argv[arg_pos+1][0] != '-') {
            cache_dir = argv[arg_pos];
            num_workers = atoi(argv[++arg_pos]);
            arg_pos++;
        } else {
            cache_dir = argv[arg_pos];
            arg_pos++;
        }
    }
    if (num_workers <= 0) num_workers = 4;

    // Load plugin registry if provided
    if (g_plugin_registry[0]) {
        int n = load_plugin_registry(g_plugin_registry);
        if (n > 0) {
            printf("Loaded %d plugin(s) from %s\n", n, g_plugin_registry);
        } else {
            fprintf(stderr, "[WARN] Failed to load plugin registry: %s\n", g_plugin_registry);
        }
    }
    
    // Add excluded dirs to noise list
    if (g_exclude_count > 0) {
        printf("  Excluding dirs: ");
        for (int i = 0; i < g_exclude_count; i++) {
            printf("%s ", g_exclude_dirs[i]);
        }
        printf("\n");
    }
    
    printf("Code Indexer v1.0\n");
    printf("==================\n");
    printf("Repo: %s\n", repo_path);
    printf("Cache: %s\n", cache_dir);
    printf("Workers: %d\n\n", num_workers);

    struct stat st;
    if (stat(repo_path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "Error: %s is not a directory\n", repo_path);
        return 1;
    }

    // Create cache directory if it doesn't exist
    if (stat(cache_dir, &st) != 0) {
        if (mkdir(cache_dir, 0755) != 0) {
            fprintf(stderr, "Error: Failed to create cache directory %s\n", cache_dir);
            return 1;
        }
    }
    
    printf("Phase 1: Scanning source files...\n");
    source_file_t* files = NULL;
    int file_count = 0;
    int file_capacity = 10000;
    
    files = malloc(file_capacity * sizeof(source_file_t));
    if (!files) {
        fprintf(stderr, "Failed to allocate file list\n");
        return 1;
    }
    
    scan_directory(repo_path, repo_path, &files, &file_count, &file_capacity);
    printf("  Found %d source files\n\n", file_count);
    
    if (file_count == 0) {
        printf("No source files found.\n");
        free(files);
        return 0;
    }
    
    printf("Phase 2: Forking %d workers...\n", num_workers);
    
    worker_t* workers = calloc(num_workers, sizeof(worker_t));
    pid_t* pids = calloc(num_workers, sizeof(pid_t));
    
    for (int i = 0; i < num_workers; i++) {
        workers[i].repo_path = repo_path;
    }
    
    for (int i = 0; i < file_count; i++) {
        int wid = i % num_workers;
        worker_t* w = &workers[wid];
        
        if (w->file_count >= w->capacity) {
            int new_cap = w->capacity == 0 ? 1000 : w->capacity * 2;
            char** new_files = realloc(w->files, new_cap * sizeof(char*));
            if (!new_files) continue;
            w->files = new_files;
            w->capacity = new_cap;
        }
        
        w->files[w->file_count] = strdup(files[i].path);
        w->file_count++;
    }
    
    for (int i = 0; i < num_workers; i++) {
        printf("  Worker %d: %d files\n", i, workers[i].file_count);
    }
    printf("\n");
    
    struct timespec start_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);
    
    int completed = 0;
    int failed_workers[64];
    int failed_count = 0;

    // 作为库被 lite 调用时默认不 fork：宿主进程可能已启动 LuaJIT/ORT 线程，
    // fork 只继承了调用线程，容易在子进程里死锁。需要并行时显式 LITE_CS_FORK=1。
    const char* fork_env = getenv("LITE_CS_FORK");
    int do_fork = (fork_opt == 1) || (fork_opt < 0 && fork_env && fork_env[0] == '1');

    if (do_fork) {
        for (int i = 0; i < num_workers; i++) {
            if (workers[i].file_count == 0) continue;

            fflush(stdout);
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork");
                continue;
            } else if (pid == 0) {
                int ret = worker_process(&workers[i], i);
                exit(ret);
            } else {
                pids[i] = pid;
            }
        }

        printf("Phase 3: Waiting for workers...\n");
        for (int i = 0; i < num_workers; i++) {
            if (pids[i] > 0) {
                int status;
                waitpid(pids[i], &status, 0);
                if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                    completed++;
                } else {
                    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
                    fprintf(stderr, "[ERROR] Worker %d failed (exit code %d, %d files)\n",
                            i, code, workers[i].file_count);
                    if (failed_count < 64) failed_workers[failed_count++] = i;
                }
            }
        }
    } else {
        printf("Phase 3: Running workers in-process (serial)...\n");
        for (int i = 0; i < num_workers; i++) {
            if (workers[i].file_count == 0) continue;
            int ret = worker_process(&workers[i], i);
            if (ret == 0) {
                completed++;
            } else {
                fprintf(stderr, "[ERROR] Worker %d failed (exit code %d, %d files)\n",
                        i, ret, workers[i].file_count);
                if (failed_count < 64) failed_workers[failed_count++] = i;
            }
        }
    }
    printf("  %d/%d workers completed", completed, num_workers);
    if (failed_count > 0) {
        printf(" [WARNING: %d worker(s) failed!]", failed_count);
        printf("\n  Failed workers: ");
        for (int f = 0; f < failed_count; f++) {
            printf("%d", failed_workers[f]);
            if (f < failed_count - 1) printf(", ");
        }
        printf("\n  Check stderr output above for details.\n");
    } else {
        printf("\n");
    }
    
    struct timespec end_time;
    clock_gettime(CLOCK_MONOTONIC, &end_time);
    double elapsed = (end_time.tv_sec - start_time.tv_sec) + 
                     (end_time.tv_nsec - start_time.tv_nsec) / 1e9;
    
    printf("Phase 4: Merging output files...\n");

    // Merge text files
    char text_out[512];
    snprintf(text_out, sizeof(text_out), "%s/chunks_text.txt", cache_dir);
    FILE* text_out_fp = fopen(text_out, "w");

    // Merge meta files
    char meta_out[512];
    snprintf(meta_out, sizeof(meta_out), "%s/chunks_meta.jsonl", cache_dir);
    FILE* meta_out_fp = fopen(meta_out, "w");

    // Merge plugin raw output (call_edge, import_edge, metadata)
    char plugin_raw_out[512];
    snprintf(plugin_raw_out, sizeof(plugin_raw_out), "%s/plugin_output.jsonl", cache_dir);
    FILE* plugin_raw_out_fp = NULL;
    if (g_plugin_count > 0) {
        plugin_raw_out_fp = fopen(plugin_raw_out, "w");
    }

    int total_chunks = 0;
    int total_plugin_lines = 0;

    for (int i = 0; i < num_workers; i++) {
        char text_file[256], meta_file[256];
        lite_cs_tmp(text_file, sizeof(text_file), "text", i, 0);
        lite_cs_tmp(meta_file, sizeof(meta_file), "meta", i, 0);

        // Copy text file
        FILE* fp = fopen(text_file, "r");
        if (fp) {
            char buf[65536];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
                fwrite(buf, 1, n, text_out_fp);
            }
            fclose(fp);
            unlink(text_file);
        }

        // Copy meta file
        fp = fopen(meta_file, "r");
        if (fp) {
            char buf[65536];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
                fwrite(buf, 1, n, meta_out_fp);
            }
            fclose(fp);
            unlink(meta_file);
        }

        // Merge plugin raw output
        if (plugin_raw_out_fp) {
            char plugin_raw_file[256];
            lite_cs_tmp(plugin_raw_file, sizeof(plugin_raw_file), "plugin_raw", i, 0);
            fp = fopen(plugin_raw_file, "r");
            if (fp) {
                char line[131072];
                while (fgets(line, sizeof(line), fp)) {
                    fputs(line, plugin_raw_out_fp);
                    total_plugin_lines++;
                }
                fclose(fp);
                unlink(plugin_raw_file);
            }
        }

        // Count chunks from chunk file
        char chunk_file[256];
        lite_cs_tmp(chunk_file, sizeof(chunk_file), "chunks", i, 0);
        fp = fopen(chunk_file, "r");
        if (fp) {
            char line[131072];
            while (fgets(line, sizeof(line), fp)) {
                total_chunks++;
            }
            fclose(fp);
            // Keep chunk file for now (may be useful for debugging)
        }
    }

    if (text_out_fp) fclose(text_out_fp);
    if (meta_out_fp) fclose(meta_out_fp);
    if (plugin_raw_out_fp) {
        fclose(plugin_raw_out_fp);
        printf("  Plugin output: %s (%d records)\n", plugin_raw_out, total_plugin_lines);
    }
    
    printf("\n========================================\n");
    printf("Indexing complete!\n");
    printf("  Files: %d\n", file_count);
    printf("  Chunks: %d\n", total_chunks);
    printf("  Plugins: %d\n", g_plugin_count);
    for (int i = 0; i < g_plugin_count; i++) {
        printf("    - %s (%s)\n", g_plugins[i].name, g_plugins[i].command);
    }
    printf("  Workers: %d\n", num_workers);
    printf("  Time: %.1fs\n", elapsed);
    printf("  Throughput: %.0f files/s\n", file_count / elapsed);
    printf("  Output: %s/chunks_text.txt, %s/chunks_meta.jsonl", cache_dir, cache_dir);
    if (g_plugin_count > 0) printf(", %s/plugin_output.jsonl", cache_dir);
    printf("\n");
    printf("========================================\n");
    
    for (int i = 0; i < file_count; i++) free(files[i].path);
    free(files);
    for (int i = 0; i < num_workers; i++) {
        for (int j = 0; j < workers[i].file_count; j++) free(workers[i].files[j]);
        free(workers[i].files);
    }
    free(workers);
    free(pids);
    
    return 0;
}
