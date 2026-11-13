/* native.c — C 内核示例 + 两种 ABI。
 *
 * 纪律（见 templates/PROJECT_STANDARD.md §3）：
 *   - 不 exit / 不 abort / 不往 stdout 打日志（stdout 是数据通道）
 *   - 错误走 <name>_error()，返回状态码
 *   - 返回堆字符串的必须配套 <name>_free
 *   - 热路径批量进出，别把循环搬回 Lua
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- 可见性：默认隐藏，只导出 ABI 面 ---- */
#define API __attribute__((visibility("default")))

static char g_err[512];

static void set_err(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
}

/* ---- 库型 ABI：状态码 + _error() ---- */

API const char *@NAME@_error(void) { return g_err; }

API int @NAME@_add(int a, int b)
{
    if ((b > 0 && a > 2147483647 - b) || (b < 0 && a < -2147483648 - b)) {
        set_err("overflow: %d + %d", a, b);
        return -1;
    }
    return a + b;
}

/* ---- 工具型 ABI：JSON in / JSON out（给 native 工具与插件）---- */

static int json_int(const char *s, const char *key, int *out)
{
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(s, pat);
    if (!p)
        return 0;
    p += strlen(pat);
    while (*p == ' ' || *p == ':' || *p == '\t')
        p++;
    if (!*p)
        return 0;
    char *end = NULL;
    long v = strtol(p, &end, 10);
    if (end == p)
        return 0;
    *out = (int)v;
    return 1;
}

static char *xstrdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p)
        memcpy(p, s, n);
    return p;
}

API char *lite_helper(const char *input)
{
    char buf[1200];
    int a = 0, b = 0;
    if (!input) {
        set_err("input is NULL");
        snprintf(buf, sizeof buf, "{\"ok\":false,\"error\":\"%s\"}", g_err);
        return xstrdup(buf);
    }
    if (!json_int(input, "a", &a) || !json_int(input, "b", &b)) {
        set_err("missing required key: a, b (got: %.120s)", input);
        snprintf(buf, sizeof buf, "{\"ok\":false,\"error\":\"%s\",\"required\":[\"a\",\"b\"]}", g_err);
        return xstrdup(buf);
    }
    int r = @NAME@_add(a, b);
    if (r < 0)
        snprintf(buf, sizeof buf, "{\"ok\":false,\"error\":\"%s\"}", g_err);
    else
        snprintf(buf, sizeof buf, "{\"ok\":true,\"result\":%d}", r);
    return xstrdup(buf);
}

API void lite_helper_free(char *p) { free(p); }
