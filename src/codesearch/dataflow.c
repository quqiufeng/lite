#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <jansson.h>
#include "cs_compat.h"

#define MAX_LINE 131072
#define MAX_VARS 2000000  /* 动态分配；上限覆盖 Linux 内核（旧值 10000 只覆盖前 1 万变量） */
#define MAX_OCCURS 2000  /* 200→2000: 高频变量（i/ret 等）不再过早截断；occurs 动态分配 */
#define MAX_FIELDS 50
#define MAX_FUNCS 5000

// 前向声明（is_c_type 定义在后面）
static int is_c_type(const char* word);

// C 控制关键字/字面量：不能作为变量名收集（否则 dataflow.json 出现 "void"/"return" 等噪声键）
static int is_c_keyword(const char* word) {
    static const char* kw[] = {
        "return", "if", "else", "for", "while", "do", "switch", "case",
        "break", "continue", "goto", "sizeof", "typedef", "register",
        "volatile", "extern", "inline", "restrict", "_Bool",
        "true", "false", "NULL", "nullptr", "this",
        NULL
    };
    for (int i = 0; kw[i]; i++) {
        if (strcmp(word, kw[i]) == 0) return 1;
    }
    return 0;
}

// ============================================
// 基础数据结构
// ============================================

// 变量出现记录（增强版：支持字段）
typedef struct {
    char file[512];
    char func[256];
    int line;
    int col;
    char context[256];
    int is_definition;  // 1=定义, 2=赋值, 3=使用
    char field_name[128];  // "" 表示无字段访问，否则为字段名
} occurrence_t;

// 字段访问记录
typedef struct {
    char field_name[128];
    occurrence_t* occurs;
    int occur_count;
    int capacity;
} field_record_t;

// 变量记录（增强版：支持字段）
// occurs/fields 改为动态分配：旧版内联 occurs[MAX_OCCURS]（每变量 ~232KB），
// 导致 MAX_VARS 无法上调、内核只覆盖前 1 万变量。
typedef struct {
    char name[128];
    char type[128];
    occurrence_t* occurs;   // 动态，上限 MAX_OCCURS
    int occur_count;
    int occur_capacity;
    field_record_t* fields; // 动态，上限 MAX_FIELDS
    int field_count;
    int field_capacity;
} var_record_t;

static var_record_t* g_vars = NULL;
static int g_var_count = 0;
static int g_var_capacity = 0;

// 变量名哈希索引（开放寻址）：name → g_vars 下标+1，0 表示空。
// 修复 find_or_create_var 旧版线性扫描（变量一多即 O(n²)）。
#define VAR_HASH_INIT 65536
static int* g_var_hash = NULL;
static size_t g_var_hash_size = 0;
static size_t g_var_hash_used = 0;

static unsigned int var_hash(const char* s) {
    unsigned int h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h;
}

// ============================================
// 跨函数数据流
// ============================================

// 函数调用记录
typedef struct {
    char caller[256];
    char callee[256];
    char call_site_file[512];
    int call_site_line;
    char args[1024];  // 参数字符串，如 "c, pool, log"
} call_edge_t;

// 调用图
typedef struct {
    call_edge_t* edges;
    int edge_count;
    int capacity;
} call_graph_t;

static call_graph_t g_call_graph = {NULL, 0, 0};

// ============================================
// 变量管理
// ============================================

// 合法 C 标识符：首字符 alpha/underscore，其余 alnum/underscore。
// 同时挡掉非 ASCII 字节（避免 dataflow.json 出现非法 UTF-8 的变量名键）
static int is_identifier(const char* s) {
    if (!s || !(isalpha((unsigned char)s[0]) || s[0] == '_')) return 0;
    for (const char* p = s + 1; *p; p++) {
        if (!(isalnum((unsigned char)*p) || *p == '_')) return 0;
    }
    return 1;
}

static var_record_t* find_or_create_var(const char* name) {
    // 过滤 C 类型/关键字/非法标识符：避免 "void"（来自 "static void *fn"）、"return"、
    // 以及非 ASCII 字节（如 "\xb0"）进入变量表污染输出。
    if (!is_identifier(name) || is_c_type(name) || is_c_keyword(name)) return NULL;

    if (!g_var_hash) {
        g_var_hash_size = VAR_HASH_INIT;
        g_var_hash = calloc(g_var_hash_size, sizeof(int));
        if (!g_var_hash) return NULL;
    }

    // 哈希查找 O(1)
    unsigned int h = var_hash(name) & (unsigned int)(g_var_hash_size - 1);
    while (g_var_hash[h]) {
        int idx = g_var_hash[h] - 1;
        if (strcmp(g_vars[idx].name, name) == 0) return &g_vars[idx];
        h = (h + 1) & (unsigned int)(g_var_hash_size - 1);
    }

    if (g_var_count >= MAX_VARS) return NULL;

    // 动态扩容变量数组
    if (g_var_count >= g_var_capacity) {
        int newcap = g_var_capacity ? g_var_capacity * 2 : 4096;
        if (newcap > MAX_VARS) newcap = MAX_VARS;
        var_record_t* nv = realloc(g_vars, (size_t)newcap * sizeof(var_record_t));
        if (!nv) return NULL;
        g_vars = nv;
        g_var_capacity = newcap;
    }

    int idx = g_var_count++;
    var_record_t* var = &g_vars[idx];
    strncpy(var->name, name, sizeof(var->name) - 1);
    var->name[sizeof(var->name) - 1] = '\0';
    var->type[0] = '\0';
    var->occurs = NULL; var->occur_count = 0; var->occur_capacity = 0;
    var->fields = NULL; var->field_count = 0; var->field_capacity = 0;

    // 插入哈希
    g_var_hash[h] = idx + 1;
    g_var_hash_used++;

    // 负载因子 > 0.7 扩容哈希
    if (g_var_hash_used * 10 >= g_var_hash_size * 7) {
        size_t newsize = g_var_hash_size * 2;
        int* nh = calloc(newsize, sizeof(int));
        if (nh) {
            for (int i = 0; i < g_var_count; i++) {
                unsigned int hh = var_hash(g_vars[i].name) & (unsigned int)(newsize - 1);
                while (nh[hh]) hh = (hh + 1) & (unsigned int)(newsize - 1);
                nh[hh] = i + 1;
            }
            free(g_var_hash);
            g_var_hash = nh;
            g_var_hash_size = newsize;
        }
    }
    return var;
}

// 只查不建：赋值/使用不该凭空造变量（`a->field = 1` 会把 field 变成"变量"），
// 变量表只由声明行建立。
static var_record_t* find_var(const char* name) {
    if (!g_var_hash || !is_identifier(name)) return NULL;
    unsigned int h = var_hash(name) & (unsigned int)(g_var_hash_size - 1);
    while (g_var_hash[h]) {
        int idx = g_var_hash[h] - 1;
        if (strcmp(g_vars[idx].name, name) == 0) return &g_vars[idx];
        h = (h + 1) & (unsigned int)(g_var_hash_size - 1);
    }
    return NULL;
}

static field_record_t* find_or_create_field(var_record_t* var, const char* field_name) {
    for (int i = 0; i < var->field_count; i++) {
        if (strcmp(var->fields[i].field_name, field_name) == 0) 
            return &var->fields[i];
    }
    if (var->field_count >= MAX_FIELDS) return NULL;
    if (var->field_count >= var->field_capacity) {
        int newcap = var->field_capacity ? var->field_capacity * 2 : 4;
        if (newcap > MAX_FIELDS) newcap = MAX_FIELDS;
        field_record_t* nf = realloc(var->fields, (size_t)newcap * sizeof(field_record_t));
        if (!nf) return NULL;
        var->fields = nf;
        var->field_capacity = newcap;
    }
    field_record_t* field = &var->fields[var->field_count++];
    strncpy(field->field_name, field_name, sizeof(field->field_name) - 1);
    field->field_name[sizeof(field->field_name) - 1] = '\0';
    field->occurs = NULL;
    field->occur_count = 0;
    field->capacity = 0;
    return field;
}

static void add_field_occurrence(field_record_t* field, occurrence_t* occ) {
    if (!field) return;
    if (field->occur_count >= field->capacity) {
        field->capacity = field->capacity == 0 ? 10 : field->capacity * 2;
        field->occurs = realloc(field->occurs, field->capacity * sizeof(occurrence_t));
    }
    field->occurs[field->occur_count++] = *occ;
}

static void add_occurrence(var_record_t* var, const char* file, const char* func, 
                           int line, int col, const char* context, int is_def,
                           const char* field_name) {
    if (!var || var->occur_count >= MAX_OCCURS) return;
    if (var->occur_count >= var->occur_capacity) {
        int newcap = var->occur_capacity ? var->occur_capacity * 2 : 8;
        if (newcap > MAX_OCCURS) newcap = MAX_OCCURS;
        occurrence_t* no = realloc(var->occurs, (size_t)newcap * sizeof(occurrence_t));
        if (!no) return;
        var->occurs = no;
        var->occur_capacity = newcap;
    }
    occurrence_t* occ = &var->occurs[var->occur_count++];
    strncpy(occ->file, file, sizeof(occ->file) - 1);
    strncpy(occ->func, func, sizeof(occ->func) - 1);
    occ->line = line;
    occ->col = col;
    strncpy(occ->context, context, sizeof(occ->context) - 1);
    occ->is_definition = is_def;
    if (field_name) {
        strncpy(occ->field_name, field_name, sizeof(occ->field_name) - 1);
        field_record_t* field = find_or_create_field(var, field_name);
        if (field) add_field_occurrence(field, occ);
    } else {
        occ->field_name[0] = '\0';
    }
}

// ============================================
// 字段访问提取
// ============================================

static const char* extract_field_access(const char* line, const char* var_name) {
    static char field_name[128];
    field_name[0] = '\0';
    
    int var_len = (int)strlen(var_name);
    const char* p = line;
    
    while ((p = strstr(p, var_name)) != NULL) {
        if (p > line && (isalnum((unsigned char)*(p-1)) || *(p-1) == '_')) {
            p += var_len;
            continue;
        }
        
        const char* after = p + var_len;
        if (*after == '-' && *(after+1) == '>') {
            after += 2;
        } else if (*after == '.') {
            after += 1;
        } else {
            p += var_len;
            continue;
        }
        
        int i = 0;
        while (*after && (isalnum((unsigned char)*after) || *after == '_') && i < 127) {
            field_name[i++] = *after++;
        }
        field_name[i] = '\0';
        
        if (i > 0) return field_name;
        p += var_len;
    }
    
    return NULL;
}

// ============================================
// 词法分析
// ============================================

static int is_c_type(const char* word) {
    static const char* types[] = {
        "int", "char", "float", "double", "void", "auto", "static", "const",
        "struct", "union", "enum", "unsigned", "signed", "long", "short",
        "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "bool", "ggml_tensor",
        "ggml_context", "ngx_str_t", "ngx_int_t", "ngx_uint_t", "ngx_flag_t",
        "ngx_http_request_t", "ngx_connection_t", "ngx_cycle_t", "ngx_pool_t",
        "sd_image_t", "sd_ctx_t", "ggml_backend_t", "ggml_cgraph",
        NULL
    };
    for (int i = 0; types[i]; i++) {
        if (strcmp(word, types[i]) == 0) return 1;
    }
    return 0;
}

// 声明行的判定用的修饰词：它们是类型的一部分，不是变量名。
static int is_type_qualifier(const char* w) {
    static const char* q[] = {
        "const", "static", "inline", "volatile", "register", "extern",
        "struct", "union", "enum", "signed", "unsigned", NULL
    };
    for (int i = 0; q[i]; i++) if (strcmp(w, q[i]) == 0) return 1;
    return 0;
}

// "size_t"/"s64"/"ngx_str_t" 这类：既有白名单，也认 _t 后缀与 s/u + 位宽写法。
static int is_type_word(const char* w) {
    if (is_c_type(w) || is_type_qualifier(w)) return 1;
    size_t n = strlen(w);
    if (n > 2 && strcmp(w + n - 2, "_t") == 0) return 1;
    if (n >= 2 && n <= 3 && (w[0] == 's' || w[0] == 'u')) {
        int digits = 1;
        for (size_t i = 1; i < n; i++) if (!isdigit((unsigned char)w[i])) digits = 0;
        if (digits) return 1;   // s8 u8 s16 u32 s64 ...
    }
    return 0;
}

// 变量名后面必须紧跟这些 token 才算"声明"：`struct sds {` 里的 sds 因此不会被当变量。
static int is_decl_terminator(const char* t) {
    return strcmp(t, "=") == 0 || strcmp(t, ";") == 0 || strcmp(t, ",") == 0 ||
           strcmp(t, "[") == 0 || strcmp(t, ")") == 0 || strcmp(t, ":") == 0;
}

static void tokenize_line(const char* line, char tokens[][128], int* token_count, int max_tokens) {
    *token_count = 0;
    const char* p = line;
    while (*p && *token_count < max_tokens) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p) break;
        
        if (*p == '/' && *(p+1) == '/') break;
        
        if (isalpha((unsigned char)*p) || *p == '_') {
            int i = 0;
            while (*p && (isalnum((unsigned char)*p) || *p == '_') && i < 127) {
                tokens[*token_count][i++] = *p++;
            }
            tokens[*token_count][i] = '\0';
            (*token_count)++;
        }
        else if (isdigit((unsigned char)*p)) {
            int i = 0;
            while (*p && (isalnum((unsigned char)*p) || *p == '.') && i < 127) {
                tokens[*token_count][i++] = *p++;
            }
            tokens[*token_count][i] = '\0';
            (*token_count)++;
        }
        else if (*p == '"' || *p == '\'') {
            char quote = *p++;
            while (*p && *p != quote) p++;
            if (*p) p++;
        }
        else {
            int i = 0;
            tokens[*token_count][i++] = *p++;
            if (*p && ((*p == '=' && strchr("=+-*/%<>!|&", *(p-1))) ||
                        (*p == '+' && *(p-1) == '+') ||
                        (*p == '-' && *(p-1) == '-') ||
                        (*p == '>' && *(p-1) == '-') ||
                        (*p == '>' && *(p-1) == '>') ||
                        (*p == '<' && *(p-1) == '<'))) {
                tokens[*token_count][i++] = *p++;
            }
            tokens[*token_count][i] = '\0';
            (*token_count)++;
        }
    }
}

// ============================================
// 代码分析
// ============================================

typedef struct {
    char file[512];
    char func[256];
    int abs_line;
} ctx_info_t;

static void analyze_line_impl(const char* line, ctx_info_t* ctx) {
    char tokens[64][128];
    int token_count = 0;
    tokenize_line(line, tokens, &token_count, 64);
    
    for (int i = 0; i < token_count; i++) {
        // 1. 变量定义：类型词（含 struct/union 标签、xxx_t、s64 之类）→ 跳过修饰词与
        //    指针星号 → 变量名。变量名后必须紧跟 = ; , [ ) : 之一，否则不是声明
        //    （`struct sds {` 的 sds、`if (x == y)` 的 x 都不会被误收）。
        if (is_type_word(tokens[i])) {
            int j = i;
            while (j < token_count) {
                const char* t = tokens[j];
                if (strcmp(t, "struct") == 0 || strcmp(t, "union") == 0 ||
                    strcmp(t, "enum") == 0) {
                    j += 2;                       // 跳过标签名
                    continue;
                }
                if (is_type_word(t) || strcmp(t, "*") == 0) { j++; continue; }
                break;
            }
            if (j < token_count && (isalpha((unsigned char)tokens[j][0]) || tokens[j][0] == '_')) {
                int k = j + 1;
                while (k < token_count && strcmp(tokens[k], "*") == 0) k++;
                if (k < token_count && !is_decl_terminator(tokens[k])) continue;
                var_record_t* var = find_or_create_var(tokens[j]);
                if (var && var->occur_count == 0) {
                    // 类型取"变量名前面最后一个非 * token"：`const char *src` 记 char
                    // 而不是 const（旧版一律取第一个词）。
                    int ti = j - 1;
                    while (ti > i && strcmp(tokens[ti], "*") == 0) ti--;
                    if (ti < i) ti = i;
                    strncpy(var->type, tokens[ti], sizeof(var->type) - 1);
                    var->type[sizeof(var->type) - 1] = '\0';
                    add_occurrence(var, ctx->file, ctx->func, ctx->abs_line, 0, line, 1, NULL);
                }
            }
            continue;
        }

        // 2. 赋值：只更新已声明的变量（`ctx->field = 1` 里的 field 不是变量）
        if (strcmp(tokens[i], "=") == 0 && i > 0) {
            char* prev = tokens[i - 1];
            if (strcmp(prev, "+") != 0 && strcmp(prev, "-") != 0 &&
                strcmp(prev, "*") != 0 && strcmp(prev, "&") != 0) {
                var_record_t* var = find_var(prev);
                if (var) {
                    const char* field = extract_field_access(line, prev);
                    add_occurrence(var, ctx->file, ctx->func, ctx->abs_line, 0, line, 2, field);
                }
            }
        }

        // 3. 使用（含字段访问）
        if ((isalpha((unsigned char)tokens[i][0]) || tokens[i][0] == '_') &&
            !is_type_word(tokens[i])) {
            int is_lvalue = 0;
            if (i + 1 < token_count && strcmp(tokens[i + 1], "=") == 0) {
                is_lvalue = 1;
            }
            if (i + 1 < token_count && 
                (strcmp(tokens[i + 1], "++") == 0 || strcmp(tokens[i + 1], "--") == 0)) {
                is_lvalue = 1;
            }
            if (!is_lvalue) {
                var_record_t* var = find_var(tokens[i]);
                if (var && var->occur_count > 0) {
                    int dup = 0;
                    for (int j = 0; j < var->occur_count; j++) {
                        if (var->occurs[j].line == ctx->abs_line) { dup = 1; break; }
                    }
                    if (!dup) {
                        const char* field = extract_field_access(line, tokens[i]);
                        add_occurrence(var, ctx->file, ctx->func, ctx->abs_line, 0, line, 3, field);
                    }
                }
            }
        }
    }
}

// 去注释：//、/* */（跨行靠 in_block 传递），字符串字面量原样保留（tokenizer 会跳过，
// 但 "http://x" 不能被当成行注释开头）。
static void strip_comments_line(char* line, int* in_block) {
    char* out = line;
    const char* p = line;
    while (*p) {
        if (*in_block) {
            const char* e = strstr(p, "*/");
            if (!e) { *out = '\0'; return; }
            p = e + 2;
            *in_block = 0;
            continue;
        }
        if (p[0] == '/' && p[1] == '*') { *in_block = 1; p += 2; continue; }
        if (p[0] == '/' && p[1] == '/') break;
        if (*p == '"' || *p == '\'') {
            char q = *p;
            *out++ = *p++;
            while (*p && *p != q) {
                if (*p == '\\' && p[1]) *out++ = *p++;
                *out++ = *p++;
            }
            if (*p) *out++ = *p++;
            continue;
        }
        *out++ = *p++;
    }
    *out = '\0';
}

static void process_function_content(const char* content, ctx_info_t* ctx_base) {
    char line[1024];
    const char* p = content;
    int rel_line = 0;
    int in_block_comment = 0;

    while (*p) {
        int i = 0;
        while (*p && *p != '\n' && i < (int)(sizeof(line) - 1)) {
            line[i++] = *p++;
        }
        line[i] = '\0';
        if (*p == '\n') p++;
        rel_line++;

        strip_comments_line(line, &in_block_comment);

        ctx_info_t ctx = *ctx_base;
        ctx.abs_line = ctx_base->abs_line + rel_line - 1;
        analyze_line_impl(line, &ctx);
    }
}

// JSON 字符串反转义（content 里 \n \t \" \\ \/ \uXXXX）。\u 只保留 ASCII，
// 其余置 '?' —— dataflow 只做 C 词法，非 ASCII 字符不会成为变量名。
static int decode_json_string(const char* src, size_t raw_len, char* out, int cap) {
    int i = 0;
    size_t j = 0;
    while (j < raw_len && i < cap - 1) {
        if (src[j] != '\\') { out[i++] = src[j++]; continue; }
        j++;
        if (j >= raw_len) break;
        switch (src[j]) {
            case 'n': out[i++] = '\n'; j++; break;
            case 't': out[i++] = '\t'; j++; break;
            case 'r': out[i++] = '\r'; j++; break;
            case 'b': out[i++] = '\b'; j++; break;
            case 'f': out[i++] = '\f'; j++; break;
            case '/': out[i++] = '/'; j++; break;
            case '\\': out[i++] = '\\'; j++; break;
            case '"': out[i++] = '"'; j++; break;
            case 'u': {
                unsigned v = 0;
                size_t k = 1;
                for (; k <= 4 && j + k < raw_len; k++) {
                    char c = src[j + k];
                    v <<= 4;
                    if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
                    else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
                    else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
                }
                j += k;
                if (v > 0 && v < 128) out[i++] = (char)v;
                break;
            }
            default: out[i++] = src[j++]; break;
        }
    }
    out[i] = '\0';
    return i;
}

static int analyze_meta(const char* meta_file) {
    FILE* fp = fopen(meta_file, "r");
    if (!fp) {
        fprintf(stderr, "Failed to open %s\n", meta_file);
        return 1;
    }
    
    char* line = NULL;
    size_t line_len = 0;
    int func_count = 0;
    
    while (getline(&line, &line_len, fp) != -1) {
        char name[256] = {0}, file[512] = {0}, kind[32] = {0};
        char content[32768] = {0};
        int line_start = 0;
        
        char* name_p = strstr(line, "\"name\":\"");
        char* file_p = strstr(line, "\"file\":\"");
        char* kind_p = strstr(line, "\"kind\":\"");
        char* line_p = strstr(line, "\"line_start\":");
        char* content_p = strstr(line, "\"content\":\"");
        
        if (!name_p || !file_p || !kind_p || !content_p) continue;
        
        name_p += 8;
        file_p += 8;
        kind_p += 8;
        line_p += 13;
        content_p += 11;
        
        int i = 0;
        while (*name_p && *name_p != '"' && i < 255) name[i++] = *name_p++;
        
        i = 0;
        while (*file_p && *file_p != '"' && i < 511) file[i++] = *file_p++;
        
        i = 0;
        while (*kind_p && *kind_p != '"' && i < 31) kind[i++] = *kind_p++;
        line_start = atoi(line_p);
        
        if (strcmp(kind, "function") != 0 && strcmp(kind, "method") != 0 &&
            strcmp(kind, "ts_function") != 0 && strcmp(kind, "ts_method") != 0) continue;
        
        // content 是 JSON 字符串：必须先反转义再分析。旧版把 "\\n" 拷成字面 'n'，
        // 整个函数被压成一行 → 所有变量行号都落在签名行（B3 的主因）。
        const char* cp = content_p;
        size_t raw_len = 0;
        int escaped = 0;
        while (cp[raw_len]) {
            char ch = cp[raw_len];
            if (escaped) { escaped = 0; raw_len++; continue; }
            if (ch == '\\') { escaped = 1; raw_len++; continue; }
            if (ch == '"') break;
            raw_len++;
        }
        decode_json_string(cp, raw_len, content, (int)sizeof(content));
        if (!content[0]) continue;
        
        ctx_info_t ctx;
        strncpy(ctx.file, file, sizeof(ctx.file) - 1);
        strncpy(ctx.func, name, sizeof(ctx.func) - 1);
        ctx.abs_line = line_start;
        
        process_function_content(content, &ctx);
        func_count++;
    }
    
    fclose(fp);
    free(line);
    printf("Analyzed %d functions, found %d unique variables\n", func_count, g_var_count);
    return 0;
}

// ============================================
// 调用图加载
// ============================================

static int load_call_graph(const char* cache_dir) {
    char path[512];
    snprintf(path, sizeof(path), "%s/call_graph.json", cache_dir);
    
    FILE* fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "Warning: call_graph.json not found at %s\n", path);
        return 1;
    }
    
    json_error_t error;
    json_t* root = json_loadf(fp, 0, &error);
    fclose(fp);
    
    if (!root) {
        fprintf(stderr, "Error parsing call_graph.json: %s\n", error.text);
        return 1;
    }
    
    g_call_graph.capacity = 10000;
    g_call_graph.edges = calloc(g_call_graph.capacity, sizeof(call_edge_t));
    g_call_graph.edge_count = 0;
    
    const char* func_name;
    json_t* func_info;
    json_object_foreach(root, func_name, func_info) {
        json_t* calls = json_object_get(func_info, "calls");
        if (!calls || !json_is_array(calls)) continue;
        
        size_t idx;
        json_t* call;
        json_array_foreach(calls, idx, call) {
            if (!json_is_object(call)) continue;
            
            json_t* callee_j = json_object_get(call, "function");
            json_t* file_j = json_object_get(call, "file");
            json_t* line_j = json_object_get(call, "line");
            json_t* args_j = json_object_get(call, "arguments");
            
            if (!callee_j || !json_is_string(callee_j)) continue;
            
            if (g_call_graph.edge_count >= g_call_graph.capacity) {
                g_call_graph.capacity *= 2;
                g_call_graph.edges = realloc(g_call_graph.edges, 
                                              g_call_graph.capacity * sizeof(call_edge_t));
            }
            
            call_edge_t* edge = &g_call_graph.edges[g_call_graph.edge_count++];
            strncpy(edge->caller, func_name, sizeof(edge->caller) - 1);
            strncpy(edge->callee, json_string_value(callee_j), sizeof(edge->callee) - 1);
            
            if (file_j && json_is_string(file_j)) {
                strncpy(edge->call_site_file, json_string_value(file_j), 
                        sizeof(edge->call_site_file) - 1);
            } else {
                edge->call_site_file[0] = '\0';
            }
            
            edge->call_site_line = (line_j && json_is_integer(line_j)) ? (int)json_integer_value(line_j) : 0;
            
            edge->args[0] = '\0';
            if (args_j && json_is_array(args_j)) {
                size_t arg_idx;
                json_t* arg;
                int pos = 0;
                json_array_foreach(args_j, arg_idx, arg) {
                    if (json_is_string(arg) && pos < (int)(sizeof(edge->args) - 2)) {
                        if (pos > 0) {
                            edge->args[pos++] = ',';
                            edge->args[pos++] = ' ';
                        }
                        const char* arg_str = json_string_value(arg);
                        int len = (int)strlen(arg_str);
                        if (pos + len < (int)(sizeof(edge->args) - 1)) {
                            strcpy(edge->args + pos, arg_str);
                            pos += len;
                        }
                    }
                }
                edge->args[pos] = '\0';
            }
        }
    }
    
    json_decref(root);
    printf("Loaded call graph: %d edges\n", g_call_graph.edge_count);
    return 0;
}

// ============================================
// 跨函数分析辅助函数
// ============================================

static const char* find_var_definition_func(const char* var_name) {
    var_record_t* var = NULL;
    for (int i = 0; i < g_var_count; i++) {
        if (strcmp(g_vars[i].name, var_name) == 0) {
            var = &g_vars[i];
            break;
        }
    }
    if (!var) return NULL;
    
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].is_definition == 1) {
            return var->occurs[i].func;
        }
    }
    return NULL;
}

static void find_next_funcs(const char* var_name, const char* current_func, 
                            char** next_funcs, int* count, int max_count) {
    for (int i = 0; i < g_call_graph.edge_count; i++) {
        if (strcmp(g_call_graph.edges[i].caller, current_func) == 0 &&
            strstr(g_call_graph.edges[i].args, var_name)) {
            int dup = 0;
            for (int j = 0; j < *count; j++) {
                if (strcmp(next_funcs[j], g_call_graph.edges[i].callee) == 0) {
                    dup = 1;
                    break;
                }
            }
            if (!dup && *count < max_count) {
                next_funcs[*count] = strdup(g_call_graph.edges[i].callee);
                (*count)++;
            }
        }
    }
}

static int count_total_fields(void) {
    int count = 0;
    for (int i = 0; i < g_var_count; i++) {
        count += g_vars[i].field_count;
    }
    return count;
}

// ============================================
// 输出函数
// ============================================

static void print_dataflow(const char* var_name) {
    var_record_t* var = NULL;
    for (int i = 0; i < g_var_count; i++) {
        if (strcmp(g_vars[i].name, var_name) == 0) {
            var = &g_vars[i];
            break;
        }
    }
    
    if (!var) {
        printf("Variable '%s' not found in analyzed code.\n", var_name);
        return;
    }
    
    printf("\n╔══════════════════════════════════════════════════════════════════╗\n");
    printf("║ Variable Data Flow: %-45s ║\n", var_name);
    if (var->type[0]) {
        printf("║ Type: %-58s ║\n", var->type);
    }
    printf("║ Total occurrences: %-46d ║\n", var->occur_count);
    printf("╚══════════════════════════════════════════════════════════════════╝\n\n");
    
    // 1. 定义
    printf("📌 DEFINITIONS:\n");
    printf("─────────────────────────────────────────────────────────────────\n");
    int found = 0;
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].is_definition == 1) {
            printf("  %s:%d  in %s()\n", 
                   var->occurs[i].file, var->occurs[i].line, var->occurs[i].func);
            printf("  %s\n\n", var->occurs[i].context);
            found++;
        }
    }
    if (!found) printf("  (no explicit definition found)\n\n");
    
    // 2. 赋值
    printf("✏️  ASSIGNMENTS (Value Changes):\n");
    printf("─────────────────────────────────────────────────────────────────\n");
    found = 0;
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].is_definition == 2) {
            printf("  %s:%d  in %s()", 
                   var->occurs[i].file, var->occurs[i].line, var->occurs[i].func);
            if (var->occurs[i].field_name[0]) {
                printf("  [field: %s]", var->occurs[i].field_name);
            }
            printf("\n  %s\n\n", var->occurs[i].context);
            found++;
        }
    }
    if (!found) printf("  (no assignments found)\n\n");
    
    // 3. 使用
    printf("👁️  USAGES (Value Reads):\n");
    printf("─────────────────────────────────────────────────────────────────\n");
    found = 0;
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].is_definition == 3) {
            printf("  %s:%d  in %s()", 
                   var->occurs[i].file, var->occurs[i].line, var->occurs[i].func);
            if (var->occurs[i].field_name[0]) {
                printf("  [field: %s]", var->occurs[i].field_name);
            }
            printf("\n  %s\n\n", var->occurs[i].context);
            found++;
        }
    }
    if (!found) printf("  (no usages found)\n\n");
    
    // 4. 字段级分析
    if (var->field_count > 0) {
        printf("🔍 FIELD-LEVEL BREAKDOWN:\n");
        printf("─────────────────────────────────────────────────────────────────\n");
        for (int f = 0; f < var->field_count; f++) {
            field_record_t* field = &var->fields[f];
            printf("\n  → %s->%s (%d occurrences)\n", var_name, field->field_name, 
                   field->occur_count);
            
            for (int i = 0; i < field->occur_count && i < 5; i++) {
                occurrence_t* occ = &field->occurs[i];
                const char* type_str = (occ->is_definition == 1) ? "DEF" :
                                       (occ->is_definition == 2) ? "SET" : "USE";
                printf("    [%s] %s:%d %s()\n", type_str, occ->file, occ->line, occ->func);
            }
            if (field->occur_count > 5) {
                printf("    ... and %d more\n", field->occur_count - 5);
            }
        }
        printf("\n");
    }
    
    // 5. 跨函数数据流
    if (g_call_graph.edge_count > 0) {
        printf("🌐 CROSS-FUNCTION FLOW:\n");
        printf("─────────────────────────────────────────────────────────────────\n");
        
        const char* def_func = find_var_definition_func(var_name);
        if (!def_func) {
            if (var->occur_count > 0) def_func = var->occurs[0].func;
        }
        
        if (def_func) {
            printf("  Origin: %s() defines '%s'\n\n", def_func, var_name);
            
            char* visited[MAX_FUNCS];
            int visited_count = 0;
            char* queue[MAX_FUNCS];
            int queue_head = 0, queue_tail = 0;
            
            queue[queue_tail++] = strdup(def_func);
            visited[visited_count++] = strdup(def_func);
            
            int depth = 0;
            while (queue_head < queue_tail && depth < 5) {
                int level_size = queue_tail - queue_head;
                for (int l = 0; l < level_size && queue_head < queue_tail; l++) {
                    char* current = queue[queue_head++];
                    
                    char* next_funcs[100];
                    int next_count = 0;
                    find_next_funcs(var_name, current, next_funcs, &next_count, 100);
                    
                    for (int i = 0; i < next_count; i++) {
                        int used = 0;
                        for (int j = 0; j < var->occur_count; j++) {
                            if (strcmp(var->occurs[j].func, next_funcs[i]) == 0) {
                                used = 1;
                                break;
                            }
                        }
                        
                        for (int s = 0; s <= depth; s++) printf("  ");
                        printf("→ %s()", next_funcs[i]);
                        if (used) printf(" [uses '%s']", var_name);
                        printf("\n");
                        
                        int already_visited = 0;
                        for (int v = 0; v < visited_count; v++) {
                            if (strcmp(visited[v], next_funcs[i]) == 0) {
                                already_visited = 1;
                                break;
                            }
                        }
                        
                        if (!already_visited && queue_tail < MAX_FUNCS) {
                            queue[queue_tail++] = strdup(next_funcs[i]);
                            visited[visited_count++] = strdup(next_funcs[i]);
                        } else {
                            free(next_funcs[i]);
                        }
                    }
                }
                depth++;
            }
            
            for (int i = 0; i < queue_tail; i++) free(queue[i]);
            for (int i = 0; i < visited_count; i++) free(visited[i]);
        }
        printf("\n");
    }
}

// JSON 字符串转义：将 src 中的特殊字符转义后写入 dst，最多写入 max_len-1 个字符
static void json_escape(char* dst, const char* src, size_t max_len) {
    size_t j = 0;
    for (size_t i = 0; src[i] && j + 1 < max_len; i++) {
        unsigned char c = src[i];
        if (c == '"' || c == '\\') {
            if (j + 2 < max_len) {
                dst[j++] = '\\';
                dst[j++] = c;
            }
        } else if (c == '\n') {
            if (j + 2 < max_len) {
                dst[j++] = '\\';
                dst[j++] = 'n';
            }
        } else if (c == '\r') {
            if (j + 2 < max_len) {
                dst[j++] = '\\';
                dst[j++] = 'r';
            }
        } else if (c == '\t') {
            if (j + 2 < max_len) {
                dst[j++] = '\\';
                dst[j++] = 't';
            }
        } else if (c >= 0x20 && c < 0x7F) {
            dst[j++] = c;
        }
        // 跳过不可打印字符
    }
    dst[j] = '\0';
}

static void save_dataflow(const char* output_file) {
    FILE* fp = fopen(output_file, "w");
    if (!fp) return;
    
    fprintf(fp, "{\n");
    for (int v = 0; v < g_var_count; v++) {
        if (v > 0) fprintf(fp, ",\n");
        var_record_t* var = &g_vars[v];
        char escaped_name[512];
        json_escape(escaped_name, var->name ? var->name : "", sizeof(escaped_name));
        fprintf(fp, "  \"%s\": {\n", escaped_name);
        if (var->type[0]) {
            char escaped_type[256];
            json_escape(escaped_type, var->type ? var->type : "", sizeof(escaped_type));
            fprintf(fp, "    \"type\": \"%s\",\n", escaped_type);
        }
        
        if (var->field_count > 0) {
            fprintf(fp, "    \"fields\": {\n");
            for (int f = 0; f < var->field_count; f++) {
                if (f > 0) fprintf(fp, ",\n");
                field_record_t* field = &var->fields[f];
                char escaped_fname[512];
                json_escape(escaped_fname, field->field_name ? field->field_name : "", sizeof(escaped_fname));
                fprintf(fp, "      \"%s\": [\n", escaped_fname);
                for (int i = 0; i < field->occur_count; i++) {
                    if (i > 0) fprintf(fp, ",\n");
                    occurrence_t* occ = &field->occurs[i];
                    const char* type_str = (occ->is_definition == 1) ? "definition" :
                                           (occ->is_definition == 2) ? "assignment" : "usage";
                    char escaped_context[512], escaped_file[1024], escaped_func[512];
                    json_escape(escaped_context, occ->context, sizeof(escaped_context));
                    json_escape(escaped_file, occ->file ? occ->file : "", sizeof(escaped_file));
                    json_escape(escaped_func, occ->func ? occ->func : "", sizeof(escaped_func));
                    fprintf(fp, "        {\"file\":\"%s\",\"func\":\"%s\",\"line\":%d,\"type\":\"%s\",\"context\":\"%s\"}",
                           escaped_file, escaped_func, occ->line, type_str, escaped_context);
                }
                fprintf(fp, "\n      ]");
            }
            fprintf(fp, "\n    },\n");
        }
        
        fprintf(fp, "    \"occurrences\": [\n");
        for (int i = 0; i < var->occur_count; i++) {
            if (i > 0) fprintf(fp, ",\n");
            occurrence_t* occ = &var->occurs[i];
            const char* type_str = (occ->is_definition == 1) ? "definition" :
                                   (occ->is_definition == 2) ? "assignment" : "usage";
            char escaped_context[512], escaped_file[1024], escaped_func[512];
            json_escape(escaped_context, occ->context, sizeof(escaped_context));
            json_escape(escaped_file, occ->file ? occ->file : "", sizeof(escaped_file));
            json_escape(escaped_func, occ->func ? occ->func : "", sizeof(escaped_func));
            fprintf(fp, "      {\"file\":\"%s\",\"func\":\"%s\",\"line\":%d,\"type\":\"%s\",\"context\":\"%s\"}",
                   escaped_file, escaped_func, occ->line, type_str, escaped_context);
        }
        fprintf(fp, "\n    ]\n  }");
    }
    fprintf(fp, "\n}\n");
    fclose(fp);
}

// ============================================
// 主函数
// ============================================

int lite_cs_dataflow_main(int argc, char** argv) {
    if (argc < 2) {
        printf("Variable Data Flow Analyzer (Enhanced)\n");
        printf("Features: Struct field tracking + Cross-function data flow\n");
        printf("Usage:\n");
        printf("  %s analyze <cache_dir>              # Analyze all variables\n", argv[0]);
        printf("  %s show <cache_dir> <var_name>     # Show data flow for variable\n", argv[0]);
        printf("\nExamples:\n");
        printf("  %s analyze /opt/code_caches/nginx_cache\n", argv[0]);
        printf("  %s show /opt/code_caches/nginx_cache c            # Shows c->fd, c->data, etc.\n", argv[0]);
        printf("  %s show /opt/code_caches/nginx_cache ngx_connection  # Cross-function flow\n", argv[0]);
        return 1;
    }
    
    const char* cmd = argv[1];
    const char* cache_dir = argv[2];
    
    if (strcmp(cmd, "analyze") == 0) {
        if (!cache_dir) {
            fprintf(stderr, "Usage: %s analyze <cache_dir>\n", argv[0]);
            return 1;
        }
        
        char meta_file[512], out_file[512];
        snprintf(meta_file, sizeof(meta_file), "%s/chunks_meta.jsonl", cache_dir);
        snprintf(out_file, sizeof(out_file), "%s/dataflow.json", cache_dir);
        
        printf("Analyzing data flow from %s...\n", meta_file);
        if (analyze_meta(meta_file) != 0) return 1;
        
        load_call_graph(cache_dir);
        
        save_dataflow(out_file);
        printf("Saved data flow to %s\n", out_file);
        printf("Found %d variables, %d fields tracked\n", g_var_count, count_total_fields());
        
    } else if (strcmp(cmd, "show") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: %s show <cache_dir> <var_name>\n", argv[0]);
            return 1;
        }
        
        const char* var_name = argv[3];
        char meta_file[512];
        snprintf(meta_file, sizeof(meta_file), "%s/chunks_meta.jsonl", cache_dir);
        
        printf("Loading data flow from %s...\n", meta_file);
        if (analyze_meta(meta_file) != 0) return 1;
        
        load_call_graph(cache_dir);
        
        print_dataflow(var_name);
        
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
    
    return 0;
}
