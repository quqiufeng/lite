/* perfprobe: sample a target with perf_event_open, attribute leaf IPs.
 *
 * lite_helper(input_json) -> output_json (UTF-8)
 *   in : {"argv":["prog","a"] | "command":"prog a", "freq":99, "seconds":60,
 *          "top":20, "kernel":true, "show_output":false, "max_samples":200000}
 *   out: {"ok":1,"target","samples","lost","dropped","exit","signal","killed",
 *         "seconds","timed_out","maps","maps_truncated","freq","cap",
 *         "anon_pct","jit_pct","kernel_pct","unmapped_pct","kernel_excluded",
 *         "truncated","hint","objects":[{"name","samples","pct"}],
 *         "symbols":[{"symbol","object","samples","pct"}]}
 *   err: {"ok":0,"samples":0,"exit":0,"stage","error"}   -- ok~=1 才是失败
 *
 * Why the SIGSTOP handshake: the counter is armed with enable_on_exec=1 so counting
 * starts exactly at execve. The child stops itself right after fork, letting the parent
 * finish perf_event_open + mmap before the target runs an instruction -- no usleep
 * race, and short-lived targets still get sampled.
 *
 * Why off2va walks PT_LOAD: the IP arrives as a *file offset*
 * (ip - map.start + map.off), while symbol tables hold *virtual* addresses. They are
 * equal only for PIE/DSO (p_vaddr == p_offset); PT_LOAD gives
 * vaddr = p_vaddr + (file_off - p_offset), valid for ET_EXEC too.
 *
 * /tmp/perf-<pid>.map (perfmap) is read and reloaded when it changes so LuaJIT/JVM
 * frames get real names instead of an anonymous blob.
 *
 * Why .eh_frame when there is no symbol table: `strip -s` deletes .symtab, so a
 * binary shipped without debug info answers nothing -- yet .eh_frame (needed by
 * C++ unwinding / backtrace) survives and holds one FDE per function with its
 * pc_begin/pc_end. We parse the CFI header chain (length + CIE pointer + FDE
 * encoding), resolve pcrel/datarel values against the section address, and
 * report "sub_<pc_begin>" -- coarse (no args, static funcs included) but a
 * hundred times better than [nosym]. Same fallback exists in lua/trace/engine.lua
 * for --sym; the two parsers are independent on purpose (engine is Lua/FFI,
 * this one is C in-process) so one bug cannot hide the other.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <ctype.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <elf.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

#define RING_SZ    (1u << 20)   /* power of two */
#define MAXHITS    8192
#define MAXOBJ     256
#define MAXMAPS    2048
#define MAXELF     256
#define MAXJIT     200000
#define MAXARGV    64
#define DEFCAP     200000
#define MAXCAP     1000000

/* ---------------------------------------------------------------- buffer */
typedef struct { char *p; size_t n, cap; } Buf;
static void binit(Buf *b) { b->cap = 4096; b->n = 0; b->p = malloc(b->cap); if (b->p) b->p[0] = 0; }
static void bgrow(Buf *b, size_t need) {
  if (!b->p || b->n + need + 1 <= b->cap) return;
  size_t c = b->cap; while (c < b->n + need + 1) c *= 2;
  char *q = realloc(b->p, c); if (!q) return;
  b->p = q; b->cap = c;
}
static void bput(Buf *b, const char *s, size_t n) { bgrow(b, n); if (!b->p) return; memcpy(b->p + b->n, s, n); b->n += n; b->p[b->n] = 0; }
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bprintf(Buf *b, const char *fmt, ...) {
  char t[512]; va_list ap;
  va_start(ap, fmt); int n = vsnprintf(t, sizeof t, fmt, ap); va_end(ap);
  if (n < 0) return;
  if ((size_t)n < sizeof t) { bput(b, t, (size_t)n); return; }
  char *big = malloc((size_t)n + 1); if (!big) return;
  va_start(ap, fmt); vsnprintf(big, (size_t)n + 1, fmt, ap); va_end(ap);
  bput(b, big, (size_t)n); free(big);
}
static void bjstr(Buf *b, const char *s) {
  bputs(b, "\"");
  for (; s && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') { bputs(b, "\\"); bput(b, (const char *)&c, 1); }
    else if (c == '\n') bputs(b, "\\n");
    else if (c == '\t') bputs(b, "\\t");
    else if (c == '\r') bputs(b, "\\r");
    else if (c < 0x20) bprintf(b, "\\u%04x", c);
    else bput(b, (const char *)&c, 1);
  }
  bputs(b, "\"");
}

/* ------------------------------------------------------------------ json */
static const char *jspace(const char *p) { while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++; return p; }

/* Exact-key lookup: pointer just past the ':' of "key":value, or NULL.
 * Length compared too, so "argv" never matches "argv2" / "xargv". */
static const char *jkey(const char *s, const char *key) {
  size_t kl = strlen(key);
  const char *p = s;
  while (p && *p) {
    if (*p != '"') { p++; continue; }
    const char *q = p + 1; size_t n = 0;
    while (q[n] && q[n] != '"') { if (q[n] == '\\' && q[n + 1]) n++; n++; }
    if (!q[n]) return NULL;                        /* unterminated string */
    if (n == kl && !memcmp(q, key, kl)) {
      const char *c = jspace(q + n + 1);
      if (*c == ':') return jspace(c + 1);
    }
    p = q + n + 1;
  }
  return NULL;
}

/* Decode one JSON string starting at '"'; returns pointer past closing quote.
 * \uXXXX is decoded; non-ASCII code points are dropped (argv is a file path). */
static const char *jstr_at(const char *v, char *out, size_t cap) {
  if (!v || *v != '"') return NULL;
  size_t o = 0;
  v++;
  while (*v && *v != '"') {
    if (*v == '\\' && v[1]) {
      v++;
      switch (*v) {
        case 'n': if (o + 1 < cap) out[o++] = '\n'; break;
        case 't': if (o + 1 < cap) out[o++] = '\t'; break;
        case 'r': if (o + 1 < cap) out[o++] = '\r'; break;
        case 'b': if (o + 1 < cap) out[o++] = '\b'; break;
        case 'f': if (o + 1 < cap) out[o++] = '\f'; break;
        case 'u': {
          unsigned cp = 0; int k;
          for (k = 1; k <= 4; k++) {
            char c = v[k]; int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else break;
            cp = cp * 16 + (unsigned)d;
          }
          v += k - 1;
          if (cp >= 0x20 && cp < 0x7f && o + 1 < cap) out[o++] = (char)cp;
          break;
        }
        default: if (o + 1 < cap) out[o++] = *v; break;
      }
      v++; continue;
    }
    if (o + 1 < cap) out[o++] = *v;
    v++;
  }
  if (cap) out[o] = 0;
  return (*v == '"') ? v + 1 : v;
}

static int jstr(const char *s, const char *key, char *out, size_t cap) {
  if (cap) out[0] = 0;
  const char *v = jkey(s, key);
  return jstr_at(v, out, cap) != NULL;
}

static double jnum(const char *s, const char *key, double def) {
  const char *v = jkey(s, key);
  if (!v) return def;
  if (!(isdigit((unsigned char)*v) || *v == '-' || *v == '+' || *v == '.')) return def;
  char *end = NULL;
  double d = strtod(v, &end);
  return (end == v) ? def : d;
}

static int jbool(const char *s, const char *key, int def) {
  const char *v = jkey(s, key);
  if (!v) return def;
  if (*v == 't') return 1;
  if (*v == 'f') return 0;
  if (isdigit((unsigned char)*v)) return strtol(v, NULL, 10) != 0;
  return def;
}

/* "argv":["a","b"]  ->  argv[i] (malloc'd), returns count or -1 on malformed JSON */
static int jargv(const char *s, char **argv, int maxargv) {
  const char *v = jkey(s, "argv");
  int n = 0;
  if (!v) return -1;
  if (*v != '[') return -1;
  v = jspace(v + 1);
  while (*v && *v != ']' && n < maxargv) {
    char tmp[1024];
    const char *e = jstr_at(v, tmp, sizeof tmp);
    if (!e) return -1;
    argv[n] = strdup(tmp);
    if (!argv[n]) return -1;
    n++;
    v = jspace(e);
    if (*v == ',') { v = jspace(v + 1); continue; }
    break;
  }
  return n;
}

static void freeargv(char **argv, int n) { for (int i = 0; i < n; i++) free(argv[i]); }

/* ------------------------------------------------------------------- elf */
typedef struct { unsigned long off, vaddr, filesz; } Seg;
typedef struct { unsigned long long v; char *nm; } Sym;
typedef struct { unsigned long long b, e; } Fde;      /* .eh_frame 的 pc 范围 */
typedef struct {
  char path[512];
  unsigned char *base;
  size_t fsz;
  Sym *s;
  int n;
  Fde *f;         /* 无符号表时的退化层：FDE 边界 */
  int nf;
  Seg seg[8];
  int nseg;
  int tried;      /* 1 = parsed (s may still be NULL) */
} Elf;

static Elf *g_elf;
static int g_nelf, g_capelf;
static long g_elf_full;

static void elf_release_all(void) {
  for (int i = 0; i < g_nelf; i++) {
    free(g_elf[i].s);
    free(g_elf[i].f);
    if (g_elf[i].base) munmap(g_elf[i].base, g_elf[i].fsz);   /* base is mmap'ed, not malloc'ed */
  }
  free(g_elf); g_elf = NULL; g_nelf = g_capelf = 0; g_elf_full = 0;
}

static int symcmp(const void *a, const void *b) {
  unsigned long long x = ((const Sym *)a)->v, y = ((const Sym *)b)->v;
  return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/* ---- .eh_frame：strip -s 只删 .symtab，CFI 还在；FDE 的 pc 范围就是函数边界。
   拿不到名字时至少给出 sub_<入口地址>，比一片 [nosym] 有用。DWARF32 only。 */
static int fdecmp(const void *a, const void *b) {
  unsigned long long x = ((const Fde *)a)->b, y = ((const Fde *)b)->b;
  return (x < y) ? -1 : (x > y) ? 1 : 0;
}

static int uleb(const unsigned char *p, const unsigned char *end, unsigned long long *out,
                const unsigned char **np) {
  unsigned long long v = 0;
  int sh = 0;
  while (p < end && sh <= 63) {
    unsigned char c = *p++;
    v |= (unsigned long long)(c & 0x7f) << sh;
    if (!(c & 0x80)) { *out = v; *np = p; return 1; }
    sh += 7;
  }
  return 0;
}

static int sleb(const unsigned char *p, const unsigned char *end, long long *out,
                const unsigned char **np) {
  long long v = 0;
  int sh = 0;
  unsigned char c = 0;
  while (p < end && sh <= 63) {
    c = *p++;
    v |= (long long)(c & 0x7f) << sh;
    sh += 7;
    if (!(c & 0x80)) {
      if (sh < 64 && (c & 0x40)) v |= -((long long)1 << sh);   /* 符号扩展 */
      *out = v; *np = p; return 1;
    }
  }
  return 0;
}

/* 按 DW_EH_PE 的 format 位读一个值（不含 application） */
static int read_val(const unsigned char **pp, const unsigned char *end, int fmt,
                    unsigned long long *v) {
  const unsigned char *p = *pp;
  unsigned long long x;
  switch (fmt) {
    case 0x01: if (!uleb(p, end, &x, pp)) return 0; break;                    /* uleb128 */
    case 0x09: { long long s; if (!sleb(p, end, &s, pp)) return 0;
                 x = (unsigned long long)s; break; }                          /* sleb128 */
    case 0x02: if (p + 2 > end) return 0; { uint16_t t; memcpy(&t, p, 2); x = t; } *pp = p + 2; break;
    case 0x0a: if (p + 2 > end) return 0; { int16_t t; memcpy(&t, p, 2);
                 x = (unsigned long long)(long long)t; } *pp = p + 2; break;
    case 0x03: if (p + 4 > end) return 0; { uint32_t t; memcpy(&t, p, 4); x = t; } *pp = p + 4; break;
    case 0x0b: if (p + 4 > end) return 0; { int32_t t; memcpy(&t, p, 4);
                 x = (unsigned long long)(long long)t; } *pp = p + 4; break;
    case 0x04: case 0x0c: if (p + 8 > end) return 0;
                 { uint64_t t; memcpy(&t, p, 8); x = t; } *pp = p + 8; break;
    default: return 0;
  }
  *v = x;
  return 1;
}

/* field_va = 该字段在内存里的虚拟地址（pcrel 的基址） */
static int enc_val(const unsigned char **pp, const unsigned char *end, int enc,
                   unsigned long long field_va, unsigned long long *out) {
  int fmt = enc & 0x0f, app = enc & 0x70;
  if (!enc) return 0;
  if (fmt == 0) fmt = 0x0c;             /* absptr：x86-64 下就是 8 字节 */
  if (app && app != 0x10) return 0;     /* datarel/textrel/funcrel 一律放弃 */
  const unsigned char *save = *pp;
  unsigned long long v;
  if (!read_val(pp, end, fmt, &v)) { *pp = save; return 0; }
  *out = (app == 0x10) ? field_va + v : v;
  return 1;
}

/* 两遍扫：先收 CIE 的 FDE 指针编码（'zR'），再解 FDE 的 pc_begin/range。 */
static void elf_parse_eh(Elf *e, size_t sec_off, size_t sec_sz, unsigned long long sec_addr) {
  const unsigned char *b = e->base;
  size_t over = (sec_off + sec_sz > e->fsz) ? e->fsz : sec_off + sec_sz;
  struct { unsigned long rec; int enc; } cie[16];
  int ncie = 0;
  size_t cap = 64, n = 0;
  Fde *arr = malloc(cap * sizeof *arr);
  if (!arr) return;

  size_t p = sec_off;
  while (p + 8 <= over) {
    uint32_t len;
    memcpy(&len, b + p, 4);
    if (!len) break;
    if (len == 0xffffffffu) break;                        /* DWARF64：极少见，放弃 */
    size_t body = p + 4, nextp = body + len;
    if (nextp <= body || nextp > over) break;
    uint32_t cid;
    memcpy(&cid, b + body, 4);

    if (cid == 0) {                                       /* CIE */
      unsigned char ver = b[body + 4];
      const unsigned char *q = b + body + 5, *qe = b + nextp;
      char aug[16] = {0};
      int na = 0;
      while (q < qe && *q && na < 15) aug[na++] = (char)*q++;
      q++;
      if (ver >= 4) q += 2;                               /* address_size + segment_size */
      unsigned long long u;
      long long s;
      if (!uleb(q, qe, &u, &q) || !sleb(q, qe, &s, &q)) { p = nextp; continue; }
      if (ver == 1) q += 1;
      else { unsigned long long ra; if (!uleb(q, qe, &ra, &q)) { p = nextp; continue; } }
      int enc = 0;
      if (aug[0] == 'z') {
        unsigned long long alen;
        if (!uleb(q, qe, &alen, &q)) { p = nextp; continue; }
        const unsigned char *ae = (q + alen < qe) ? q + alen : qe;
        for (char *a = aug + 1; *a && q < ae; a++) {
          if (*a == 'R') enc = *q++;
          else if (*a == 'L') q++;
          else if (*a == 'P') {
            int pe = *q++;
            unsigned long long dv;
            if (!enc_val(&q, ae, pe, 0, &dv)) break;
          } else if (*a == 'S') { }
          else break;
        }
      }
      if (ncie < 16) { cie[ncie].rec = p; cie[ncie].enc = enc; ncie++; }
      p = nextp;
      continue;
    }

    unsigned long co = (unsigned long)(body - cid);        /* FDE 的 CIE 指针相对自身 */
    int enc = -1;
    for (int i = 0; i < ncie; i++) if (cie[i].rec == co) { enc = cie[i].enc; break; }
    if (enc <= 0) { p = nextp; continue; }
    const unsigned char *q = b + body + 4, *qe = b + nextp;
    unsigned long long begin, range;
    unsigned long long field_va = sec_addr + (unsigned long long)(body + 4 - sec_off);
    if (!enc_val(&q, qe, enc, field_va, &begin)) { p = nextp; continue; }
    int rf = enc & 0x0f;
    if (rf == 0) rf = 0x03;
    if (!read_val(&q, qe, rf, &range)) { p = nextp; continue; }
    if (!begin || !range) { p = nextp; continue; }
    if (n == cap) {
      Fde *na2 = realloc(arr, cap * 2 * sizeof *arr);
      if (!na2) break;
      arr = na2; cap *= 2;
    }
    arr[n].b = begin;
    arr[n].e = begin + range;
    n++;
    p = nextp;
  }
  if (n) { qsort(arr, n, sizeof *arr, fdecmp); e->f = arr; e->nf = (int)n; }
  else free(arr);
}

static void elf_fde_try(Elf *e, const Elf64_Shdr *sh) {
  if (sh) elf_parse_eh(e, sh->sh_offset, sh->sh_size, sh->sh_addr);
}

/* Fill e->seg[] from PT_LOAD and e->s[] from .symtab (fallback .dynsym). */
static void elf_parse(Elf *e) {
  unsigned char *b = e->base;
  size_t sz = e->fsz;
  if (sz < sizeof(Elf64_Ehdr)) return;
  Elf64_Ehdr *eh = (Elf64_Ehdr *)b;
  if (eh->e_phentsize != sizeof(Elf64_Phdr)) return;
  for (int i = 0; i < eh->e_phnum && e->nseg < 8; i++) {
    size_t o = (size_t)eh->e_phoff + (size_t)i * eh->e_phentsize;
    if (o + sizeof(Elf64_Phdr) > sz) break;
    Elf64_Phdr *ph = (Elf64_Phdr *)(b + o);
    if (ph->p_type != PT_LOAD || !ph->p_filesz) continue;
    e->seg[e->nseg].off = ph->p_offset;
    e->seg[e->nseg].vaddr = ph->p_vaddr;
    e->seg[e->nseg].filesz = ph->p_filesz;
    e->nseg++;
  }
  if (eh->e_shentsize != sizeof(Elf64_Shdr)) return;
  /* .eh_frame 的位置：无符号表时靠它的 FDE 边界兜底 */
  const Elf64_Shdr *ehsec = NULL;
  if (eh->e_shstrndx < eh->e_shnum) {
    size_t no = (size_t)eh->e_shoff + (size_t)eh->e_shstrndx * eh->e_shentsize;
    if (no + sizeof(Elf64_Shdr) <= sz) {
      const Elf64_Shdr *sn = (const Elf64_Shdr *)(b + no);
      if (sn->sh_offset < sz) {
        const char *nmb = (const char *)(b + sn->sh_offset);
        size_t nl = sn->sh_size;
        if (sn->sh_offset + nl > sz) nl = sz - sn->sh_offset;
        for (int i = 0; i < eh->e_shnum; i++) {
          size_t o = (size_t)eh->e_shoff + (size_t)i * eh->e_shentsize;
          if (o + sizeof(Elf64_Shdr) > sz) break;
          const Elf64_Shdr *sh = (const Elf64_Shdr *)(b + o);
          if (sh->sh_name >= nl || sh->sh_type == SHT_NOBITS) continue;
          const char *cn = nmb + sh->sh_name;
          size_t rem = nl - sh->sh_name;                  /* ".eh_frame" 精确匹配，排除 _hdr */
          if (rem > 9 && !strncmp(cn, ".eh_frame", 9) && cn[9] == 0) { ehsec = sh; break; }
        }
      }
    }
  }
  const Elf64_Shdr *use = NULL;
  size_t nsym = 0;
  const Elf64_Shdr *dyn = NULL;
  for (int i = 0; i < eh->e_shnum; i++) {
    size_t o = (size_t)eh->e_shoff + (size_t)i * eh->e_shentsize;
    if (o + sizeof(Elf64_Shdr) > sz) break;
    const Elf64_Shdr *sh = (const Elf64_Shdr *)(b + o);
    if (sh->sh_type == SHT_SYMTAB && !use) { use = sh; nsym = sh->sh_size / sh->sh_entsize; }
    else if (sh->sh_type == SHT_DYNSYM && !dyn) dyn = sh;
  }
  if (!use && dyn) { use = dyn; nsym = dyn->sh_size / dyn->sh_entsize; }
  if (!use || !use->sh_entsize) { elf_fde_try(e, ehsec); return; }
  size_t so = use->sh_offset;
  size_t st = use->sh_link < (size_t)eh->e_shnum ? (size_t)eh->e_shoff + use->sh_link * eh->e_shentsize : 0;
  if (!st || st + sizeof(Elf64_Shdr) > sz) { elf_fde_try(e, ehsec); return; }
  const Elf64_Shdr *str = (const Elf64_Shdr *)(b + st);
  if (str->sh_offset >= sz) { elf_fde_try(e, ehsec); return; }
  size_t strsz = str->sh_size;
  if (str->sh_offset + strsz > sz) strsz = sz - str->sh_offset;
  const char *strb = (const char *)(b + str->sh_offset);
  if (nsym > MAXJIT) nsym = MAXJIT;
  if (so + nsym * use->sh_entsize > sz) nsym = (sz > so) ? (sz - so) / use->sh_entsize : 0;
  if (!nsym) { elf_fde_try(e, ehsec); return; }
  Sym *arr = malloc(nsym * sizeof(Sym));
  if (!arr) { elf_fde_try(e, ehsec); return; }
  int n = 0;
  for (size_t i = 0; i < nsym; i++) {
    const Elf64_Sym *sy = (const Elf64_Sym *)(b + so + i * use->sh_entsize);
    if (!sy->st_value || !sy->st_name) continue;
    if (sy->st_name >= strsz) continue;                  /* strtab bounds */
    const char *nm = strb + sy->st_name;
    if (!nm[0] || strnlen(nm, strsz - sy->st_name) >= strsz - sy->st_name) continue;
    int t = ELF64_ST_TYPE(sy->st_info);
    if (t != STT_FUNC && t != STT_OBJECT && t != STT_NOTYPE && t != STT_GNU_IFUNC) continue;
    arr[n].v = sy->st_value;
    arr[n].nm = (char *)nm;
    n++;
  }
  if (!n) { free(arr); elf_fde_try(e, ehsec); return; }
  qsort(arr, n, sizeof(Sym), symcmp);
  e->s = arr; e->n = n;
}

static Elf *elf_get(const char *path) {
  if (!path || path[0] != '/') return NULL;
  for (int i = 0; i < g_nelf; i++) if (!strcmp(g_elf[i].path, path)) return &g_elf[i];
  if (strstr(path, " (deleted)")) return NULL;   /* can't reopen reliably: don't cache */
  if (g_nelf >= MAXELF) { g_elf_full++; return NULL; }
  if (g_nelf == g_capelf) {
    int c = g_capelf ? g_capelf * 2 : 32;
    Elf *q = realloc(g_elf, (size_t)c * sizeof(Elf));
    if (!q) return NULL;
    g_elf = q; g_capelf = c;
  }
  Elf *e = &g_elf[g_nelf++];
  memset(e, 0, sizeof *e);
  snprintf(e->path, sizeof e->path, "%s", path);
  e->tried = 1;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd >= 0) {
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 64 && st.st_size <= (off_t)(512 << 20)) {
      void *b = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
      if (b != MAP_FAILED) {
        unsigned char *p = b;
        /* e_ident: 0x7f 'E' 'L' 'F', EI_CLASS=2 (ELFCLASS64), EI_DATA=1 (LSB) */
        if (p[0] == 0x7f && p[1] == 'E' && p[2] == 'L' && p[3] == 'F' && p[4] == 2 && p[5] == 1) {
          e->base = b; e->fsz = (size_t)st.st_size;
          elf_parse(e);
        }
        if (!e->base) munmap(b, (size_t)st.st_size);
      }
    }
    close(fd);
  }
  return e;
}

/* file offset -> virtual address via PT_LOAD (0 = no segment covers it) */
static unsigned long off2va(const Elf *e, unsigned long off) {
  if (!e) return 0;
  for (int i = 0; i < e->nseg; i++)
    if (off >= e->seg[i].off && off < e->seg[i].off + e->seg[i].filesz)
      return e->seg[i].vaddr + (off - e->seg[i].off);
  if (!e->nseg) return off;      /* no phdr: legacy p_vaddr==p_offset assumption */
  return 0;
}

static const char *elf_sym(Elf *e, unsigned long fileoff) {
  if (!e || !e->s || !e->n) return NULL;
  unsigned long long va = off2va(e, fileoff);
  if (!va) return NULL;
  int lo = 0, hi = e->n - 1, best = -1;
  while (lo <= hi) {
    int mid = lo + (hi - lo) / 2;
    if (e->s[mid].v <= va) { best = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return (best < 0) ? NULL : e->s[best].nm;
}

/* 无符号表时的兜底：命中 FDE 范围就返回 sub_<入口地址> */
static const char *elf_fde(Elf *e, unsigned long fileoff) {
  static char buf[32];
  if (!e || !e->f || !e->nf) return NULL;
  unsigned long long va = off2va(e, fileoff);
  if (!va) return NULL;
  int lo = 0, hi = e->nf - 1, best = -1;
  while (lo <= hi) {
    int mid = lo + (hi - lo) / 2;
    if (e->f[mid].b <= va) { best = mid; lo = mid + 1; } else hi = mid - 1;
  }
  if (best < 0 || va >= e->f[best].e) return NULL;
  snprintf(buf, sizeof buf, "sub_%llx", e->f[best].b);
  return buf;
}

/* ------------------------------------------------------------------ maps */
typedef struct { unsigned long start, end, off; char path[512]; } MapR;
static MapR g_map[MAXMAPS];
static int g_nmap, g_map_trunc;
static long g_maps_reads;

/* Rebuild in place, in file order (maps is sorted): consecutive lines with the same
 * start AND path are merged, so stale entries from a previous snapshot can't survive.
 * A vanished target (fopen fails) keeps the last snapshot -- exit races are expected. */
static void maps_read(pid_t pid) {
  char p[64];
  snprintf(p, sizeof p, "/proc/%d/maps", pid);
  FILE *f = fopen(p, "re");
  if (!f) return;
  int n = 0, trunc = 0;
  char line[1400];
  while (fgets(line, sizeof line, f)) {
    unsigned long a = 0, b = 0, off = 0;
    char perms[8] = {0}, path[512] = {0};
    int k = sscanf(line, "%lx-%lx %7s %lx %*s %*s %511[^\n]", &a, &b, perms, &off, path);
    if (k < 4) continue;
    if (k < 5) path[0] = 0;      /* no pathname column: anonymous */
    else {
      char *q = path;
      while (*q == ' ') q++;
      if (q != path) memmove(path, q, strlen(q) + 1);
      if (!strcmp(path, "(deleted)")) path[0] = 0;
    }
    if (n > 0 && g_map[n - 1].start == a && !strcmp(g_map[n - 1].path, path)) { g_map[n - 1].end = b; continue; }
    if (n >= MAXMAPS) { trunc = 1; break; }
    g_map[n].start = a; g_map[n].end = b; g_map[n].off = off;
    snprintf(g_map[n].path, sizeof g_map[n].path, "%s", path);
    n++;
  }
  fclose(f);
  g_nmap = n; g_map_trunc = trunc; g_maps_reads++;
}

static MapR *map_find(unsigned long ip) {
  int lo = 0, hi = g_nmap - 1;
  while (lo <= hi) {
    int m = lo + (hi - lo) / 2;
    if (ip < g_map[m].start) hi = m - 1;
    else if (ip >= g_map[m].end) lo = m + 1;
    else return &g_map[m];
  }
  return NULL;
}

/* ------------------------------------------------------------------- jit */
typedef struct { unsigned long start, size; char *nm; } JitE;
static JitE *g_jit;
static int g_njit;
static time_t g_jit_mt;
static off_t g_jit_sz = -1;
static int g_jit_loaded;

static void jit_free(void) {
  for (int i = 0; i < g_njit; i++) free(g_jit[i].nm);
  free(g_jit); g_jit = NULL; g_njit = 0; g_jit_sz = -1; g_jit_mt = 0; g_jit_loaded = 0;
}

static int jitcmp(const void *a, const void *b) {
  unsigned long x = ((const JitE *)a)->start, y = ((const JitE *)b)->start;
  return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/* /tmp/perf-<pid>.map: "%lx %lx <name>", unsorted, rewritten as code is generated. */
static void jit_load(pid_t pid) {
  char p[64];
  snprintf(p, sizeof p, "/tmp/perf-%d.map", (int)pid);
  struct stat st;
  if (stat(p, &st) != 0) { if (g_jit_loaded) jit_free(); return; }
  if (g_jit_loaded && st.st_mtime == g_jit_mt && st.st_size == g_jit_sz) return;
  jit_free();
  g_jit_loaded = 1; g_jit_mt = st.st_mtime; g_jit_sz = st.st_size;
  FILE *f = fopen(p, "re");
  if (!f) return;
  /* jit_free() 刚把 g_jit 置空：cap 只是上限，缓冲区必须自己先分配，
     否则下面的 g_jit[g_njit] 就是空指针写（目标一旦真写了 perf map 即崩）。 */
  int cap = 1024;
  g_jit = malloc((size_t)cap * sizeof(JitE));
  if (!g_jit) { fclose(f); return; }
  char line[600];
  while (fgets(line, sizeof line, f)) {
    unsigned long a = 0, n = 0; char nm[256];
    if (sscanf(line, "%lx %lx %255[^\n]", &a, &n, nm) != 3) continue;
    if (!n || !nm[0]) continue;
    if (g_njit >= cap) {
      if (cap >= MAXJIT) break;
      int c = cap * 2; if (c > MAXJIT) c = MAXJIT;
      JitE *q = realloc(g_jit, (size_t)c * sizeof(JitE));
      if (!q) break;
      g_jit = q; cap = c;
    }
    char *d = strdup(nm);
    if (!d) break;
    g_jit[g_njit].start = a; g_jit[g_njit].size = n; g_jit[g_njit].nm = d;
    g_njit++;
  }
  fclose(f);
  if (g_njit) qsort(g_jit, g_njit, sizeof(JitE), jitcmp);
}

static const char *jit_sym(unsigned long ip) {
  if (!g_njit) return NULL;
  int lo = 0, hi = g_njit - 1, best = -1;
  while (lo <= hi) {
    int m = lo + (hi - lo) / 2;
    if (g_jit[m].start <= ip) { best = m; lo = m + 1; } else hi = m - 1;
  }
  if (best < 0) return NULL;
  return (ip - g_jit[best].start < g_jit[best].size) ? g_jit[best].nm : NULL;
}

/* ----------------------------------------------------------------- probe */
static const char *base_name(const char *p) {
  const char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

static const char *paranoid_str(void) {
  static char v[16];
  if (!v[0]) {
    snprintf(v, sizeof v, "?");
    FILE *f = fopen("/proc/sys/kernel/perf_event_paranoid", "re");
    if (f) { if (fgets(v, sizeof v, f)) { char *n = strchr(v, '\n'); if (n) *n = 0; } fclose(f); }
  }
  return v;
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Arm a CPU_CLOCK counter that starts counting at the child's execve.
 * paranoid>=2 denies kernel-space counters to unprivileged users, so fall back to
 * user-only and tell the caller (kernel_excluded). */
static int open_counter(pid_t pid, int freq, int want_kernel, int *kernel_excluded, char *err, size_t errsz) {
  unsigned long long period = freq > 0 ? 1000000000ULL / (unsigned long long)freq : 10000000ULL;
  if (!period) period = 1;
  int order[2], ntry = 0;
  if (want_kernel) order[ntry++] = 0;
  order[ntry++] = 1;
  for (int t = 0; t < ntry; t++) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = PERF_TYPE_SOFTWARE;
    a.config = PERF_COUNT_SW_CPU_CLOCK;
    a.sample_period = period;
    a.sample_type = PERF_SAMPLE_IP;
    a.disabled = 1;
    a.enable_on_exec = 1;          /* never count before exec */
    a.wakeup_events = 1;           /* wake poll() per sample instead of per watermark */
    a.exclude_kernel = (unsigned)order[t];
    a.exclude_hv = 1;
    a.inherit = 0;
    int fd = (int)syscall(SYS_perf_event_open, &a, pid, -1, -1, 0);
    if (fd >= 0) { *kernel_excluded = order[t]; return fd; }
    int e = errno;
    if (t == 0 && (e == EACCES || e == EPERM)) continue;   /* retry user-only */
    snprintf(err, errsz, "perf_event_open: %s (perf_event_paranoid=%s)", strerror(e), paranoid_str());
    return -1;
  }
  snprintf(err, errsz, "perf_event_open: no usable configuration");
  return -1;
}

/* Consume the ring. Returns the number of sample records seen (>= stored ones),
 * *dropped counts samples lost to our own capacity, *lost sums PERF_RECORD_LOST. */
static int drain(void *buf, size_t pagesz, unsigned long *ips, int nips, int cap, long *lost, long *dropped) {
  struct perf_event_mmap_page *meta = (struct perf_event_mmap_page *)buf;
  __sync_synchronize();
  unsigned long head = meta->data_head;
  unsigned long tail = meta->data_tail;
  char *data = (char *)buf + pagesz;
  int seen = 0;
  while (head - tail >= sizeof(struct perf_event_header)) {
    struct perf_event_header *h = (struct perf_event_header *)(data + (tail & (RING_SZ - 1)));
    if (h->size < sizeof *h || (unsigned long)h->size > head - tail) break;
    if (h->type == PERF_RECORD_SAMPLE && h->size >= sizeof(*h) + 8) {
      unsigned long ip = 0;
      memcpy(&ip, (char *)h + sizeof(*h), 8);
      if (nips + seen < cap) ips[nips + seen] = ip;
      else if (dropped) (*dropped)++;
      seen++;
    } else if (h->type == PERF_RECORD_LOST && h->size >= sizeof(*h) + 16) {
      unsigned long long n = 0;
      memcpy(&n, (char *)h + sizeof(*h) + 8, 8);
      if (lost) *lost += (long)n;
    }
    tail += h->size;
  }
  meta->data_tail = tail;
  return seen;
}

typedef struct { char name[128]; int n; } ObjTot;
typedef struct { char sym[160]; char obj[128]; int n; } SymTot;

static int objcmp(const void *a, const void *b) {
  int x = ((const ObjTot *)a)->n, y = ((const ObjTot *)b)->n;
  return (x < y) ? 1 : (x > y) ? -1 : 0;
}
static int symcmp_n(const void *a, const void *b) {
  int x = ((const SymTot *)a)->n, y = ((const SymTot *)b)->n;
  return (x < y) ? 1 : (x > y) ? -1 : 0;
}

static char *run_probe(const char *in) {
  Buf b; binit(&b);
  char err[512];
  const char *stage = "parse";
  err[0] = 0;

  char *argv[MAXARGV + 1];
  int argc = 0;
  unsigned long *ips = NULL;
  void *ring = MAP_FAILED;
  size_t ringsz = 0, pagesz = 0;
  int fd = -1, ep0 = -1;
  pid_t pid = -1;
  int reaped = 0, st = 0, timed_out = 0, killed = 0, exec_done = 0;
  int kernel_excluded = 0;
  long lost = 0, dropped = 0;
  int nips = 0;
  long long t0 = now_ms();
  double spent = 0;
  int cap = 0, freq = 0, top = 0, secs = 0, want_kernel = 1, show_out = 0;

  secs = (int)jnum(in, "seconds", 600);
  if (secs < 1) secs = 1;
  if (secs > 3600) secs = 3600;
  freq = (int)jnum(in, "freq", 99);
  if (freq < 1) freq = 1;
  if (freq > 5000) freq = 5000;
  top = (int)jnum(in, "top", 20);
  if (top < 1) top = 1;
  if (top > 200) top = 200;
  cap = (int)jnum(in, "max_samples", DEFCAP);
  if (cap < 1000) cap = 1000;
  if (cap > MAXCAP) cap = MAXCAP;
  want_kernel = jbool(in, "kernel", 1);
  show_out = jbool(in, "show_output", 0);

  argc = jargv(in, argv, MAXARGV);
  if (argc <= 0) {
    argc = 0;
    char cmd[2048];
    if (jstr(in, "command", cmd, sizeof cmd) && cmd[0]) {
      char *dup = strdup(cmd), *p = dup;
      if (!dup) { snprintf(err, sizeof err, "out of memory"); goto out; }
      while (*p && argc < MAXARGV) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        char *s = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        int more = (*p != 0);
        *p = 0;
        argv[argc] = strdup(s);
        if (!argv[argc]) { free(dup); snprintf(err, sizeof err, "out of memory"); goto out; }
        argc++;
        if (!more) break;
        p++;
      }
      free(dup);
    }
  }
  if (argc <= 0) { snprintf(err, sizeof err, "缺 argv / command"); goto out; }
  argv[argc] = NULL;          /* execvp walks until NULL, not until argc */

  pagesz = (size_t)sysconf(_SC_PAGESIZE);
  if (pagesz < 4096) pagesz = 4096;
  ringsz = RING_SZ + pagesz;
  ips = malloc((size_t)cap * sizeof(unsigned long));
  if (!ips) { snprintf(err, sizeof err, "out of memory for %d samples", cap); goto out; }

  stage = "fork";
  int ep[2];
  if (pipe2(ep, O_CLOEXEC) != 0) { snprintf(err, sizeof err, "pipe2: %s", strerror(errno)); goto out; }
  pid = fork();
  if (pid < 0) { close(ep[0]); close(ep[1]); snprintf(err, sizeof err, "fork: %s", strerror(errno)); goto out; }
  if (pid == 0) {
    close(ep[0]);
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) {
      dup2(dn, 0);
      if (!show_out) { dup2(dn, 1); dup2(dn, 2); }
      if (dn > 2) close(dn);
    }
    raise(SIGSTOP);                 /* parent arms the counter, then SIGCONTs us */
    execvp(argv[0], argv);
    int ce = errno;
    ssize_t w = write(ep[1], &ce, sizeof ce);
    (void)w;
    _exit(127);
  }
  ep0 = ep[0];
  close(ep[1]);

  stage = "handshake";
  for (;;) {
    pid_t w = waitpid(pid, &st, WUNTRACED);
    if (w == pid) break;
    if (w < 0 && errno == EINTR) continue;
    snprintf(err, sizeof err, "waitpid: %s", strerror(errno));
    goto out;
  }
  if (!WIFSTOPPED(st)) {
    snprintf(err, sizeof err, "child did not stop (status 0x%x)", st);
    goto out;
  }

  stage = "perf_event_open";
  fd = open_counter(pid, freq, want_kernel, &kernel_excluded, err, sizeof err);
  if (fd < 0) goto out;

  ring = mmap(NULL, ringsz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (ring == MAP_FAILED) { snprintf(err, sizeof err, "mmap ring: %s", strerror(errno)); goto out; }

  stage = "run";
  if (kill(pid, SIGCONT) != 0) { snprintf(err, sizeof err, "SIGCONT: %s", strerror(errno)); goto out; }

  long long last_rf = 0;
  for (;;) {
    if (!exec_done) {
      int ce = 0;
      ssize_t rn = read(ep0, &ce, sizeof ce);
      if (rn == (ssize_t)sizeof ce) {
        snprintf(err, sizeof err, "execvp(%s): %s", argv[0], strerror(ce));
        stage = "exec";
        goto out;
      }
      if (rn <= 0 && (rn == 0 || (errno != EAGAIN && errno != EINTR))) {
        exec_done = 1;
        close(ep0); ep0 = -1;
        maps_read(pid); jit_load(pid);
        last_rf = now_ms();
      }
    }

    int room = cap - nips;
    int seen = drain(ring, pagesz, ips, nips, cap, &lost, &dropped);
    nips += (seen > room) ? room : seen;
    if (nips >= cap) { killed = 1; kill(pid, SIGKILL); break; }

    struct pollfd pf;
    pf.fd = fd; pf.events = POLLIN; pf.revents = 0;
    poll(&pf, 1, 10);

    pid_t w = waitpid(pid, &st, WNOHANG);
    if (w == pid) { reaped = 1; break; }
    if (w < 0 && errno != EINTR) { reaped = 1; break; }

    long long t = now_ms();
    if (exec_done && t - last_rf >= 250) { maps_read(pid); jit_load(pid); last_rf = t; }
    if (t - t0 >= (long long)secs * 1000) { timed_out = 1; killed = 1; kill(pid, SIGKILL); break; }
  }

  spent = (double)(now_ms() - t0) / 1000.0;
  if (ring != MAP_FAILED) {
    int room = cap - nips;
    int seen = drain(ring, pagesz, ips, nips, cap, &lost, &dropped);
    nips += (seen > room) ? room : seen;
  }
  if (ep0 >= 0) { close(ep0); ep0 = -1; }
  if (fd >= 0) { close(fd); fd = -1; }
  if (!reaped) {
    kill(pid, SIGKILL);
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    reaped = 1;
  }

  int ex = WIFEXITED(st) ? WEXITSTATUS(st) : 0;
  int sig = WIFSIGNALED(st) ? WTERMSIG(st) : 0;
  /* target 常在 main 收尾时才写 perf map（Chez AOT 的代码入口此刻才稳定），
     子进程已回收、/proc/<pid>/maps 已消失，但地图文件还在：补最后一次加载。 */
  if (!g_jit_loaded) jit_load(pid);
  stage = "attribute";

  /* ---- attribution ---------------------------------------------------- */
  static ObjTot obj[MAXOBJ];
  static SymTot sym[MAXHITS];
  int nobj = 0, nsym = 0, nsym_extra = 0;
  long n_anon = 0, n_jitv = 0, n_kern = 0, n_unmapped = 0;

  for (int i = 0; i < nips; i++) {
    unsigned long ip = ips[i];
    const char *oname = "[unmapped]";
    const char *sname = "[unmapped]";

    if (ip >= 0xffff800000000000UL) {
      oname = "[kernel]"; sname = "[k]"; n_kern++;
    } else {
      MapR *m = map_find(ip);
      if (m && m->path[0] == '/') {
        oname = base_name(m->path);
        Elf *e = elf_get(m->path);
        const char *s = elf_sym(e, ip - m->start + m->off);
        if (s) sname = s;
        else {
          s = elf_fde(e, ip - m->start + m->off);
          if (s) sname = s;
          else {                      /* 连 FDE 都没有：至少给 模块+偏移 */
            static char nb[160];
            snprintf(nb, sizeof nb, "%s+0x%lx", base_name(m->path), ip - m->start + m->off);
            sname = nb;
          }
        }
      } else if (m && m->path[0] == '[') {
        oname = m->path; sname = m->path;
      } else {
        if (m && m->path[0] == 0) n_anon++; else if (!m) n_unmapped++;
        const char *j = jit_sym(ip);
        if (j) { oname = "[jit]"; sname = j; n_jitv++; }
        else if (m) { oname = "[anon]"; sname = "[anon]"; }
      }
    }

    int k;
    for (k = 0; k < nobj; k++) if (!strcmp(obj[k].name, oname)) break;
    if (k == nobj && nobj < MAXOBJ) { snprintf(obj[nobj].name, sizeof obj[nobj].name, "%s", oname); obj[nobj].n = 0; nobj++; }
    if (k < nobj) obj[k].n++;

    for (k = 0; k < nsym; k++) if (!strcmp(sym[k].sym, sname) && !strcmp(sym[k].obj, oname)) break;
    if (k == nsym) {
      if (nsym < MAXHITS) {
        snprintf(sym[nsym].sym, sizeof sym[nsym].sym, "%s", sname);
        snprintf(sym[nsym].obj, sizeof sym[nsym].obj, "%s", oname);
        sym[nsym].n = 0;
        nsym++;
      } else nsym_extra++;
    }
    if (k < nsym) sym[k].n++;
  }
  if (nsym_extra) { /* fold overflow into one bucket */
    if (nsym < MAXHITS) { snprintf(sym[nsym].sym, sizeof sym[nsym].sym, "[+%d more]", nsym_extra); snprintf(sym[nsym].obj, sizeof sym[nsym].obj, "-"); sym[nsym].n = nsym_extra; nsym++; }
  }

  qsort(obj, (size_t)nobj, sizeof obj[0], objcmp);
  qsort(sym, (size_t)nsym, sizeof sym[0], symcmp_n);

  double dn = nips > 0 ? (double)nips : 1.0;
  bputs(&b, "{\"ok\":1,\"target\":");
  bjstr(&b, base_name(argv[0]));
  bprintf(&b, ",\"samples\":%d,\"lost\":%ld,\"dropped\":%ld,\"exit\":%d,\"signal\":%d", nips, lost, dropped, ex, sig);
  bprintf(&b, ",\"killed\":%d,\"seconds\":%.3f,\"timed_out\":%d", killed && !timed_out ? 1 : 0, spent, timed_out);
  bprintf(&b, ",\"maps\":%d,\"maps_truncated\":%d,\"freq\":%d,\"cap\":%d", g_nmap, g_map_trunc, freq, cap);
  bprintf(&b, ",\"kernel_excluded\":%d,\"truncated\":%d", kernel_excluded, (lost > 0 || dropped > 0));
  bprintf(&b, ",\"anon_pct\":%.1f,\"jit_pct\":%.1f,\"kernel_pct\":%.1f,\"unmapped_pct\":%.1f",
          100.0 * (double)n_anon / dn, 100.0 * (double)n_jitv / dn, 100.0 * (double)n_kern / dn,
          100.0 * (double)n_unmapped / dn);
  if (nips == 0) {
    bputs(&b, ",\"hint\":");
    bjstr(&b, kernel_excluded
      ? "0 个样本：目标比 1/freq 秒还短，或 CPU 未调度到它（内核计数被 paranoid 关掉了）"
      : "0 个样本：目标比 1/freq 秒还短，或 CPU 未调度到它");
  } else if (g_elf_full) {
    bprintf(&b, ",\"elf_cache_full\":%ld", g_elf_full);
  }
  bputs(&b, ",\"objects\":[");
  for (int i = 0; i < nobj && i < top; i++)
    bprintf(&b, "%s{\"name\":\"%s\",\"samples\":%d,\"pct\":%.1f}",
            i ? "," : "", obj[i].name, obj[i].n, 100.0 * (double)obj[i].n / dn);
  bputs(&b, "],\"symbols\":[");
  for (int i = 0; i < nsym && i < top; i++) {
    bputs(&b, i ? ",{\"symbol\":" : "{\"symbol\":");
    bjstr(&b, sym[i].sym);
    bputs(&b, ",\"object\":");
    bjstr(&b, sym[i].obj);
    bprintf(&b, ",\"samples\":%d,\"pct\":%.1f}", sym[i].n, 100.0 * (double)sym[i].n / dn);
  }
  bputs(&b, "]}");

out:
  if (ring != MAP_FAILED) munmap(ring, ringsz);
  if (fd >= 0) close(fd);
  if (ep0 >= 0) close(ep0);
  if (pid > 0 && !reaped) {
    kill(pid, SIGKILL);
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
  }
  elf_release_all();
  jit_free();
  free(ips);
  freeargv(argv, argc);
  if (err[0]) {
    b.n = 0; if (b.p) b.p[0] = 0;
    bprintf(&b, "{\"ok\":0,\"samples\":0,\"exit\":0,\"freq\":%d,\"stage\":", freq);
    bjstr(&b, stage);
    bputs(&b, ",\"error\":");
    bjstr(&b, err);
    bputs(&b, "}");
  }
  return b.p;
}

char *lite_helper(const char *input) { return run_probe(input && input[0] ? input : "{}"); }
void lite_helper_free(char *out) { free(out); }
