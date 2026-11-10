/* cgrep: 代码搜索 helper。输入 flat JSON:
 * {"pattern":"...","path":".","ext":"lua,c,h","ignore_case":true,
 *  "fixed":false,"max_hits":200,"per_file":20,"threads":4}
 * 输出 JSON: {"ok":true,"hits":[{file,line,text}],"files":N,"scanned":N,"count":N,"ms":N,"truncated":bool}
 * 注意 count 不能叫 hits：cjson 里同名键取后者，数组会被计数器覆盖成数字
 * （踩过：helper/cgrep.lua:24 attempt to get length of field 'hits'）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <regex.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>
#include <pthread.h>

#define MAXFILES 200000
#define MAXTEXT 220
#define MAXSIZE (4*1024*1024)

typedef struct { int fileidx; int line; char text[MAXTEXT]; } Hit;

typedef struct {
    char **files; int nfiles, cap;
    Hit *hits; int nhits, caphits;
    int max_hits, per_file, truncated, scanned;
    regex_t re;
    char ext[512];
    pthread_mutex_t mu;
    int next;
} Ctx;

typedef struct { char *p; size_t n, cap; } Buf;

static Ctx g;
static char errbuf[512];

static void bput(Buf *b, const char *s, size_t l) {
    if (b->n + l + 1 > b->cap) {
        size_t c = b->cap ? b->cap : 1024;
        while (c < b->n + l + 1) c *= 2;
        b->p = realloc(b->p, c);
        b->cap = c;
    }
    memcpy(b->p + b->n, s, l); b->n += l; b->p[b->n] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bjson(Buf *b, const char *s, size_t l) {
    bput(b, "\"", 1);
    for (size_t i = 0; i < l; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  bputs(b, "\\\""); break;
        case '\\': bputs(b, "\\\\"); break;
        case '\n': bputs(b, "\\n"); break;
        case '\r': bputs(b, "\\r"); break;
        case '\t': bputs(b, "\\t"); break;
        default:
            if (c < 0x20) { char t[8]; snprintf(t, sizeof t, "\\u%04x", c); bputs(b, t); }
            else bput(b, (char *)&c, 1);
        }
    }
    bput(b, "\"", 1);
}

static const char *jfind(const char *j, const char *key) {
    char pat[128]; snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = j;
    while ((p = strstr(p, pat)) != NULL) {
        const char *q = p + strlen(pat);
        while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') q++;
        if (*q == ':') { q++; while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') q++; return q; }
        p = q;
    }
    return NULL;
}
static int jstr(const char *j, const char *key, char *out, size_t n) {
    const char *v = jfind(j, key);
    if (!v || *v != '"') return 0;
    v++; size_t o = 0;
    while (*v && *v != '"') {
        if (*v == '\\') {
            v++;
            if (!*v) break;
            switch (*v) {
            case 'n': if (o + 1 < n) out[o++] = '\n'; v++; break;
            case 't': if (o + 1 < n) out[o++] = '\t'; v++; break;
            case 'r': if (o + 1 < n) out[o++] = '\r'; v++; break;
            case 'u': {
                unsigned cp = 0; int bad = 0;
                for (int i = 1; i <= 4; i++) {
                    unsigned char h = (unsigned char)v[i];
                    if (!isxdigit(h)) { bad = 1; break; }
                    cp = cp * 16 + (isdigit(h) ? h - '0' : (tolower(h) - 'a' + 10));
                }
                v += bad ? 1 : 5;
                if (bad) break;
                if (cp < 0x80) { if (o + 1 < n) out[o++] = (char)cp; }
                else if (cp < 0x800) { if (o + 2 < n) { out[o++] = 0xC0 | (cp >> 6); out[o++] = 0x80 | (cp & 0x3F); } }
                else { if (o + 3 < n) { out[o++] = 0xE0 | (cp >> 12); out[o++] = 0x80 | ((cp >> 6) & 0x3F); out[o++] = 0x80 | (cp & 0x3F); } }
                break;
            }
            default: if (o + 1 < n) out[o++] = *v; v++; break;
            }
        } else { if (o + 1 < n) out[o++] = *v; v++; }
    }
    out[o] = 0;
    return 1;
}
static long jint(const char *j, const char *key, long def) {
    const char *v = jfind(j, key);
    if (!v) return def;
    if (!isdigit((unsigned char)*v) && *v != '-') return def;
    return strtol(v, NULL, 10);
}
static int jbool(const char *j, const char *key, int def) {
    const char *v = jfind(j, key);
    if (!v) return def;
    if (strncmp(v, "true", 4) == 0) return 1;
    if (strncmp(v, "false", 5) == 0) return 0;
    return def;
}

static const char *SKIP[] = {".git","node_modules","build","dist",".cache","__pycache__",
                             ".venv","target",".idea",".vscode","helper/lib/.skip",NULL};

static int skip_dir(const char *n) {
    for (int i = 0; SKIP[i]; i++) if (strcmp(n, SKIP[i]) == 0) return 1;
    return 0;
}

static int ext_ok(Ctx *c, const char *path) {
    if (!c->ext[0]) return 1;
    const char *dot = strrchr(path, '.');
    if (!dot) return 0;
    dot++;
    size_t dl = strlen(dot);
    const char *p = c->ext;
    while (*p) {
        const char *comma = strchr(p, ',');
        size_t l = comma ? (size_t)(comma - p) : strlen(p);
        if (l == dl && strncasecmp(p, dot, l) == 0) return 1;
        if (!comma) break;
        p = comma + 1;
    }
    return 0;
}

static void add_file(Ctx *c, const char *path) {
    if (c->nfiles >= c->cap) {
        c->cap = c->cap ? c->cap * 2 : 1024;
        c->files = realloc(c->files, c->cap * sizeof(char *));
    }
    c->files[c->nfiles++] = strdup(path);
}

static void walk(Ctx *c, const char *dir, int depth) {
    if (depth > 24 || c->nfiles >= MAXFILES) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    char path[4096];
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        int n = snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        if (n < 0 || (size_t)n >= sizeof path) continue;
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISLNK(st.st_mode)) continue;
        if (S_ISDIR(st.st_mode)) { if (skip_dir(e->d_name)) continue; walk(c, path, depth + 1); }
        else if (S_ISREG(st.st_mode)) add_file(c, path);
    }
    closedir(d);
}

static void push_hit(Ctx *c, int fi, int line, const char *ls, size_t len) {
    pthread_mutex_lock(&c->mu);
    if (c->nhits >= c->max_hits) { c->truncated = 1; pthread_mutex_unlock(&c->mu); return; }
    if (c->nhits >= c->caphits) {
        c->caphits = c->caphits ? c->caphits * 2 : 256;
        c->hits = realloc(c->hits, c->caphits * sizeof(Hit));
    }
    Hit *h = &c->hits[c->nhits];
    int trunc = len > MAXTEXT - 1;
    if (trunc) len = MAXTEXT - 1;
    memcpy(h->text, ls, len);
    while (trunc && len > 0 && ((unsigned char)h->text[len] & 0xC0) == 0x80) len--;
    h->text[len] = 0;
    h->fileidx = fi; h->line = line;
    c->nhits++;
    pthread_mutex_unlock(&c->mu);
}

static void scan_file(Ctx *c, int fi) {
    const char *path = c->files[fi];
    if (!ext_ok(c, path)) return;
    FILE *f = fopen(path, "rb");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long sz = ftell(f);
    if (sz < 0 || sz > MAXSIZE) { fclose(f); return; }
    rewind(f);
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return; }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[rd] = 0;
    pthread_mutex_lock(&c->mu); c->scanned++; pthread_mutex_unlock(&c->mu);
    if (memchr(buf, 0, rd)) { free(buf); return; }

    const char *base = buf, *p = buf;
    int line = 1, per = 0;
    while (p < base + rd) {
        regmatch_t m;
        if (regexec(&c->re, p, 1, &m, p == base ? 0 : REG_NOTBOL) != 0) break;
        if (m.rm_so < 0) break;
        const char *hit = p + m.rm_so;
        for (const char *q = p; q < hit; q++) if (*q == '\n') line++;
        const char *ls = hit;
        while (ls > base && ls[-1] != '\n') ls--;
        const char *le = hit;
        while (le < base + rd && *le != '\n') le++;
        push_hit(c, fi, line, ls, (size_t)(le - ls));
        if (++per >= c->per_file) break;
        p = (le > p) ? le : p + 1;   /* 一行只报一次，跳过本行剩余匹配 */
    }
    free(buf);
}

static void *worker(void *arg) {
    Ctx *c = (Ctx *)arg;
    for (;;) {
        pthread_mutex_lock(&c->mu);
        int i = c->next++;
        int stop = (c->nhits >= c->max_hits);
        pthread_mutex_unlock(&c->mu);
        if (stop || i >= c->nfiles) break;
        scan_file(c, i);
    }
    return NULL;
}

static int cmp_hit(const void *a, const void *b) {
    const Hit *x = a, *y = b;
    int r = strcmp(g.files[x->fileidx], g.files[y->fileidx]);
    if (r) return r;
    return x->line - y->line;
}

static void escape_re(const char *s, char *d) {
    for (; *s; s++) { if (strchr("\\^$.[]|()*+?{}", *s)) *d++ = '\\'; *d++ = *s; }
    *d = 0;
}

static char *err_json(const char *msg) {
    Buf b = {0};
    bputs(&b, "{\"ok\":false,\"error\":");
    bjson(&b, msg, strlen(msg));
    bputs(&b, ",\"required\":[\"pattern\"]}");
    return b.p;
}

char *lite_helper(const char *input) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    memset(&g, 0, sizeof g);
    pthread_mutex_init(&g.mu, NULL);

    char pattern[1024] = {0}, path[4096] = {0};
    const char *j = input ? input : "";
    int is_json = (*j == '{');
    if (!is_json) { snprintf(pattern, sizeof pattern, "%s", j); }
    else {
        jstr(j, "pattern", pattern, sizeof pattern);
        if (!jstr(j, "path", path, sizeof path)) snprintf(path, sizeof path, ".");
    }
    if (!pattern[0]) { pthread_mutex_destroy(&g.mu); return err_json("missing required key: pattern"); }
    if (!path[0]) snprintf(path, sizeof path, ".");

    g.max_hits = (int)jint(j, "max_hits", 200);
    if (g.max_hits <= 0) g.max_hits = 200;
    if (g.max_hits > 2000) g.max_hits = 2000;
    g.per_file = (int)jint(j, "per_file", 20);
    if (g.per_file <= 0) g.per_file = 20;
    int threads = (int)jint(j, "threads", 4);
    if (threads < 1) threads = 1;
    if (threads > 16) threads = 16;
    if (is_json) jstr(j, "ext", g.ext, sizeof g.ext);

    char re_pat[2048];
    int fixed = is_json ? jbool(j, "fixed", 0) : 0;
    if (fixed) escape_re(pattern, re_pat); else snprintf(re_pat, sizeof re_pat, "%s", pattern);
    int cflags = REG_EXTENDED | REG_NEWLINE;
    if (is_json && jbool(j, "ignore_case", 1)) cflags |= REG_ICASE;
    int rc = regcomp(&g.re, re_pat, cflags);
    if (rc != 0) {
        regerror(rc, &g.re, errbuf, sizeof errbuf);
        pthread_mutex_destroy(&g.mu);
        return err_json(errbuf);
    }

    struct stat st;
    if (stat(path, &st) != 0) {
        snprintf(errbuf, sizeof errbuf, "path not found: %s", path);
        regfree(&g.re); pthread_mutex_destroy(&g.mu);
        return err_json(errbuf);
    }
    if (S_ISDIR(st.st_mode)) walk(&g, path, 0);
    else add_file(&g, path);

    pthread_t th[16];
    int started = 0;
    int n = threads < g.nfiles ? threads : g.nfiles;
    for (int i = 0; i < n; i++) if (pthread_create(&th[i], NULL, worker, &g) == 0) started++;
    if (started == 0) worker(&g);
    for (int i = 0; i < started; i++) pthread_join(th[i], NULL);

    int total_hits = g.nhits;
    if (g.nhits > 1) qsort(g.hits, g.nhits, sizeof(Hit), cmp_hit);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    if (ms < 1) ms = 1;

    Buf b = {0};
    bputs(&b, "{\"ok\":true,\"hits\":[");
    for (int i = 0; i < g.nhits; i++) {
        if (i) bput(&b, ",", 1);
        bputs(&b, "{\"file\":"); bjson(&b, g.files[g.hits[i].fileidx], strlen(g.files[g.hits[i].fileidx]));
        char num[32]; snprintf(num, sizeof num, ",\"line\":%d,\"text\":", g.hits[i].line); bputs(&b, num);
        bjson(&b, g.hits[i].text, strlen(g.hits[i].text));
        bput(&b, "}", 1);
    }
    char tail[256];
    snprintf(tail, sizeof tail, "],\"files\":%d,\"scanned\":%d,\"count\":%d,\"ms\":%ld,\"truncated\":%s}",
             g.nfiles, g.scanned, total_hits, ms, g.truncated ? "true" : "false");
    bputs(&b, tail);

    regfree(&g.re);
    pthread_mutex_destroy(&g.mu);
    return b.p;
}

void lite_helper_free(char *out) { free(out); }
