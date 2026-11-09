#ifndef LITE_CS_COMPAT_H
#define LITE_CS_COMPAT_H

// 从 my_db 的 CLI 工具移植进来时，所有日志都走 stderr：
// lite 的 TUI/serve 占用 stdout，库内 printf 会污染界面和 JSON 通道。
#include <stdio.h>
#include <stdarg.h>

static inline void lite_cs_logf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static inline void lite_cs_puts(const char* s) {
    fputs(s, stderr);
    fputc('\n', stderr);
}

#define printf lite_cs_logf
#define puts lite_cs_puts

#endif
