#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "cs_compat.h"

#define MAX_NAME_LEN 256
#define MAX_FUNC 1200000
#define HASH_SIZE 2097151
static char** g_func_names = NULL;
static int g_func_count = 0;

static int g_name_hash[HASH_SIZE];  // -1 = empty
#define MAX_ARGS 20

// =============================================================================
// Noise symbol filter: suppress JS/TS builtins and Effect-TS combinators
// so the call graph highlights business logic instead of infrastructure.
// =============================================================================

static const char* NOISE_SYMBOLS[] = {
    // JavaScript / Node.js globals and constructors
    "Array", "ArrayBuffer", "Boolean", "Buffer", "DataView", "Date", "Error",
    "Function", "Infinity", "JSON", "Map", "Math", "NaN", "Number", "Object",
    "Promise", "Proxy", "RangeError", "ReferenceError", "RegExp", "Set",
    "String", "Symbol", "TypeError", "URIError", "WeakMap", "WeakSet",
    "console", "exports", "global", "globalThis", "module", "process",
    "require", "undefined",

    // Array static and prototype methods
    "Array.from", "Array.isArray", "Array.of",
    "at", "concat", "copyWithin", "entries", "every", "fill", "filter", "find",
    "findIndex", "findLast", "findLastIndex", "flat", "flatMap", "forEach",
    "includes", "indexOf", "join", "keys", "lastIndexOf", "map", "pop", "push",
    "reduce", "reduceRight", "reverse", "shift", "slice", "some", "sort",
    "splice", "toLocaleString", "toString", "unshift", "values",

    // Object static methods
    "Object.assign", "Object.create", "Object.defineProperties", "Object.defineProperty",
    "Object.entries", "Object.freeze", "Object.fromEntries", "Object.getOwnPropertyDescriptor",
    "Object.getOwnPropertyDescriptors", "Object.getOwnPropertyNames", "Object.getOwnPropertySymbols",
    "Object.getPrototypeOf", "Object.hasOwn", "Object.is", "Object.isExtensible",
    "Object.isFrozen", "Object.isSealed", "Object.keys", "Object.preventExtensions",
    "Object.seal", "Object.setPrototypeOf", "Object.values",

    // JSON / console / Promise
    "JSON.parse", "JSON.stringify",
    "Promise.all", "Promise.allSettled", "Promise.any", "Promise.race", "Promise.reject", "Promise.resolve",
    "console.debug", "console.error", "console.info", "console.log", "console.trace", "console.warn",

    // String / Number / Math / Date / RegExp prototype methods (commonly called unqualified)
    "charAt", "charCodeAt", "codePointAt", "endsWith", "fromCharCode",
    "match", "matchAll", "normalize", "padEnd", "padStart", "repeat", "replace",
    "replaceAll", "search", "split", "startsWith", "substring", "substr",
    "toLowerCase", "toUpperCase", "trim", "trimEnd", "trimStart",
    "isFinite", "isInteger", "isNaN", "isSafeInteger", "parseFloat", "parseInt",
    "toFixed", "toPrecision",
    "abs", "ceil", "floor", "max", "min", "pow", "random", "round", "sqrt", "trunc",
    "getDate", "getDay", "getFullYear", "getHours", "getMilliseconds", "getMinutes",
    "getMonth", "getSeconds", "getTime", "getTimezoneOffset", "getUTCDate",
    "toISOString", "toUTCString",
    "exec", "test",

    // Map / Set / Promise prototype methods
    "add", "clear", "delete", "forEach", "get", "has", "set", "size",
    "catch", "finally", "then",

    // Timers / process
    "setTimeout", "clearTimeout", "setInterval", "clearInterval", "setImmediate",
    "process.cwd", "process.env", "process.exit", "process.nextTick",

    // Effect-TS core combinators and namespaces
    "Effect", "Effect.acquireUseRelease", "Effect.all", "Effect.andThen", "Effect.annotateLogs", "Effect.as",
    "Effect.bind", "Effect.bindTo", "Effect.catch", "Effect.catchAll", "Effect.catchSome", "Effect.catchTag", "Effect.catchTags",
    "Effect.die", "Effect.either", "Effect.fail", "Effect.filter", "Effect.flatMap", "Effect.fn",
    "Effect.fork", "Effect.forever", "Effect.fromNullable", "Effect.gen", "Effect.if",
    "Effect.ignore", "Effect.iterate", "Effect.join", "Effect.let", "Effect.log", "Effect.logError",
    "Effect.map", "Effect.mapBoth", "Effect.mapError", "Effect.mergeAll", "Effect.never",
    "Effect.onExit", "Effect.orDie", "Effect.optionFromOptional", "Effect.provide",
    "Effect.provideLayer", "Effect.provideService", "Effect.provideServiceEffect",
    "Effect.promise", "Effect.race", "Effect.raceAll", "Effect.repeat", "Effect.retry",
    "Effect.runFork", "Effect.runPromise", "Effect.runPromiseExit", "Effect.runSync",
    "Effect.schedule", "Effect.scoped", "Effect.sleep", "Effect.succeed", "Effect.sync",
    "Effect.tap", "Effect.tapBoth", "Effect.tapError", "Effect.timeout", "Effect.try",
    "Effect.tryPromise", "Effect.unified", "Effect.void", "Effect.withSpan", "Effect.zip",
    "Effect.zipLeft", "Effect.zipRight", "Effect.zipWith",
    "Context", "Context.Service", "Context.Tag", "Context.add", "Context.get",
    "Context.make", "Context.merge", "Context.empty",
    "Layer", "Layer.effect", "Layer.merge", "Layer.provide", "Layer.succeed",
    "Layer.sync", "Layer.toRuntime",
    "Ref", "Ref.get", "Ref.make", "Ref.set", "Ref.update", "Ref.updateAndGet",
    "Option", "Option.flatMap", "Option.fromNullable", "Option.getOrElse",
    "Option.getOrThrow", "Option.map", "Option.none", "Option.orElse", "Option.some",
    "Either", "Either.flatMap", "Either.left", "Either.map", "Either.match",
    "Either.right", "Either.void",
    "Schema", "Schema.Array", "Schema.Boolean", "Schema.Class", "Schema.Date",
    "Schema.Literal", "Schema.Number", "Schema.Record", "Schema.String", "Schema.Struct",
    "Schema.Tuple", "Schema.Union", "Schema.decode", "Schema.decodeUnknown",
    "Schema.encode", "Schema.encodeUnknown", "Schema.optional", "Schema.parseJson",
    "pipe",

    // Node.js modules and Web APIs
    "Buffer.alloc", "Buffer.concat", "Buffer.from", "Buffer.isBuffer",
    "fetch",
    "path.basename", "path.dirname", "path.extname", "path.format", "path.isAbsolute",
    "path.join", "path.normalize", "path.parse", "path.relative", "path.resolve",
    "child_process.exec", "child_process.execFile", "child_process.execFileSync",
    "child_process.execSync", "child_process.fork", "child_process.spawn",
    "fs.access", "fs.accessSync", "fs.appendFile", "fs.appendFileSync", "fs.copyFile",
    "fs.copyFileSync", "fs.cp", "fs.cpSync", "fs.existsSync", "fs.mkdir", "fs.mkdirSync",
    "fs.readFile", "fs.readFileSync", "fs.readdir", "fs.readdirSync", "fs.rename",
    "fs.renameSync", "fs.rm", "fs.rmSync", "fs.rmdir", "fs.rmdirSync", "fs.stat",
    "fs.statSync", "fs.writeFile", "fs.writeFileSync",

    // Common unqualified helpers that produce noise
    "entries", "keys", "values", "has", "get", "set", "delete", "clear", "add",
    "map", "filter", "reduce", "forEach", "find", "some", "every", "includes",
    "join", "split", "trim", "replace", "startsWith", "endsWith", "push", "pop",
    "shift", "unshift", "slice", "splice", "sort", "reverse", "concat", "flatMap",
    "then", "catch", "finally",
    "log", "error", "warn",
};

static int is_noise_symbol(const char* name) {
    if (!name || !name[0]) return 1;

    // Reject anonymous / literal / template / dynamic expressions
    for (const char* p = name; *p; p++) {
        char c = *p;
        if (c == '(' || c == ')' || c == '[' || c == ']' ||
            c == '{' || c == '}' || c == '`' || c == '$' ||
            c == '"' || c == '\'') {
            return 1;
        }
    }

    // Reject leading/trailing whitespace or pure whitespace
    const char* p = name;
    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p) return 1;

    int n = sizeof(NOISE_SYMBOLS) / sizeof(NOISE_SYMBOLS[0]);
    for (int i = 0; i < n; i++) {
        if (strcmp(NOISE_SYMBOLS[i], name) == 0) return 1;
    }

    // 启发式过滤（治 LuaJIT 等宏污染扇入排名）：
    //   ① 长度 < 3 的符号（调试宏 dd、单双字母）基本不是函数调用目标；
    //   ② 全大写（A-Z/0-9/_）标识符视为宏（LJLIB_CF/LJFOLD/LJLIB_REC…），非函数。
    {
        int len = (int)strlen(name);
        if (len < 3) return 1;
        int has_lower = 0;
        for (const char* q = name; *q; q++) {
            if (*q >= 'a' && *q <= 'z') { has_lower = 1; break; }
        }
        if (!has_lower) return 1;
    }
    return 0;
}

typedef struct call_edge {
    char caller[MAX_NAME_LEN];
    char file[512];
    int line;
    char args[1024];
    // 间接/成员调用标注（2026-11-10）：调用点是 `obj->fn()` / `obj.fn()` 时，
    // 唯一能拿到的线索是接收者表达式（via）；标出来让查询侧能把它和直接调用区分开，
    // 否则 `i_fop->write_iter()` 与真的 `write_iter()` 调用在图里长得一模一样。
    char via[MAX_NAME_LEN];
    int indirect;
    // 跨文件符号解析（2026-11-13）：def = 这条边落到哪个定义文件（仅 local/global），
    // ambiguous/defs = 同名多份非 static 定义、又没能按文件收敛，不能当成精确边。
    char def[512];
    int scope;   // SCOPE_EXTERNAL / LOCAL / GLOBAL / AMBIGUOUS
    int defs;    // 候选定义数（ambiguous 时是"几份实现混在这里"）
    struct call_edge* next;
} call_edge_t;

typedef struct func_node {
    char name[MAX_NAME_LEN];
    call_edge_t* calls;
    struct func_node* next;
} func_node_t;

static func_node_t* g_func_nodes = NULL;
static int g_scope_count[4] = {0, 0, 0, 0};

// Go/C++ 裸名 -> 唯一作用域名（用于把跨包/跨类的调用边挂回 scoped symbol）
typedef struct {
    char bare[MAX_NAME_LEN];
    char scoped[MAX_NAME_LEN];
    int ambiguous;
} bare_entry_t;
static bare_entry_t* g_bares = NULL;
static int g_bare_hash[HASH_SIZE];
static int g_bare_count = 0;

// =============================================================================
// 定义表（2026-11-13）：name -> 定义点列表 {file, is_static}
//
// 旧行为：调用图节点/边只按裸名解析，`static int open(...)` 在 20 个 .c 里各有一份时，
// 所有调用点被糊成同一条 `open` 边，`context` 出来的「谁调用它」跨文件互相污染
// （内核 arch/ 那份 142 条扇入就是这么来的）。定义表让每条边至少知道自己落在
// 哪个定义上：同文件定义优先（C 的 static 语义），否则取唯一的非 static 定义，
// 多份非 static 定义则标 ambiguous，绝不静默合并。
// =============================================================================
#define DEF_HASH_SIZE 262147
#define MAX_DEFS_PER_NAME 32

typedef struct def_rec {
    const char* file;   // 指向 file 池（interned），不单独 free
    int is_static;
    int is_header;      // .h/.hpp/... 里的 `static inline` 对所有包含者可见
} def_rec_t;

typedef struct def_list {
    char* name;
    def_rec_t recs[MAX_DEFS_PER_NAME];
    int count;
    struct def_list* next;
} def_list_t;

static def_list_t** g_def_hash = NULL;

// file 池：同一条边/同一个函数共用一份路径字符串，避免 120 万 chunk 各 strdup 一遍。
typedef struct file_node {
    char* path;
    struct file_node* next;
} file_node_t;
static file_node_t** g_file_hash = NULL;

static unsigned int hash_str_n(const char* s, unsigned int mod) {
    unsigned int h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)*s++;
    return h % mod;
}

static const char* intern_file(const char* path) {
    if (!path || !*path) return "";
    if (!g_file_hash) {
        g_file_hash = calloc(DEF_HASH_SIZE, sizeof(file_node_t*));
        if (!g_file_hash) return path;
    }
    unsigned int h = hash_str_n(path, DEF_HASH_SIZE);
    for (file_node_t* n = g_file_hash[h]; n; n = n->next) {
        if (strcmp(n->path, path) == 0) return n->path;
    }
    file_node_t* n = malloc(sizeof(file_node_t));
    if (!n) return path;
    n->path = strdup(path);
    if (!n->path) { free(n); return path; }
    n->next = g_file_hash[h];
    g_file_hash[h] = n;
    return n->path;
}

// 签名里 `static` 才算文件内定义：只看第一行，且必须出现在函数名之前
// （函数体里的 `static int x` 是局部静态变量，不算）。
static int def_is_static(const char* content, const char* name) {
    if (!content || !name || !*name) return 0;
    const char* nl = strchr(content, '\n');
    const char* sig_end = nl ? nl : content + strlen(content);
    size_t nlen = strlen(name);
    const char* nm = sig_end;
    for (const char* p = content; p < sig_end && p; p = strstr(p, name)) {
        int left_ok = (p == content) || !(isalnum((unsigned char)p[-1]) || p[-1] == '_');
        int right_ok = !(isalnum((unsigned char)p[nlen]) || p[nlen] == '_');
        if (left_ok && right_ok) { nm = p; break; }
        p += nlen;
        if (p >= sig_end) break;
    }
    for (const char* q = content; q + 6 <= nm; q++) {
        if (strncmp(q, "static", 6) == 0 &&
            (q == content || !(isalnum((unsigned char)q[-1]) || q[-1] == '_')) &&
            !(isalnum((unsigned char)q[6]) || q[6] == '_')) {
            return 1;
        }
    }
    return 0;
}

// 头文件里的定义对所有包含者可见（`static inline` 助手），不能当文件内符号处理。
static int is_header_path(const char* file) {
    static const char* EXTS[] = { ".h", ".hpp", ".hh", ".hxx", ".inc", ".inl", ".ipp" };
    size_t n = strlen(file);
    for (size_t i = 0; i < sizeof(EXTS) / sizeof(EXTS[0]); i++) {
        size_t e = strlen(EXTS[i]);
        if (n > e && strcmp(file + n - e, EXTS[i]) == 0) return 1;
    }
    return 0;
}

static void add_def(const char* name, const char* file, int is_static) {
    if (!name || !*name || !file || !*file) return;
    if (!g_def_hash) {
        g_def_hash = calloc(DEF_HASH_SIZE, sizeof(def_list_t*));
        if (!g_def_hash) return;
    }
    unsigned int h = hash_str_n(name, DEF_HASH_SIZE);
    def_list_t* d = g_def_hash[h];
    while (d && strcmp(d->name, name) != 0) d = d->next;
    if (!d) {
        d = calloc(1, sizeof(def_list_t));
        if (!d) return;
        d->name = strdup(name);
        if (!d->name) { free(d); return; }
        d->next = g_def_hash[h];
        g_def_hash[h] = d;
    }
    for (int i = 0; i < d->count; i++) {
        if (strcmp(d->recs[i].file, file) == 0) {
            // 同一文件里同名多份（重载/嵌套/分 Part）：非 static 优先
            if (!is_static) d->recs[i].is_static = 0;
            return;
        }
    }
    if (d->count >= MAX_DEFS_PER_NAME) return;   // 溢出保护，别越界
    d->recs[d->count].file = intern_file(file);
    d->recs[d->count].is_static = is_static;
    d->recs[d->count].is_header = is_header_path(file);
    d->count++;
}

// 解析结果：0=external(索引里没有定义/只有别的文件的 static) 1=local 2=global 3=ambiguous
enum { SCOPE_EXTERNAL = 0, SCOPE_LOCAL = 1, SCOPE_GLOBAL = 2, SCOPE_AMBIGUOUS = 3 };

// 按 caller 文件解析 tok 指向哪个定义。def_out 只在 local/global 时写入。
static int resolve_def(const char* caller_file, const char* tok,
                       char* def_out, size_t defsz, int* def_count_out) {
    def_out[0] = '\0';
    if (def_count_out) *def_count_out = 0;
    if (!g_def_hash || !tok || !*tok) return SCOPE_EXTERNAL;
    unsigned int h = hash_str_n(tok, DEF_HASH_SIZE);
    def_list_t* d = g_def_hash[h];
    while (d && strcmp(d->name, tok) != 0) d = d->next;
    if (!d || d->count == 0) return SCOPE_EXTERNAL;

    // ① 同文件定义：C 的 static 只在文件内可见，Python/JS 的同名嵌套函数同理。
    if (caller_file && *caller_file) {
        for (int i = 0; i < d->count; i++) {
            if (strcmp(d->recs[i].file, caller_file) == 0) {
                snprintf(def_out, defsz, "%s", caller_file);
                if (def_count_out) *def_count_out = d->count;
                return SCOPE_LOCAL;
            }
        }
    }
    // ② 唯一可见定义：非 static 的 .c 定义，或头文件里的 static inline。
    //    头文件里的 static inline 对所有包含者可见，所以也算「可见」，不按 static 丢弃。
    const char* only = NULL;
    int visible = 0;
    for (int i = 0; i < d->count; i++) {
        if (!d->recs[i].is_static || d->recs[i].is_header) {
            visible++;
            only = d->recs[i].file;
        }
    }
    if (visible == 1) {
        snprintf(def_out, defsz, "%s", only);
        if (def_count_out) *def_count_out = d->count;
        return SCOPE_GLOBAL;
    }
    // ③ 多份可见定义：不能静默合并，交查询侧标注。
    if (visible > 1) {
        if (def_count_out) *def_count_out = visible;
        return SCOPE_AMBIGUOUS;
    }
    // 只剩别的文件里的 static 非头定义：这个调用点不可能落到它们身上（static 无外部可见性）。
    if (def_count_out) *def_count_out = d->count;
    return SCOPE_EXTERNAL;
}

typedef struct plugin_edge {
    char caller[MAX_NAME_LEN];
    char callee[MAX_NAME_LEN];
    char file[512];
    int line;
} plugin_edge_t;

static plugin_edge_t* g_plugin_edges = NULL;
static int g_plugin_edge_count = 0;
static int g_plugin_edge_capacity = 0;

// DJB2 hash
static unsigned int hash_str(const char* s) {
    unsigned int h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)*s++;
    return h % HASH_SIZE;
}

static void add_func_name(const char* name) {
    if (is_noise_symbol(name)) return;
    if (g_func_count >= MAX_FUNC) return;  // 溢出保护（旧版无检查，300k 后堆越界静默损坏）
    unsigned int h = hash_str(name);
    while (g_name_hash[h] >= 0) {
        if (strcmp(g_func_names[g_name_hash[h]], name) == 0) return;
        h = (h + 1) % HASH_SIZE;
    }
    g_func_names[g_func_count] = strdup(name);
    g_name_hash[h] = g_func_count;
    g_func_count++;
    // C++ 兼容（2026-09-17）：同时注册裸方法名——chunks 里是 Class::method，
    // 但调用点写的是 obj.method( / obj->method(，token 只有裸名。
    // 不注册裸名则 C++ 类方法的调用边全丢（percona 实测：79k 边 vs 应有 ~500k）。
    const char* sep = strstr(name, "::");
    if (sep && sep[2]) {
        const char* bare = sep + 2;
        if (g_bares && g_bare_count < MAX_FUNC) {
            unsigned int bh = hash_str(bare);
            while (g_bare_hash[bh] >= 0 &&
                   strcmp(g_bares[g_bare_hash[bh]].bare, bare) != 0) {
                bh = (bh + 1) % HASH_SIZE;
            }
            if (g_bare_hash[bh] < 0) {
                bare_entry_t* e = &g_bares[g_bare_count];
                strncpy(e->bare, bare, MAX_NAME_LEN - 1);
                e->bare[MAX_NAME_LEN - 1] = '\0';
                strncpy(e->scoped, name, MAX_NAME_LEN - 1);
                e->scoped[MAX_NAME_LEN - 1] = '\0';
                e->ambiguous = 0;
                g_bare_hash[bh] = g_bare_count++;
            } else if (strcmp(g_bares[g_bare_hash[bh]].scoped, name) != 0) {
                g_bares[g_bare_hash[bh]].ambiguous = 1;
            }
        }
        add_func_name(bare);
    }
}

static int is_func_known(const char* name) {
    unsigned int h = hash_str(name);
    while (g_name_hash[h] >= 0) {
        if (strcmp(g_func_names[g_name_hash[h]], name) == 0) return 1;
        h = (h + 1) % HASH_SIZE;
    }
    return 0;
}

// Go/C++ 作用域解析：调用点只有裸名，优先绑定到 caller 的 pkg/类作用域，
// 例如 control.turnOrchestrator::runTurnLoop 内的 foo() -> 同作用域 foo。
static const char* unique_scoped(const char* bare) {
    if (!g_bares) return NULL;
    unsigned int h = hash_str(bare);
    while (g_bare_hash[h] >= 0) {
        bare_entry_t* e = &g_bares[g_bare_hash[h]];
        if (strcmp(e->bare, bare) == 0) {
            return e->ambiguous ? NULL : e->scoped;
        }
        h = (h + 1) % HASH_SIZE;
    }
    return NULL;
}

static void resolve_callee(const char* caller, const char* tok, char* out, size_t outsz) {
    const char* sep = strstr(caller, "::");
    if (sep && sep > caller) {
        int n = snprintf(out, outsz, "%.*s::%s", (int)(sep - caller), caller, tok);
        if (n > 0 && (size_t)n < outsz && is_func_known(out)) return;
    }
    const char* scoped = unique_scoped(tok);
    if (scoped && is_func_known(scoped)) {
        snprintf(out, outsz, "%s", scoped);
        return;
    }
    snprintf(out, outsz, "%s", tok);
}

// 旧实现每次 add_call_edge 都线性扫全部 call graph 节点（O(edges×functions)，
// 内核这种百万 chunk 规模会拖到 10 分钟）。用和 g_name_hash 同尺寸的开放寻址表。
static func_node_t** g_node_hash = NULL;

static func_node_t* get_func_node(const char* name, int create) {
    if (!g_node_hash) {
        g_node_hash = calloc(HASH_SIZE, sizeof(func_node_t*));
        if (!g_node_hash) return NULL;
    }
    unsigned int h = hash_str(name) % HASH_SIZE;
    while (g_node_hash[h] && strcmp(g_node_hash[h]->name, name) != 0) {
        h = (h + 1) % HASH_SIZE;
    }
    if (g_node_hash[h]) return g_node_hash[h];
    if (!create) return NULL;

    func_node_t* n = malloc(sizeof(func_node_t));
    if (!n) return NULL;
    strncpy(n->name, name, MAX_NAME_LEN - 1);
    n->name[MAX_NAME_LEN - 1] = '\0';
    n->calls = NULL;
    n->next = g_func_nodes;
    g_func_nodes = n;
    g_node_hash[h] = n;
    return n;
}

static void add_call_edge(const char* callee, const char* caller, const char* file, int line,
                          const char* args, const char* via);

static void store_plugin_edge(const char* caller, const char* callee, const char* file, int line) {
    if (g_plugin_edge_count >= g_plugin_edge_capacity) {
        int new_cap = g_plugin_edge_capacity == 0 ? 4096 : g_plugin_edge_capacity * 2;
        plugin_edge_t* new_arr = realloc(g_plugin_edges, new_cap * sizeof(plugin_edge_t));
        if (!new_arr) return;
        g_plugin_edges = new_arr;
        g_plugin_edge_capacity = new_cap;
    }
    plugin_edge_t* e = &g_plugin_edges[g_plugin_edge_count++];
    strncpy(e->caller, caller, MAX_NAME_LEN - 1);
    e->caller[MAX_NAME_LEN - 1] = '\0';
    strncpy(e->callee, callee, MAX_NAME_LEN - 1);
    e->callee[MAX_NAME_LEN - 1] = '\0';
    strncpy(e->file, file ? file : "", sizeof(e->file) - 1);
    e->file[sizeof(e->file) - 1] = '\0';
    e->line = line;
}

static void apply_plugin_edges() {
    int applied = 0;
    int skipped = 0;
    for (int i = 0; i < g_plugin_edge_count; i++) {
        plugin_edge_t* e = &g_plugin_edges[i];
        if (is_func_known(e->callee) && !is_noise_symbol(e->callee) && !is_noise_symbol(e->caller)) {
            add_call_edge(e->callee, e->caller, e->file, e->line, "", NULL);
            applied++;
        } else {
            skipped++;
        }
    }
    printf("  Applied %d plugin edges, skipped %d external/noise\n", applied, skipped);
}

static void add_call_edge(const char* callee, const char* caller, const char* file, int line,
                          const char* args, const char* via) {
    if (is_noise_symbol(callee) || is_noise_symbol(caller)) return;
    func_node_t* node = get_func_node(callee, 1);
    if (!node) return;

    // Deduplicate identical caller/file/line
    call_edge_t* e = node->calls;
    while (e) {
        if (strcmp(e->caller, caller) == 0 && strcmp(e->file, file) == 0 && e->line == line) return;
        e = e->next;
    }

    e = malloc(sizeof(call_edge_t));
    if (!e) return;
    strncpy(e->caller, caller, MAX_NAME_LEN - 1);
    e->caller[MAX_NAME_LEN - 1] = '\0';
    strncpy(e->file, file ? file : "", sizeof(e->file) - 1);
    e->file[sizeof(e->file) - 1] = '\0';
    e->line = line;
    strncpy(e->args, args ? args : "", sizeof(e->args) - 1);
    e->args[sizeof(e->args) - 1] = '\0';
    e->via[0] = '\0';
    if (via && via[0]) {
        strncpy(e->via, via, MAX_NAME_LEN - 1);
        e->via[MAX_NAME_LEN - 1] = '\0';
        e->indirect = 1;
    } else {
        e->indirect = 0;
    }
    // 跨文件解析：边落在哪个定义上（local 优先，其次唯一可见定义，多份则标 ambiguous）
    {
        char def[512];
        int defs = 0;
        e->scope = resolve_def(file, callee, def, sizeof(def), &defs);
        e->defs = defs;
        snprintf(e->def, sizeof(e->def), "%s", def);
    }
    e->next = node->calls;
    node->calls = e;
}

static int is_func_kind(const char* kind) {
    return kind[0] && (
        strcmp(kind, "function") == 0 ||
        strcmp(kind, "method") == 0 ||
        strcmp(kind, "func") == 0 ||
        strcmp(kind, "methodSpec") == 0 ||
        strcmp(kind, "ts_function") == 0 ||
        strcmp(kind, "ts_method") == 0
    );
}

// Extract value of a JSON string field (handles simple escaped chars)
static int json_extract_str(const char* json, const char* key, char* out, int max_len) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);
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
    while (*p && isdigit((unsigned char)*p)) {
        val = val * 10 + (*p - '0');
        p++;
    }
    return val;
}

// 在内容中查找函数调用，并提取参数
static int __attribute__((unused)) find_call_with_args(const char* content, const char* func_name,
                                char* args_out, int args_out_size) {
    int len = (int)strlen(func_name);
    const char* p = content;
    args_out[0] = '\0';

    while ((p = strstr(p, func_name)) != NULL) {
        if (p > content) {
            char c = *(p - 1);
            if (isalnum(c) || c == '_' || c == ':') {
                p += len;
                continue;
            }
        }

        const char* after = p + len;
        while (*after && isspace((unsigned char)*after)) after++;

        if (*after == '(') {
            after++;
            int depth = 1;
            int arg_idx = 0;
            char arg[MAX_ARGS][128];
            int arg_len = 0;
            int in_string = 0;
            char string_char = 0;

            while (*after && depth > 0 && arg_idx < MAX_ARGS) {
                if (!in_string && (*after == '"' || *after == '\'')) {
                    in_string = 1;
                    string_char = *after;
                    after++;
                    continue;
                }
                if (in_string && *after == string_char) {
                    in_string = 0;
                    after++;
                    continue;
                }
                if (in_string) {
                    after++;
                    continue;
                }

                if (*after == '(') {
                    depth++;
                } else if (*after == ')') {
                    depth--;
                    if (depth == 0) break;
                } else if (*after == ',' && depth == 1) {
                    if (arg_len > 0) {
                        arg[arg_idx][arg_len] = '\0';
                        arg_idx++;
                        arg_len = 0;
                    }
                    after++;
                    continue;
                }

                if (arg_len < 127 && depth == 1) {
                    arg[arg_idx][arg_len++] = *after;
                }
                after++;
            }

            if (arg_len > 0 && arg_idx < MAX_ARGS) {
                arg[arg_idx][arg_len] = '\0';
                arg_idx++;
            }

            int pos = 0;
            for (int i = 0; i < arg_idx && pos < args_out_size - 1; i++) {
                char* start = arg[i];
                while (*start && isspace((unsigned char)*start)) start++;
                char* end = start + strlen(start) - 1;
                while (end > start && isspace((unsigned char)*end)) *end-- = '\0';

                if (strlen(start) > 0) {
                    int alen = (int)strlen(start);
                    if (pos + alen + 3 < args_out_size) {
                        if (pos > 0) {
                            args_out[pos++] = ',';
                            args_out[pos++] = ' ';
                        }
                        strcpy(args_out + pos, start);
                        pos += alen;
                    }
                }
            }
            args_out[pos] = '\0';
            return 1;
        }

        p += len;
    }

    return 0;
}

// 从当前调用点的 '(' 之后解析参数，避免为每个 callee 重新 strstr 整个 body。
static void extract_call_args(const char* after, char* args_out, int args_out_size) {
    int depth = 1;
    int arg_idx = 0;
    int arg_len = 0;
    int in_string = 0;
    char string_char = 0;
    char arg[MAX_ARGS][128];
    args_out[0] = '\0';

    while (*after && depth > 0 && arg_idx < MAX_ARGS) {
        if (!in_string && (*after == '"' || *after == '\'')) {
            in_string = 1;
            string_char = *after;
            after++;
            continue;
        }
        if (in_string && *after == string_char) {
            in_string = 0;
            after++;
            continue;
        }
        if (in_string) { after++; continue; }

        if (*after == '(') {
            depth++;
        } else if (*after == ')') {
            depth--;
            if (depth == 0) break;
        } else if (*after == ',' && depth == 1) {
            if (arg_len > 0) {
                arg[arg_idx][arg_len] = '\0';
                arg_idx++;
                arg_len = 0;
            }
            after++;
            continue;
        }

        if (arg_len < 127 && depth == 1) arg[arg_idx][arg_len++] = *after;
        after++;
    }

    if (arg_len > 0 && arg_idx < MAX_ARGS) {
        arg[arg_idx][arg_len] = '\0';
        arg_idx++;
    }

    int pos = 0;
    for (int i = 0; i < arg_idx && pos < args_out_size - 1; i++) {
        char* start = arg[i];
        while (*start && isspace((unsigned char)*start)) start++;
        char* end = start + strlen(start) - 1;
        while (end > start && isspace((unsigned char)*end)) *end-- = '\0';
        int alen = (int)strlen(start);
        if (alen == 0) continue;
        if (pos + alen + 3 < args_out_size) {
            if (pos > 0) { args_out[pos++] = ','; args_out[pos++] = ' '; }
            strcpy(args_out + pos, start);
            pos += alen;
        }
    }
    args_out[pos] = '\0';
}

static void load_plugin_edges(const char* plugin_file) {
    FILE* fp = fopen(plugin_file, "r");
    if (!fp) return;

    char* line = NULL;
    size_t line_len = 0;
    int count = 0;

    while (getline(&line, &line_len, fp) != -1) {
        char type[32] = {0};
        json_extract_str(line, "type", type, sizeof(type));
        if (strcmp(type, "call_edge") != 0) continue;

        char caller[MAX_NAME_LEN] = {0};
        char callee[MAX_NAME_LEN] = {0};
        char file[512] = {0};

        json_extract_str(line, "caller", caller, sizeof(caller));
        json_extract_str(line, "callee", callee, sizeof(callee));
        json_extract_str(line, "caller_file", file, sizeof(file));
        int line_num = json_extract_int(line, "caller_line");

        if (!caller[0] || !callee[0]) continue;

        store_plugin_edge(caller, callee, file, line_num);
        count++;
    }

    free(line);
    fclose(fp);
    printf("  Loaded %d call edges from plugin output\n", count);
}


// 返回合法 UTF-8 序列长度；非法返回 0（输出时替换为 '?'）。
static int utf8_len(const unsigned char* s, int remaining) {
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    int n;
    if ((c & 0xE0) == 0xC0) n = 2;
    else if ((c & 0xF0) == 0xE0) n = 3;
    else if ((c & 0xF8) == 0xF0) n = 4;
    else return 0;
    if (n > remaining) return 0;
    for (int i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) return 0;
    }
    return n;
}

static void json_escape_str(const char* src, char* dst, int max_len) {
    int j = 0;
    for (int i = 0; src[i] && j < max_len - 1; i++) {
        unsigned char c = src[i];
        if (c == '"' || c == '\\') {
            if (j + 2 < max_len) {
                dst[j++] = '\\';
                dst[j++] = c;
            }
        } else if (c == '\n') {
            if (j + 2 < max_len) { dst[j++] = '\\'; dst[j++] = 'n'; }
        } else if (c == '\r') {
            if (j + 2 < max_len) { dst[j++] = '\\'; dst[j++] = 'r'; }
        } else if (c == '\t') {
            if (j + 2 < max_len) { dst[j++] = '\\'; dst[j++] = 't'; }
        } else if (c < 0x20) {
            // skip control chars
        } else if (c < 0x80) {
            dst[j++] = c;
        } else {
            int n = utf8_len((const unsigned char*)(src + i), (int)strlen(src + i));
            if (n > 0 && j + n < max_len) {
                memcpy(dst + j, src + i, n);
                j += n;
                i += n - 1;
            } else {
                dst[j++] = '?';
            }
        }
    }
    dst[j] = '\0';
}

int lite_cs_callgraph_main(int argc, char** argv) {
    if (argc < 2) {
        printf("Call Graph Builder (Enhanced with TypeScript plugin support)\n");
        printf("Usage: %s <cache_dir>\n", argv[0]);
        return 1;
    }

    const char* cache_dir = argv[1];
    char meta_file[512], out_file[512], plugin_file[512];
    snprintf(meta_file, sizeof(meta_file), "%s/chunks_meta.jsonl", cache_dir);
    snprintf(out_file, sizeof(out_file), "%s/call_graph.json", cache_dir);
    snprintf(plugin_file, sizeof(plugin_file), "%s/plugin_output.jsonl", cache_dir);

    g_func_names = malloc(MAX_FUNC * sizeof(char*));
    if (!g_func_names) return 1;
    memset(g_name_hash, -1, sizeof(g_name_hash));
    g_bares = malloc((size_t)MAX_FUNC * sizeof(bare_entry_t));
    if (!g_bares) return 1;
    memset(g_bare_hash, -1, sizeof(g_bare_hash));

    printf("Phase 1: Loading functions and bodies\n");
    fflush(stdout);

    FILE* fp = fopen(meta_file, "r");
    if (!fp) {
        fprintf(stderr, "Failed to open %s\n", meta_file);
        return 1;
    }

    char* line = NULL;
    size_t line_len = 0;
    int processed_count = 0;
    int body_count = 0;

    typedef struct func_body {
        char name[MAX_NAME_LEN];
        char file[512];
        int line_start;
        char* content;
        struct func_body* next;
    } func_body_t;

    func_body_t* bodies = NULL;

    while (getline(&line, &line_len, fp) != -1) {
        char* name_p = strstr(line, "\"name\":\"");
        char* file_p = strstr(line, "\"file\":\"");
        char* kind_p = strstr(line, "\"kind\":\"");
        char* line_p = strstr(line, "\"line_start\":");
        char* content_p = strstr(line, "\"content\":\"");
        if (!name_p || !kind_p) continue;

        name_p += 8;
        kind_p += 8;
        char kind[64] = {0};
        int i = 0;
        while (*kind_p && *kind_p != '"' && i < 63) kind[i++] = *kind_p++;
        if (!is_func_kind(kind)) continue;

        char name[256] = {0};
        i = 0;
        while (*name_p && *name_p != '"' && i < 255) name[i++] = *name_p++;
        if (!name[0]) continue;

        add_func_name(name);
        processed_count++;

        if (file_p && content_p) {
            file_p += 8;
            char file[512] = {0};
            i = 0;
            while (*file_p && *file_p != '"' && i < 511) file[i++] = *file_p++;

            int line_start = line_p ? atoi(line_p + 13) : 0;
            content_p += 11;

            char* content = malloc(line_len);
            if (content) {
                const char* p = content_p;
                int j = 0;
                while (*p) {
                    if (*p == '\\' && *(p+1)) {
                        content[j++] = *(++p);
                        p++;
                    } else if (*p == '"') {
                        break;
                    } else {
                        content[j++] = *p++;
                    }
                }
                content[j] = '\0';

                func_body_t* b = malloc(sizeof(func_body_t));
                strncpy(b->name, name, MAX_NAME_LEN - 1);
                b->name[MAX_NAME_LEN - 1] = '\0';
                strncpy(b->file, file, sizeof(b->file) - 1);
                b->file[sizeof(b->file) - 1] = '\0';
                b->line_start = line_start;
                b->content = content;
                b->next = bodies;
                bodies = b;
                body_count++;
                // 定义表：name -> {file, static}，供边解析「这条边到底指向哪个定义」
                add_def(name, file, def_is_static(content, name));
            }
        }

        if (g_func_count >= MAX_FUNC) break;
    }
    fclose(fp);
    printf("  Found %d unique functions, loaded %d bodies\n", g_func_count, body_count);

    printf("Phase 2: Loading plugin call edges\n");
    load_plugin_edges(plugin_file);
    apply_plugin_edges();

    printf("Phase 3: Building call graph with arguments...\n");

    // Text-based call detection for bodies (backward compat + ctags)
    // 性能修复（2026-09-16）：旧实现 O(bodies × functions × strstr) ——
    // 115k chunks 需 ~10 分钟，147 万 chunks 估算数天（"卡死"）。
    // 新实现：每个 body 只扫一遍，tokenize 标识符 → is_func_known 哈希查找，
    // 命中且后跟 '(' 才调用 find_call_with_args 提参数 → O(总文本)。
    func_body_t* b = bodies;
    while (b) {
        // 每 body 去重小哈希（旧行为：同一 (callee, body) 只记一条边）
        unsigned int seen[256];
        memset(seen, 0, sizeof(seen));
        const char* p = b->content;
        while (*p) {
            if (isalpha((unsigned char)*p) || *p == '_') {
                const char* start = p;
                while (isalnum((unsigned char)*p) || *p == '_') p++;
                int tlen = (int)(p - start);
                if (tlen >= 2 && tlen < MAX_NAME_LEN) {
                    const char* q = p;
                    while (*q && isspace((unsigned char)*q)) q++;
                    if (*q == '(') {
                        char tok[MAX_NAME_LEN];
                        memcpy(tok, start, tlen);
                        tok[tlen] = '\0';
                        // 间接调用识别：token 前面是 `->` 或 `.` 时，调用点形如
                        // `obj->fn()` / `obj.fn()`，接收者（obj）是唯一可得的线索。
                        // 拿不到接收者（`arr[i].fn`、`(*o->f).fn`）也标 indirect，
                        // 只是 via 留空。不改挂边策略（仍按裸名解析），只加标注。
                        char via[MAX_NAME_LEN];
                        via[0] = '\0';
                        {
                            const char* r = start;
                            while (r > b->content && isspace((unsigned char)r[-1])) r--;
                            int back = (int)(r - b->content);
                            if (back >= 1 && r[-1] == '.') {
                                const char* end = r - 1;
                                const char* s = end;
                                while (s > b->content &&
                                       (isalnum((unsigned char)s[-1]) || s[-1] == '_')) s--;
                                if (end > s && (size_t)(end - s) < sizeof(via)) {
                                    memcpy(via, s, (size_t)(end - s));
                                    via[end - s] = '\0';
                                } else {
                                    via[0] = '#';
                                    via[1] = '\0';
                                }
                            } else if (back >= 2 && r[-1] == '>' && r[-2] == '-') {
                                const char* end = r - 2;
                                const char* s = end;
                                while (s > b->content &&
                                       (isalnum((unsigned char)s[-1]) || s[-1] == '_')) s--;
                                if (end > s && (size_t)(end - s) < sizeof(via)) {
                                    memcpy(via, s, (size_t)(end - s));
                                    via[end - s] = '\0';
                                } else {
                                    via[0] = '#';
                                    via[1] = '\0';
                                }
                            }
                        }
                        char callee[MAX_NAME_LEN];
                        resolve_callee(b->name, tok, callee, sizeof(callee));
                        if (strcmp(b->name, callee) != 0 && is_func_known(callee)) {
                            unsigned int sh = hash_str(callee) % 256;
                            int dup = 0, probes = 0;
                            while (seen[sh] && probes < 256) {
                                if (seen[sh] == hash_str(callee)) { dup = 1; break; }
                                sh = (sh + 1) % 256;
                                probes++;
                            }
                            if (!dup) {
                                seen[sh] = hash_str(callee);
                                char args[1024];
                                extract_call_args(q + 1, args, sizeof(args));
                                add_call_edge(callee, b->name, b->file, b->line_start, args, via);
                            }
                        }
                    }
                }
            } else {
                p++;
            }
        }
        b = b->next;
    }

    FILE* out = fopen(out_file, "w");
    if (!out) {
        fprintf(stderr, "Failed to create %s\n", out_file);
        return 1;
    }

    fprintf(out, "{\n");
    int first = 1;

    func_node_t* node = g_func_nodes;
    while (node) {
        if (!node->calls) { node = node->next; continue; }

        char esc_name[MAX_NAME_LEN * 2];
        json_escape_str(node->name, esc_name, sizeof(esc_name));

        if (!first) fprintf(out, ",\n");
        first = 0;
        fprintf(out, "  \"%s\": {\n", esc_name);
        fprintf(out, "    \"calls\": [\n");

        call_edge_t* e = node->calls;
        int first_edge = 1;
        while (e) {
            g_scope_count[e->scope >= 0 && e->scope <= 3 ? e->scope : 0]++;
            char esc_caller[MAX_NAME_LEN * 2];
            char esc_file[1024];
            json_escape_str(e->caller, esc_caller, sizeof(esc_caller));
            json_escape_str(e->file, esc_file, sizeof(esc_file));

            if (!first_edge) fprintf(out, ",\n");
            first_edge = 0;
            fprintf(out, "      {\"function\":\"%s\",\"file\":\"%s\",\"line\":%d",
                    esc_caller, esc_file, e->line);
            if (e->args[0]) {
                char esc_args[4096];
                json_escape_str(e->args, esc_args, sizeof(esc_args));
                fprintf(out, ",\"arguments\":[\"%s\"]", esc_args);
            }
            if (e->indirect) {
                fprintf(out, ",\"indirect\":true");
                if (e->via[0] && e->via[0] != '#') {
                    char esc_via[MAX_NAME_LEN * 2];
                    json_escape_str(e->via, esc_via, sizeof(esc_via));
                    fprintf(out, ",\"via\":\"%s\"", esc_via);
                }
            }
            // 跨文件解析结果（省字节编码）：
            //   scope=local      → 同文件定义（def 就是调用点自己的 file）
            //   def=<file>       → 唯一全局/头文件可见定义
            //   scope=ambiguous  → defs 份同名实现混在这条边上，别当精确边
            //   三者都没有        → external（索引里没有对应定义，或只有别处的 static）
            if (e->scope == SCOPE_LOCAL) {
                fprintf(out, ",\"scope\":\"local\"");
            } else if (e->scope == SCOPE_GLOBAL) {
                char esc_def[1024];
                json_escape_str(e->def, esc_def, sizeof(esc_def));
                fprintf(out, ",\"def\":\"%s\"", esc_def);
            } else if (e->scope == SCOPE_AMBIGUOUS) {
                fprintf(out, ",\"scope\":\"ambiguous\",\"defs\":%d", e->defs > 0 ? e->defs : 2);
            }
            fprintf(out, "}");
            e = e->next;
        }

        fprintf(out, "\n    ]\n  }");
        node = node->next;
    }

    fprintf(out, "\n}\n");
    fclose(out);
    printf("Saved call graph to %s\n", out_file);
    printf("  Symbol resolution: %d local, %d global, %d ambiguous, %d external\n",
           g_scope_count[SCOPE_LOCAL], g_scope_count[SCOPE_GLOBAL],
           g_scope_count[SCOPE_AMBIGUOUS], g_scope_count[SCOPE_EXTERNAL]);

    // Cleanup
    for (int i = 0; i < g_func_count; i++) free(g_func_names[i]);
    free(g_func_names);

    while (bodies) {
        func_body_t* next = bodies->next;
        free(bodies->content);
        free(bodies);
        bodies = next;
    }

    while (g_func_nodes) {
        func_node_t* fn = g_func_nodes;
        g_func_nodes = fn->next;
        call_edge_t* e = fn->calls;
        while (e) {
            call_edge_t* next = e->next;
            free(e);
            e = next;
        }
        free(fn);
    }

    free(line);
    return 0;
}
