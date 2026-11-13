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
#define MAX_PARAMS 12   /* 形参表长度上限 = 实参位置上限（跨过程 hop 按位置对齐） */

// 前向声明（is_c_type / is_type_word / is_type_qualifier 定义在后面）
static int is_c_type(const char* word);
static int is_type_word(const char* w);
static int is_type_qualifier(const char* w);

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

// 跨过程数据流的一跳：变量在 caller 里作为第 pos 个实参传给 callee，
// 落到 callee 的形参 param 上（sig 解析不出来时 param 为空）。
// scope/def/defs 直接抄 call_graph.json 的跨文件解析结果：
//   local=同文件定义 / def=唯一可见定义文件 / ambiguous=defs 份同名实现混在这条边上。
#define MAX_HOPS 48
typedef struct {
    char caller[256];
    char callee[256];
    char file[512];
    int line;
    char param[64];
    int pos;
    int scope;          // 0=external 1=local 2=global 3=ambiguous
    char def[512];
    int defs;
} hop_t;

// 变量记录（增强版：支持字段）
// occurs/fields 改为动态分配：旧版内联 occurs[MAX_OCCURS]（每变量 ~232KB），
// 导致 MAX_VARS 无法上调、内核只覆盖前 1 万变量。
typedef struct {
    char name[128];
    char type[128];
    occurrence_t* occurs;   // 动态，上限 MAX_OCCURS
    int occur_count;
    int occur_capacity;
    int occur_seen;         // 真·总次数（含被 MAX_OCCURS 挡掉的），落盘为 occurrences_total
    int occur_truncated;    // 1 = 撞 MAX_OCCURS 被截断，输出里要标出来
    field_record_t* fields; // 动态，上限 MAX_FIELDS
    int field_count;
    int field_capacity;
    hop_t* hops;            // 动态，上限 MAX_HOPS（跨过程实参传递）
    int hop_count;
    int hop_capacity;
} var_record_t;

static var_record_t* g_vars = NULL;
static int g_var_count = 0;
static int g_var_capacity = 0;

// 语言分布：dataflow 只做 C 词法（声明驱动），python/go/ts 的函数体也能走一遍但
// 语义差得远。0 条命中时必须能说清是「这门语言不在覆盖范围」还是「名字拼错了」，
// 所以 analyzing 时把语言计数落到 dataflow_meta.json，import 存进 KV。
#define MAX_LANGS 16
typedef struct {
    char name[24];
    int funcs;
} lang_count_t;
static lang_count_t g_langs[MAX_LANGS];
static int g_lang_count = 0;
static int g_funcs_total = 0;
static int g_hop_total = 0;

static int lang_is_c_family(const char* l) {
    return l && (strcmp(l, "c") == 0 || strcmp(l, "cpp") == 0 ||
                 strcmp(l, "objc") == 0 || strcmp(l, "objcpp") == 0);
}

static void count_lang(const char* lang) {
    if (!lang || !*lang) lang = "unknown";
    for (int i = 0; i < g_lang_count; i++) {
        if (strcmp(g_langs[i].name, lang) == 0) { g_langs[i].funcs++; return; }
    }
    if (g_lang_count >= MAX_LANGS) return;
    strncpy(g_langs[g_lang_count].name, lang, sizeof(g_langs[0].name) - 1);
    g_langs[g_lang_count].funcs = 1;
    g_lang_count++;
}

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
    // 按顶层逗号切开的实参表达式（arg_list[k] 就是第 k 个实参）。只留一份字符串
    // 时位置无法还原，hop 也就只能写 "传给了 callee" 而说不出「传给第几个形参」。
    char arg_list[MAX_PARAMS][128];
    int arg_count;
    int scope;        // 0=external 1=local 2=global 3=ambiguous（call_graph.json）
    char def[512];
    int defs;
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
    var->occur_seen = 0;
    var->occur_truncated = 0;
    var->fields = NULL; var->field_count = 0; var->field_capacity = 0;
    var->hops = NULL; var->hop_count = 0; var->hop_capacity = 0;

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
    // 截断不静默：occur_seen 记真·总次数，输出里带 occurrences_total，
    // 调用方能看到「只落了 2000 条，实际 8721 次」而不是当成全部。
    if (!var) return;
    var->occur_seen++;
    if (var->occur_count >= MAX_OCCURS) {
        var->occur_truncated = 1;
        return;
    }
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
// 函数形参表（跨过程数据流的「落点」）
//
// 旧版跨函数流只做 `strstr(实参串, 变量名)`：`buf` 会命中 `bufsize`，嵌套调用
// `f(g(x), 1)` 里的 x 被算成传给 f，而且从不记形参名 —— 于是「x 传到 helper_add
// 的第几个形参、那里有没有被改写」在 dataflow.json 里根本不存在。
// 这里从 chunks_meta 的 signature 解析形参（name + type），实参按顶层逗号切成
// 位置索引 → 形参名，跨过程边才带得上 param/pos。
// ============================================
#define PARAM_HASH_SIZE 65536

typedef struct {
    char name[64];
    char type[64];
} param_t;

typedef struct func_param {
    char func[256];
    param_t params[MAX_PARAMS];
    int count;
    struct func_param* next;
} func_param_t;

static func_param_t** g_param_hash = NULL;

static unsigned int param_hash(const char* s) {
    unsigned int h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)*s++;
    return h % PARAM_HASH_SIZE;
}

static func_param_t* func_params(const char* func) {
    if (!g_param_hash || !func || !*func) return NULL;
    func_param_t* p = g_param_hash[param_hash(func)];
    while (p && strcmp(p->func, func) != 0) p = p->next;
    return p;
}

static func_param_t* func_params_create(const char* func) {
    if (!g_param_hash) {
        g_param_hash = calloc(PARAM_HASH_SIZE, sizeof(func_param_t*));
        if (!g_param_hash) return NULL;
    }
    unsigned int h = param_hash(func);
    func_param_t* p = g_param_hash[h];
    while (p && strcmp(p->func, func) != 0) p = p->next;
    if (p) return p;
    p = calloc(1, sizeof(func_param_t));
    if (!p) return NULL;
    strncpy(p->func, func, sizeof(p->func) - 1);
    p->next = g_param_hash[h];
    g_param_hash[h] = p;
    return p;
}

// ============================================
// 字段访问提取
// ============================================

// 从一段形参声明里取 (name, type)。无名形参（只有类型，如 `int`）返回 0：
// 位置仍然保留（实参按位置对齐），只是 param 为空。
static int parse_param_decl(const char* part, int part_len, param_t* out) {
    char buf[256];
    int n = part_len < (int)sizeof(buf) - 1 ? part_len : (int)sizeof(buf) - 1;
    memcpy(buf, part, (size_t)n);
    buf[n] = '\0';
    // 去掉默认值（C++）与数组维度 / 位域
    for (char* q = buf; *q; q++) {
        if (*q == '=' || *q == '[' || *q == ':') { *q = '\0'; break; }
    }
    const char* name = NULL;
    int name_len = 0;
    char* fp = strstr(buf, "(*");   // 函数指针 `int (*cb)(int)`
    if (fp) {
        const char* q = fp + 2;
        while (*q == ' ' || *q == '*') q++;
        name = q;
        while (*q && (isalnum((unsigned char)*q) || *q == '_')) q++;
        name_len = (int)(q - name);
    } else {
        // 取「最后一个不是类型词/关键字的标识符」：`const char *src` → src，
        // `struct x *p` → p，无名形参 `int` → 没有
        const char* q = buf;
        while (*q) {
            if (isalpha((unsigned char)*q) || *q == '_') {
                const char* s = q;
                while (*q && (isalnum((unsigned char)*q) || *q == '_')) q++;
                int len = (int)(q - s);
                char tok[64];
                int tl2 = len < 63 ? len : 63;
                memcpy(tok, s, (size_t)tl2);
                tok[tl2] = '\0';
                if (!is_type_word(tok) && !is_c_keyword(tok) && !is_type_qualifier(tok) &&
                    strcmp(tok, "struct") != 0 && strcmp(tok, "union") != 0 &&
                    strcmp(tok, "enum") != 0) {
                    name = s;
                    name_len = len;
                }
                continue;
            }
            q++;
        }
    }
    if (!name || name_len <= 0 || name_len >= (int)sizeof(out->name)) return 0;
    memcpy(out->name, name, (size_t)name_len);
    out->name[name_len] = '\0';
    // 类型 = 名字之前的文本，去掉尾部的 * 和空白
    int tl = (int)(name - buf);
    while (tl > 0 && (buf[tl - 1] == ' ' || buf[tl - 1] == '*' || buf[tl - 1] == '\t'))
        tl--;
    if (tl >= (int)sizeof(out->type)) tl = (int)sizeof(out->type) - 1;
    memcpy(out->type, buf, (size_t)tl);
    out->type[tl] = '\0';
    return 1;
}
// signature 形如 `static int helper_add(int a, int b)` / `foo(void)`：
// 只切括号内的顶层逗号，嵌套括号（函数指针）靠 depth 跳过。
static void add_func_params(const char* func, const char* sig) {
    if (!func || !*func || !sig || !*sig) return;
    const char* open = strchr(sig, '(');
    if (!open) return;
    int depth = 0;
    const char* close = NULL;
    for (const char* p = open; *p; p++) {
        if (*p == '(') depth++;
        else if (*p == ')') { if (--depth == 0) { close = p; break; } }
    }
    if (!close) close = open + strlen(open);
    func_param_t* fp = func_params_create(func);
    if (!fp) return;
    const char* start = open + 1;
    depth = 0;
    for (const char* p = open + 1; *p; p++) {
        int boundary = (p == close);
        if (!boundary) {
            if (*p == '(') { depth++; continue; }
            if (*p == ')') { depth--; continue; }
            // 普通字符必须 continue：旧版缺这一句，于是每轮都往下走
            // `start = p + 1`，len 恒为 0，形参表永远是空的。
            if (*p == ',' && depth == 0) boundary = 1;
            else continue;
        }
        int len = (int)(p - start);
        if (len > 0 && fp->count < MAX_PARAMS) {
            param_t pt;
            if (parse_param_decl(start, len, &pt)) fp->params[fp->count++] = pt;
        }
        start = p + 1;
        if (p == close) break;
    }
}
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

// 形参在函数体里被赋值（`a = a + b`）：旧版这条写完全不可见（形参从没被当成
// 变量声明过），于是「x 传进 helper_add 后有没有被改写」永远判不出来。这里按
// signature 解析出的形参表补一条赋值 occurrence，类型取形参类型。
static var_record_t* implicit_param_var(const char* name, const char* func) {
    func_param_t* fp = func_params(func);
    if (!fp) return NULL;
    for (int i = 0; i < fp->count; i++) {
        if (strcmp(fp->params[i].name, name) != 0) continue;
        var_record_t* var = find_or_create_var(name);
        if (!var) return NULL;
        if (!var->type[0])
            strncpy(var->type, fp->params[i].type, sizeof(var->type) - 1);
        return var;
    }
    return NULL;
}

// 该变量在这个「文件+函数」作用域里是否已经记过声明（is_definition==1）。
// 同名变量在不同函数里是不同实体，decl 必须按作用域取，不能全库取第一条。
static int has_def_in(var_record_t* var, const char* file, const char* func) {
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].is_definition != 1) continue;
        if (strcmp(var->occurs[i].file, file) != 0) continue;
        if (strcmp(var->occurs[i].func, func) != 0) continue;
        return 1;
    }
    return 0;
}

// 同一「文件+函数+行」是否已记过这个变量的任意一条 occurrence。
// 去重只比行号不行（内核里不同文件的同名变量常撞行号）。
static int has_occ_at(var_record_t* var, const char* file, const char* func, int line) {
    for (int i = 0; i < var->occur_count; i++) {
        if (var->occurs[i].line != line) continue;
        if (strcmp(var->occurs[i].file, file) != 0) continue;
        if (strcmp(var->occurs[i].func, func) != 0) continue;
        return 1;
    }
    return 0;
}

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
                // 以前只在 var->occur_count == 0（全库第一次见到）时记 definition，
                // 于是「同名变量第二次声明」永远没有定义行 —— 查询里 decl 只能退回
                // 全库那条，指到别的文件的同名局部（`reason` 的声明落在 ubsan.c:219）。
                // 现在按「文件+函数」判重：每个作用域里的声明都记一条 definition。
                if (var && !has_def_in(var, ctx->file, ctx->func)) {
                    // 类型取"变量名前面最后一个非 * token"：`const char *src` 记 char
                    // 而不是 const（旧版一律取第一个词）。
                    int ti = j - 1;
                    while (ti > i && strcmp(tokens[ti], "*") == 0) ti--;
                    if (ti < i) ti = i;
                    // 类型只认第一次声明：同名变量的第二个作用域不该改写全库 type
                    if (!var->type[0]) {
                        strncpy(var->type, tokens[ti], sizeof(var->type) - 1);
                        var->type[sizeof(var->type) - 1] = '\0';
                    }
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
                // `obj->field = 1` / `s.field = 1`：field 是成员名，不是局部变量
                int is_member = (i >= 2 && (strcmp(tokens[i - 2], "->") == 0 ||
                                            strcmp(tokens[i - 2], ".") == 0));
                var_record_t* var = find_var(prev);
                if (!var && !is_member) var = implicit_param_var(prev, ctx->func);
                // 声明没被认出来的局部变量（跨行声明、宏展开、非 C 语言的
                // `x = 1`）以前整条赋值都丢掉，于是查询那儿「变量查不到」。
                // 这里兜底建一个无类型变量：只要求是个合法标识符、不是成员名。
                if (!var && !is_member && is_identifier(prev) &&
                    !is_c_type(prev) && !is_c_keyword(prev) && !is_type_word(prev)) {
                    var = find_or_create_var(prev);
                }
                // `int flag = 0;` 走完上面的声明分支已经记过 definition，
                // 这里再记一条 assignment 就是同一行两条（查询里 delta/reason
                // 都是一定义一赋值重复出现，白占 occurrences 配额）。
                if (var && !has_occ_at(var, ctx->file, ctx->func, ctx->abs_line)) {
                    const char* field = extract_field_access(line, prev);
                    add_occurrence(var, ctx->file, ctx->func, ctx->abs_line, 0, line, 2, field);
                }
            }
        }

        // 3. 使用（含字段访问）
        //    `p->slow.netdev` / `a.b` 里的 slow/netdev/b 是**成员名**，不是变量：
        //    只要别处真有一个同名局部（内核里 `bool slow;` 到处都有），旧版就会把
        //    全内核的 `->slow` 全算到那个变量头上（现场：`in`/`slow` 变成了「使用了
        //    上千次的全局变量」，type 还是错的）。成员名的记录由基变量那条
        //    extract_field_access 负责，这里直接跳过。
        int is_member_name = (i > 0 && (strcmp(tokens[i - 1], "->") == 0 ||
                                        strcmp(tokens[i - 1], ".") == 0));
        //    标签不是变量：`goto validate;` 的操作数和 `validate:` 这个定义点都不该
        //    落到某个同名变量头上（内核里 goto 极多，旧版让标签成了「用了 116 次的
        //    变量 validate」，而它的声明指向任何同名局部）。判定要保守：`a ? b : c`
        //    里的 b 后面也跟 ':'，所以只在「语句开头」或「goto 后面」才认标签。
        int is_label = (i > 0 && strcmp(tokens[i - 1], "goto") == 0) ||
                       (i + 1 < token_count && strcmp(tokens[i + 1], ":") == 0 &&
                        (i == 0 || strcmp(tokens[i - 1], ";") == 0 ||
                         strcmp(tokens[i - 1], "{") == 0 ||
                         strcmp(tokens[i - 1], "}") == 0));
        //    函数调用/类型转换不是变量：`tcp_sk(sk)`、`(struct sock *)x` 里的
        //    标识符后面跟 '('，旧版把 tcp_sk 当成了「用过的变量」，decl 落到
        //    别的文件的同名函数上。调用关系归 call_graph，不归 dataflow。
        int is_call = (i + 1 < token_count && strcmp(tokens[i + 1], "(") == 0);
        if (!is_member_name && !is_label && !is_call &&
            (isalpha((unsigned char)tokens[i][0]) || tokens[i][0] == '_') &&
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
                    if (!has_occ_at(var, ctx->file, ctx->func, ctx->abs_line)) {
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
    // 窗口/切片可能从块注释中间开始（上面 " // Part " 已跳过，但别的来源仍可能）：
    // 一行里出现 `*/` 却没出现 `/*`，说明前文是这个注释的一部分，整行都是注释尾巴
    // （`… check it more carefully in slow path */` 里的 in/slow/path 曾被当变量）。
    if (!*in_block) {
        const char* close = strstr(line, "*/");
        if (close && !strstr(line, "/*") && !strstr(line, "//")) {
            const char* after = close + 2;
            memmove(line, after, strlen(after) + 1);
        }
    }
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
        char* sig_p = strstr(line, "\"signature\":\"");
        char* line_p = strstr(line, "\"line_start\":");
        char* content_p = strstr(line, "\"content\":\"");
        char* lang_p = strstr(line, "\"language\":\"");
        
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

        // 长函数被切成 "sig // Part N" 窗口（indexer.c，每个窗口 1500B/重叠 500B），
        // 但这些窗口的 line_start 都是函数起始行 —— 拿它们当函数体分析有三个连锁错：
        //   ① 行号全挤在函数开头（tcp_rcv_established 的 `in`/`last` 都落到 6508）；
        //   ② 窗口从注释中间切开（`/* If PAWS failed… */` 只剩尾巴），去注释器看不到
        //      开头的 `/*`，注释里的 in/last/slow 被当成变量；
        //   ③ 同一函数体被重复分析 4~5 次，occurrences 与 occurrences_total 一起虚高。
        // 首个 chunk 已是完整函数体（≤16000B，行号正确），窗口只服务检索/向量，
        // 这里直接跳过（import.c 的 KV 写入也做了同样的跳过）。
        if (strstr(content, " // Part ")) continue;
        
        ctx_info_t ctx;
        strncpy(ctx.file, file, sizeof(ctx.file) - 1);
        strncpy(ctx.func, name, sizeof(ctx.func) - 1);
        ctx.abs_line = line_start;
        
        // 形参表：跨过程流要把实参位置映射到 callee 的形参名。
        if (sig_p) {
            char sig[512];
            int si = 0;
            // sig_p 指向 strstr 的 `"signature":"`（13 字节，末尾那个引号是值的开引号）。
            // 旧版只 +12，sp 停在开引号上，上面循环立刻因 *sp=='"' 结束 → sig 恒空，
            // 于是 func_params 永远是空表，跨过程 hop 的 param 全为空。
            const char* sp = sig_p + 13;
            while (*sp && *sp != '"' && si < (int)sizeof(sig) - 1) {
                if (*sp == '\\' && sp[1]) { sp++; if (*sp != 'n' && *sp != 't') sig[si++] = *sp; }
                else sig[si++] = *sp;
                sp++;
            }
            sig[si] = '\0';
            add_func_params(name, sig);
        }

        // 语言计数：只统计真正会被分析的函数体（上面 kind 过滤已经过了）
        {
            char lang[24] = {0};
            int li = 0;
            if (lang_p) {
                const char* lp = lang_p + 12;
                while (*lp && *lp != '"' && li < (int)sizeof(lang) - 1) lang[li++] = *lp++;
            }
            lang[li] = '\0';
            count_lang(lang);
        }

        process_function_content(content, &ctx);
        func_count++;
        g_funcs_total = func_count;
    }
    
    fclose(fp);
    free(line);
    printf("Analyzed %d functions, found %d unique variables\n", func_count, g_var_count);
    return 0;
}

// ============================================
// 调用图加载
// ============================================

// call_graph.json 的 arguments 是对齐切口后重新拼成的一整串（"c, pool, log"），
// 位置信息只剩「顶层逗号的第几段」。跨过程 hop 要写「传给第几个形参」，所以
// 加载时按顶层逗号再切回 arg_list[]（括号/方括号内的逗号不算，嵌套调用保持完整）。
static void split_edge_args(call_edge_t* edge) {
    edge->arg_count = 0;
    const char* p = edge->args;
    while (*p && edge->arg_count < MAX_PARAMS) {
        while (*p == ' ' || *p == '\t') p++;
        const char* start = p;
        int depth = 0;
        while (*p) {
            if (*p == '(' || *p == '[' || *p == '{') depth++;
            else if ((*p == ')' || *p == ']' || *p == '}') && depth > 0) depth--;
            else if (*p == ',' && depth == 0) break;
            p++;
        }
        int len = (int)(p - start);
        while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\t')) len--;
        if (len > 0) {
            int cap = (int)sizeof(edge->arg_list[0]) - 1;
            int n = len < cap ? len : cap;
            memcpy(edge->arg_list[edge->arg_count], start, (size_t)n);
            edge->arg_list[edge->arg_count][n] = '\0';
            edge->arg_count++;
        }
        if (*p == ',') { p++; continue; }
        break;
    }
}

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
            
            // call_graph.json 是反向图：key 是 callee，entry 的 "function" 是 caller。
            // 旧版直接 key→caller、"function"→callee，整张图装反，于是「谁调谁」
            // 和跨过程流全是反的（helper_add 的实参被算成传给调用者的实参）。
            json_t* caller_j = json_object_get(call, "function");
            json_t* file_j = json_object_get(call, "file");
            json_t* line_j = json_object_get(call, "line");
            json_t* args_j = json_object_get(call, "arguments");
            
            if (!caller_j || !json_is_string(caller_j)) continue;
            
            if (g_call_graph.edge_count >= g_call_graph.capacity) {
                g_call_graph.capacity *= 2;
                g_call_graph.edges = realloc(g_call_graph.edges, 
                                              g_call_graph.capacity * sizeof(call_edge_t));
            }
            
            call_edge_t* edge = &g_call_graph.edges[g_call_graph.edge_count++];
            memset(edge, 0, sizeof(*edge));
            strncpy(edge->caller, json_string_value(caller_j), sizeof(edge->caller) - 1);
            strncpy(edge->callee, func_name, sizeof(edge->callee) - 1);
            
            if (file_j && json_is_string(file_j)) {
                strncpy(edge->call_site_file, json_string_value(file_j), 
                        sizeof(edge->call_site_file) - 1);
            } else {
                edge->call_site_file[0] = '\0';
            }
            
            edge->call_site_line = (line_j && json_is_integer(line_j)) ? (int)json_integer_value(line_j) : 0;

            // 跨文件解析结果（callgraph.c 写进 call_graph.json）：
            // scope=local 同文件定义；def=唯一可见定义；scope=ambiguous 多份同名实现。
            // 跨过程流直接带上，免得调用侧以为这条边是精确的。
            edge->scope = 0;
            edge->def[0] = '\0';
            edge->defs = 0;
            {
                const char* scope_s = json_string_value(json_object_get(call, "scope"));
                const char* def_s = json_string_value(json_object_get(call, "def"));
                if (def_s && *def_s) {
                    strncpy(edge->def, def_s, sizeof(edge->def) - 1);
                    edge->scope = 2;
                }
                if (scope_s && strcmp(scope_s, "local") == 0) edge->scope = 1;
                else if (scope_s && strcmp(scope_s, "ambiguous") == 0) edge->scope = 3;
                json_t* defs_j = json_object_get(call, "defs");
                if (defs_j && json_is_integer(defs_j)) edge->defs = (int)json_integer_value(defs_j);
            }
            
            edge->args[0] = '\0';
            edge->arg_count = 0;
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
            split_edge_args(edge);
        }
    }
    
    json_decref(root);
    printf("Loaded call graph: %d edges\n", g_call_graph.edge_count);
    return 0;
}

// ============================================
// 跨过程跳（hop）：变量在 caller 里作为第 k 个实参传给 callee
//
// 旧版跨函数流只在查询侧用 strstr(args, var_name) 猜，dataflow.json 里既没有
// 位置也没有形参名，于是「x 传给 helper_add 的哪个形参、那里是不是形参上被改写」
// 全靠人肉翻代码。这里把边显式落盘，查询/打印都直接读。
// caller → edges 建哈希，避免对每个 occurrence 线性扫全部调用边。
// ============================================
#define CALLER_HASH_SIZE 65536
typedef struct edge_node {
    int idx;
    struct edge_node* next;
} edge_node_t;

static edge_node_t** g_caller_hash = NULL;

static unsigned int caller_hash(const char* s) {
    unsigned int h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)*s++;
    return h % CALLER_HASH_SIZE;
}

static void build_caller_index(void) {
    if (g_caller_hash || g_call_graph.edge_count <= 0) return;
    g_caller_hash = calloc(CALLER_HASH_SIZE, sizeof(edge_node_t*));
    if (!g_caller_hash) return;
    for (int i = 0; i < g_call_graph.edge_count; i++) {
        unsigned int h = caller_hash(g_call_graph.edges[i].caller);
        edge_node_t* n = malloc(sizeof(edge_node_t));
        if (!n) return;
        n->idx = i;
        n->next = g_caller_hash[h];
        g_caller_hash[h] = n;
    }
}

// 实参表达式里这个变量是不是「直接」传过去的：`buf` 不算 `bufsize`，
// `f(g(x), 1)` 里的 x 也不算传给 f（它传给 g）——旧版 strstr 两个都错。
static int arg_refers_to(const char* arg, const char* var) {
    if (!arg || !*arg || !var || !*var) return 0;
    size_t vl = strlen(var);
    for (const char* q = arg; *q; q++) {
        if (*q == '"') break;  // 字符串字面量后面不是代码
        if (!(isalpha((unsigned char)*q) || *q == '_')) continue;
        const char* s = q;
        while (*q && (isalnum((unsigned char)*q) || *q == '_')) q++;
        const char* after = q;
        while (*after == ' ' || *after == '\t') after++;
        if (*after == '(') return 0;   // 嵌套调用：实参属于内层函数
        (void)s;
    }
    const char* p = arg;
    while ((p = strstr(p, var)) != NULL) {
        if (p > arg && (isalnum((unsigned char)p[-1]) || p[-1] == '_')) { p += vl; continue; }
        char nb = p[vl];
        if (!(isalnum((unsigned char)nb) || nb == '_')) return 1;
        p += vl;
    }
    return 0;
}

static void add_hop(var_record_t* var, const call_edge_t* e, int pos, const char* param) {
    if (!var || !e) return;
    for (int i = 0; i < var->hop_count; i++) {
        hop_t* h = &var->hops[i];
        if (h->line == e->call_site_line && h->pos == pos &&
            strcmp(h->callee, e->callee) == 0) return;   // 同一调用点已记
    }
    if (var->hop_count >= MAX_HOPS) return;
    if (var->hop_count >= var->hop_capacity) {
        int newcap = var->hop_capacity ? var->hop_capacity * 2 : 4;
        if (newcap > MAX_HOPS) newcap = MAX_HOPS;
        hop_t* nh = realloc(var->hops, (size_t)newcap * sizeof(hop_t));
        if (!nh) return;
        var->hops = nh;
        var->hop_capacity = newcap;
    }
    hop_t* h = &var->hops[var->hop_count++];
    memset(h, 0, sizeof(*h));
    strncpy(h->caller, e->caller, sizeof(h->caller) - 1);
    strncpy(h->callee, e->callee, sizeof(h->callee) - 1);
    strncpy(h->file, e->call_site_file, sizeof(h->file) - 1);
    h->line = e->call_site_line;
    if (param) strncpy(h->param, param, sizeof(h->param) - 1);
    h->pos = pos;
    h->scope = e->scope;
    strncpy(h->def, e->def, sizeof(h->def) - 1);
    h->defs = e->defs;
}

#define MAX_FUNCS_PER_VAR 64   // 一个变量跨过太多函数时只取前 64 个（hop 上限已是 48）

static void build_hops(void) {
    build_caller_index();
    if (!g_caller_hash) return;
    int total = 0;
    for (int v = 0; v < g_var_count; v++) {
        var_record_t* var = &g_vars[v];
        if (var->occur_count == 0) continue;
        char seen[MAX_FUNCS_PER_VAR][256];
        int nf = 0;
        for (int o = 0; o < var->occur_count && var->hop_count < MAX_HOPS; o++) {
            const char* fn = var->occurs[o].func;
            if (!fn || !*fn) continue;
            int dup = 0;
            for (int i = 0; i < nf; i++) {
                if (strcmp(seen[i], fn) == 0) { dup = 1; break; }
            }
            if (dup) continue;
            if (nf >= MAX_FUNCS_PER_VAR) continue;
            strncpy(seen[nf], fn, sizeof(seen[0]) - 1);
            seen[nf][sizeof(seen[0]) - 1] = '\0';
            nf++;
            for (edge_node_t* nd = g_caller_hash[caller_hash(fn)]; nd; nd = nd->next) {
                if (var->hop_count >= MAX_HOPS) break;
                call_edge_t* e = &g_call_graph.edges[nd->idx];
                if (strcmp(e->caller, fn) != 0) continue;
                func_param_t* fp = func_params(e->callee);
                for (int k = 0; k < e->arg_count && k < MAX_PARAMS; k++) {
                    if (!arg_refers_to(e->arg_list[k], var->name)) continue;
                    // sig 解析不出来（或无此位形参）时 param 留空，pos 照样有效
                    const char* pname = (fp && k < fp->count) ? fp->params[k].name : "";
                    int before = var->hop_count;
                    add_hop(var, e, k, pname);
                    if (var->hop_count > before) total++;
                }
            }
        }
    }
    g_hop_total = total;
    printf("Cross-proc hops: %d\n", total);
}

// dataflow_meta.json：这份分析到底覆盖了什么。以前只有 stdout 上的
// "Found N variables"，import 之后查询侧一无所知 —— 非 C 语言（python/go/ts）
// 命中 0 条时看起来和「拼错名字」没区别。落盘后 query 能在空结果里说清原因。
static void write_dataflow_meta(const char* cache_dir) {
    char path[512];
    snprintf(path, sizeof(path), "%s/dataflow_meta.json", cache_dir);
    json_t* root = json_object();
    if (!root) return;
    json_object_set_new(root, "functions", json_integer(g_funcs_total));
    json_object_set_new(root, "variables", json_integer(g_var_count));
    json_object_set_new(root, "hops", json_integer(g_hop_total));
    int c_funcs = 0, other_funcs = 0;
    json_t* langs = json_object();
    for (int i = 0; i < g_lang_count; i++) {
        json_object_set_new(langs, g_langs[i].name, json_integer(g_langs[i].funcs));
        if (lang_is_c_family(g_langs[i].name)) c_funcs += g_langs[i].funcs;
        else other_funcs += g_langs[i].funcs;
    }
    json_object_set_new(root, "langs", langs);
    json_object_set_new(root, "c_family_functions", json_integer(c_funcs));
    json_object_set_new(root, "other_language_functions", json_integer(other_funcs));
    json_object_set_new(root, "lexer", json_string("c-family"));

    // 覆盖范围内但为空、或压根没有 C 族函数时，把话说在明面上
    if (other_funcs > 0 && c_funcs == 0) {
        json_object_set_new(root, "note", json_string(
            "dataflow only lexes C-family (c/cpp/objc) function bodies; this index has "
            "0 such functions, so cross-function data flow is empty by design — use "
            "action=context / action=grep for other languages"));
    } else if (other_funcs > 0) {
        json_object_set_new(root, "note", json_string(
            "dataflow only lexes C-family (c/cpp/objc) function bodies; "
            "other_language_functions are parsed with the C lexer and their "
            "variables/uses are largely missing"));
    }
    char* str = json_dumps(root, JSON_COMPACT | JSON_PRESERVE_ORDER);
    if (str) {
        FILE* fp = fopen(path, "w");
        if (fp) {
            fputs(str, fp);
            fclose(fp);
        }
        free(str);
    }
    json_decref(root);
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
    if (var->hop_count > 0) {
        printf("🌉 CROSS-PROC HOPS (explicit, arg position → param):\n");
        printf("─────────────────────────────────────────────────────────────────\n");
        static const char* scope_names[4] = {"external", "local", "global", "ambiguous"};
        for (int i = 0; i < var->hop_count; i++) {
            hop_t* h = &var->hops[i];
            printf("  %s:%d  %s() → %s(", h->file, h->line, h->caller, h->callee);
            if (h->param[0]) printf("%s", h->param);
            else printf("arg%d", h->pos);
            printf(")  [pos %d, %s]", h->pos, scope_names[h->scope & 3]);
            if (h->def[0]) printf(" def=%s", h->def);
            if (h->defs > 1) printf(" (%d impls)", h->defs);
            printf("\n");
        }
        printf("\n");
    }

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
        
        // 撞 MAX_OCCURS 时条目是被截断的：不标出来，调用方会以为「这个变量
        // 全生命周期就这么多引用」（i/ret 这类高频变量最容易被误读）。
        // occurrences_total 永远是真·总次数，truncated 时它 > 落盘条数。
        fprintf(fp, "    \"occurrences_total\": %d,\n",
                var->occur_seen > var->occur_count ? var->occur_seen : var->occur_count);
        if (var->occur_truncated) {
            fprintf(fp, "    \"occurrences_truncated\": true,\n");
            fprintf(fp, "    \"occurrences_limit\": %d,\n", MAX_OCCURS);
        }
        // 真·声明行：occurrences 是遍历序，第一条既不是声明也不是最小行，
        // 下游拿 occurrences[0].line 当声明会指错行。这里直接给定义那条。
        for (int i = 0; i < var->occur_count; i++) {
            if (var->occurs[i].is_definition != 1) continue;
            char df[1024], dfu[512];
            json_escape(df, var->occurs[i].file ? var->occurs[i].file : "", sizeof(df));
            json_escape(dfu, var->occurs[i].func ? var->occurs[i].func : "", sizeof(dfu));
            fprintf(fp, "    \"decl\": {\"file\":\"%s\",\"func\":\"%s\",\"line\":%d},\n",
                    df, dfu, var->occurs[i].line);
            break;
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
        fprintf(fp, "\n    ]");
        // 跨过程跳：之前这些边只活在查询侧的一次 strstr 猜测里，进不了盘。
        if (var->hop_count > 0) {
            fprintf(fp, ",\n    \"hops\": [\n");
            static const char* scope_names[4] = {"external", "local", "global", "ambiguous"};
            for (int i = 0; i < var->hop_count; i++) {
                hop_t* h = &var->hops[i];
                char ec[512], ee[512], ef[1024], ep[128], ed[1024];
                json_escape(ec, h->caller, sizeof(ec));
                json_escape(ee, h->callee, sizeof(ee));
                json_escape(ef, h->file, sizeof(ef));
                json_escape(ep, h->param, sizeof(ep));
                json_escape(ed, h->def, sizeof(ed));
                fprintf(fp, "%s      {\"caller\":\"%s\",\"callee\":\"%s\",\"file\":\"%s\","
                            "\"line\":%d,\"pos\":%d,\"param\":\"%s\",\"scope\":\"%s\"",
                        i ? ",\n" : "", ec, ee, ef, h->line, h->pos, ep,
                        scope_names[h->scope & 3]);
                if (h->def[0]) fprintf(fp, ",\"def\":\"%s\"", ed);
                if (h->defs > 0) fprintf(fp, ",\"defs\":%d", h->defs);
                fprintf(fp, "}");
            }
            fprintf(fp, "\n    ]");
        }
        fprintf(fp, "\n  }");
    }
    fprintf(fp, "\n}\n");
    fclose(fp);
}

// ============================================
// 主函数
// ============================================

// 进程内复用：lite 是长驻进程，同一个 .so 里 dataflow 会被反复处理（lens build 每轮一次）。
// 旧版这些 static 表既没有收尾也没有入口清零，第二次进来变量表还留着上一轮的记录 →
// occurrences 成倍重复、dataflow.json 一轮比一轮大（现场：72 行 → 78 行，`a` 的赋值出现两条）。
// 统一 free + 置 NULL，analyze/show 入口各调一次；CLI 单次进程里多这一步也无害。
static void dataflow_globals_reset(void) {
    for (int i = 0; i < g_var_count; i++) {
        free(g_vars[i].occurs);
        free(g_vars[i].fields);
        free(g_vars[i].hops);
    }
    free(g_vars); g_vars = NULL;
    g_var_count = 0;
    g_var_capacity = 0;

    free(g_var_hash); g_var_hash = NULL;
    g_var_hash_size = 0;
    g_var_hash_used = 0;

    if (g_param_hash) {
        for (size_t i = 0; i < PARAM_HASH_SIZE; i++) {
            func_param_t* p = g_param_hash[i];
            while (p) { func_param_t* nx = p->next; free(p); p = nx; }
        }
        free(g_param_hash); g_param_hash = NULL;
    }

    if (g_caller_hash) {
        for (size_t i = 0; i < CALLER_HASH_SIZE; i++) {
            edge_node_t* n = g_caller_hash[i];
            while (n) { edge_node_t* nx = n->next; free(n); n = nx; }
        }
        free(g_caller_hash); g_caller_hash = NULL;
    }

    free(g_call_graph.edges); g_call_graph.edges = NULL;
    g_call_graph.edge_count = 0;
    g_call_graph.capacity = 0;

    memset(g_langs, 0, sizeof(g_langs));
    g_lang_count = 0;
    g_funcs_total = 0;
    g_hop_total = 0;
}

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
        dataflow_globals_reset();
        if (analyze_meta(meta_file) != 0) return 1;
        
        load_call_graph(cache_dir);
        build_hops();
        
        save_dataflow(out_file);
        write_dataflow_meta(cache_dir);
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
        dataflow_globals_reset();
        if (analyze_meta(meta_file) != 0) return 1;
        
        load_call_graph(cache_dir);
        build_hops();
        
        print_dataflow(var_name);
        
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
    
    return 0;
}
