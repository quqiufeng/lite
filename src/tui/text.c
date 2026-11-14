/* lite TUI 文本内核：显示宽度 / 折行 / 逐字符 cell / 行内词级 diff。
 *
 * 为什么在 C 里：TUI 每帧要按显示宽度折行 + 填 cell，Lua 版每字符一次
 * `utf8.decode`（3~4 次 s:byte + 一个 s:sub）和一次 wcwidth FFI 调用，
 * 大 diff 一帧几十万次，实测 diff 布局占整帧 29%。这里把「按宽度走字符」
 * 的三个热循环各做成一次 FFI 调用，Lua 侧只处理「行 run」而不是「字符」。
 *
 * 语义必须与 lua/tui/utf8.lua + diff_layout.wrap_segments 逐位一致：
 *   - 非法/不完整 UTF-8 字节：当宽度 1 的单字节字符（不跳过、不合并）。
 *   - 组合字符（wcwidth == 0）：宽度 0，折行时不占列，put 时挂到前一 cell。
 *   - 超宽字符（cw > width）：col == 0 时仍然落行首（宁可溢出也不空走一行）。
 *   - 文本末尾的 '\n' 产生一个末尾空行（wrap 的行数语义）。
 * 任何缓冲区装不下都返回负数（= 需要多少个），调用方回退纯 Lua 实现——
 * 这里不允许「悄悄截断」。
 *
 * 全部函数无状态、无分配（除 intraline 的 DP 缓冲），可多线程调用。
 */
/* wcwidth 是 XSI 扩展：不给 _XOPEN_SOURCE 时 glibc 只给隐式声明，
 * 返回值按 int 传会碰运气（x86_64 上通常对，但 -Wall 会一直警告）。 */
#define _XOPEN_SOURCE 700
#include <locale.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define TUI_OK 0

static int tui_locale_ready = 0;

static void tui_ensure_locale(void)
{
    if (!tui_locale_ready) {
        setlocale(LC_CTYPE, "");
        tui_locale_ready = 1;
    }
}

/* 解一个 UTF-8 字符：返回消耗字节数（>=1），cp 为码点。
 * 非法序列按单字节处理（cp = 该字节），与原 Lua 实现一致。 */
static int tui_dec(const unsigned char *s, int n, int i, uint32_t *cp)
{
    unsigned char b1 = s[i];
    if (b1 < 0x80) {
        *cp = b1;
        return 1;
    }
    int len;
    uint32_t c;
    if (b1 < 0xC0) { /* 孤立续字节 */
        *cp = b1;
        return 1;
    } else if (b1 < 0xE0) {
        len = 2; c = b1 - 0xC0u;
    } else if (b1 < 0xF0) {
        len = 3; c = b1 - 0xE0u;
    } else {
        len = 4; c = b1 - 0xF0u;
    }
    if (i + len > n) {
        *cp = b1;
        return 1;
    }
    for (int k = 1; k < len; k++) {
        unsigned char b = s[i + k];
        if (b < 0x80 || b >= 0xC0) {
            *cp = b1;
            return 1;
        }
        c = c * 64u + (uint32_t)(b - 0x80);
    }
    *cp = c;
    return len;
}

/* 显示宽度：组合字符 0，异常（wcwidth < 0）按 1。 */
static int tui_width_cp(uint32_t cp)
{
    int w = wcwidth((wint_t)cp);
    if (w < 0) return 1;
    return w;
}

/* ---------- 1. 显示宽度 ---------- */

int lite_tui_width(const char *str, int n)
{
    if (!str || n <= 0) return 0;
    tui_ensure_locale();
    const unsigned char *s = (const unsigned char *)str;
    int w = 0, i = 0;
    while (i < n) {
        uint32_t cp;
        int len = tui_dec(s, n, i, &cp);
        w += tui_width_cp(cp);
        i += len;
    }
    return w;
}

/* ---------- 2. 折行（纯文本 / 带样式段） ---------- */

/* 只有行数需求时用它（比 wrap_segs 少一次输出组装）。 */
int lite_tui_count_lines(const char *str, int n, int width)
{
    if (!str || n <= 0) return 0;
    tui_ensure_locale();
    if (width < 1) width = 1;
    const unsigned char *s = (const unsigned char *)str;
    int lines = 1, col = 0, i = 0;
    while (i < n) {
        uint32_t cp;
        int len = tui_dec(s, n, i, &cp);
        if (cp == '\n') {
            lines++;
            col = 0;
        } else {
            int cw = tui_width_cp(cp);
            if (col + cw > width && col > 0) {
                lines++;
                col = 0;
            }
            col += cw;
        }
        i += len;
    }
    return lines;
}

/* 每行起始字节偏移（0 基），breaks[k] = 第 k 行起始。
 * 返回行数；缓冲区不够返回 -(需要的行数)。 */
int lite_tui_wrap(const char *str, int n, int width, int *breaks, int maxbreaks)
{
    if (!str || n <= 0) {
        if (breaks && maxbreaks > 0) breaks[0] = 0;
        return 1;
    }
    tui_ensure_locale();
    if (width < 1) width = 1;
    const unsigned char *s = (const unsigned char *)str;
    int lines = 1, col = 0, i = 0;
    if (breaks && maxbreaks > 0) breaks[0] = 0;
    while (i < n) {
        uint32_t cp;
        int len = tui_dec(s, n, i, &cp);
        int newline = 0;
        if (cp == '\n') {
            newline = 1;
        } else {
            int cw = tui_width_cp(cp);
            if (col + cw > width && col > 0) newline = 1;
        }
        if (newline) {
            if (breaks && lines < maxbreaks) breaks[lines] = i + (cp == '\n' ? len : 0);
            lines++;
            col = 0;
            if (cp == '\n') {
                i += len;
                continue;
            }
            /* 字符本身落到新行，不重新消费——下面照常累加宽度 */
            col = tui_width_cp(cp);
        } else {
            col += tui_width_cp(cp);
        }
        i += len;
    }
    if (breaks && lines > maxbreaks) return -lines;
    return lines;
}

/* 带样式段折行：segs 的文本已拼成 s，segoff[i] 是第 i 段起始（0 基），
 * segoff[nseg] == n。输出 run：每 4 个 int 一组
 *   [0] 行号（0 基） [1] s 内起始字节 [2] 字节长度 [3] 段号（0 基）
 * 返回 run 数；缓冲区不够返回 -(需要的 run 数)；*out_lines 写总行数。
 * 一行的段可能被折行切开（同一段号出现两次），所以 Lua 侧按 run 组装。 */
int lite_tui_wrap_segs(const char *str, int n, const int *segoff, int nseg,
                       int width, int *out, int maxruns, int *out_lines)
{
    tui_ensure_locale();
    if (width < 1) width = 1;
    if (out_lines) *out_lines = 1;
    if (!str || n <= 0 || !segoff || nseg <= 0) return 0;

    const unsigned char *s = (const unsigned char *)str;
    int lines = 1, col = 0, i = 0, runs = 0;
    int seg = 0;              /* 当前段号，随 i 前进单调递增 */
    int run_start = 0, run_seg = 0, run_line = 0;
    int open = 0;

    while (i < n) {
        while (seg + 1 < nseg && i >= segoff[seg + 1]) seg++;

        uint32_t cp;
        int len = tui_dec(s, n, i, &cp);
        int brk = 0;      /* 换行（字符本身丢弃） */
        int soft = 0;     /* 折行（字符落到新行） */
        if (cp == '\n') {
            brk = 1;
        } else {
            int cw = tui_width_cp(cp);
            if (col + cw > width && col > 0) soft = 1;
        }

        if (brk || soft) {
            if (open) {
                if (runs >= maxruns) return -(runs + 1);
                out[runs * 4 + 0] = run_line;
                out[runs * 4 + 1] = run_start;
                out[runs * 4 + 2] = i - run_start;
                out[runs * 4 + 3] = run_seg;
                runs++;
                open = 0;
            }
            lines++;
            col = 0;
            if (brk) {
                i += len;
                run_line = lines - 1;
                run_start = i;
                run_seg = seg;
                continue;
            }
            run_line = lines - 1;
            run_start = i;
            run_seg = seg;
            open = 1;
            col = tui_width_cp(cp);
            i += len;
            continue;
        }

        if (!open) {
            run_start = i;
            run_seg = seg;
            run_line = lines - 1;
            open = 1;
        } else if (seg != run_seg) {
            /* 段边界：先收口上一个 run，再从当前位置开新 run */
            if (runs >= maxruns) return -(runs + 1);
            out[runs * 4 + 0] = run_line;
            out[runs * 4 + 1] = run_start;
            out[runs * 4 + 2] = i - run_start;
            out[runs * 4 + 3] = run_seg;
            runs++;
            run_start = i;
            run_seg = seg;
            open = 1;
        }
        col += tui_width_cp(cp);
        i += len;
    }

    if (open) {
        if (runs >= maxruns) return -(runs + 1);
        out[runs * 4 + 0] = run_line;
        out[runs * 4 + 1] = run_start;
        out[runs * 4 + 2] = i - run_start;
        out[runs * 4 + 3] = run_seg;
        runs++;
    }
    if (out_lines) *out_lines = lines;
    return runs;
}

/* ---------- 3. 逐字符 cell ---------- */

/* 把 s 解成显示单元，每 3 个 int 一组：[起始字节, 字节长, 显示宽度]。
 * 宽度为 0 的（组合字符）调用方挂到前一个 cell 上。返回单元数，
 * 缓冲区不够返回 -(需要多少)。 */
int lite_tui_cells(const char *str, int n, int *out, int maxcells)
{
    if (!str || n <= 0) return 0;
    tui_ensure_locale();
    const unsigned char *s = (const unsigned char *)str;
    int i = 0, cells = 0;
    while (i < n) {
        uint32_t cp;
        int len = tui_dec(s, n, i, &cp);
        if (cp != '\n') {
            if (cells >= maxcells) return -(cells + 1);
            out[cells * 3 + 0] = i;
            out[cells * 3 + 1] = len;
            out[cells * 3 + 2] = tui_width_cp(cp);
            cells++;
        }
        i += len;
    }
    return cells;
}

/* ---------- 4. 行内词级 diff ---------- */

/* a/b 是已 intern 成整数的 token 序列。行内 LCS + 回溯，
 * 输出「正向」编辑脚本，每个 int 一个操作：
 *   0 = 引用双方（a[ia++], b[ib++] 相等）
 *   1 = 只在 a（删除）    2 = 只在 b（新增）
 * 返回操作数；dp 缓冲分配失败或超限返回 -1（调用方回退 Lua 实现）。
 * max_ops 写满返回 -(需要多少)。 */
int lite_tui_intraline(const int *a, int na, const int *b, int nb,
                       unsigned char *ops, int max_ops)
{
    if (na < 0 || nb < 0) return -1;
    if (na == 0 && nb == 0) return 0;
    if (na == 0) {
        if (nb > max_ops) return -nb;
        memset(ops, 2, (size_t)nb);
        return nb;
    }
    if (nb == 0) {
        if (na > max_ops) return -na;
        memset(ops, 1, (size_t)na);
        return na;
    }

    size_t cells = (size_t)(na + 1) * (size_t)(nb + 1);
    if (cells > (size_t)20000) return -1;
    uint16_t *dp = (uint16_t *)malloc(cells * sizeof(uint16_t));
    if (!dp) return -1;
    memset(dp, 0, cells * sizeof(uint16_t));

    size_t stride = (size_t)(nb + 1);
#define DP(i, j) dp[(size_t)(i) * stride + (size_t)(j)]
    for (int i = 1; i <= na; i++) {
        for (int j = 1; j <= nb; j++) {
            if (a[i - 1] == b[j - 1]) {
                DP(i, j) = (uint16_t)(DP(i - 1, j - 1) + 1);
            } else {
                uint16_t x = DP(i - 1, j), y = DP(i, j - 1);
                DP(i, j) = x > y ? x : y;
            }
        }
    }

    /* 回溯装进倒序缓冲，再翻转成正向脚本 */
    int need = na + nb;
    unsigned char *rev = (unsigned char *)malloc((size_t)need);
    if (!rev) {
        free(dp);
        return -1;
    }
    int k = 0, i = na, j = nb;
    while (i > 0 && j > 0) {
        if (a[i - 1] == b[j - 1]) {
            rev[k++] = 0;
            i--; j--;
        } else if (DP(i - 1, j) >= DP(i, j - 1)) {
            rev[k++] = 1;
            i--;
        } else {
            rev[k++] = 2;
            j--;
        }
    }
    while (i > 0) { rev[k++] = 1; i--; }
    while (j > 0) { rev[k++] = 2; j--; }
#undef DP
    free(dp);

    if (k > max_ops) {
        free(rev);
        return -k;
    }
    for (int t = 0; t < k; t++) ops[t] = rev[k - 1 - t];
    free(rev);
    return k;
}
