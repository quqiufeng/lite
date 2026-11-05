/*
 * metrics.c — Structured logging and Prometheus metrics implementation
 */

#include "metrics.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdarg.h>
#include <math.h>

#define MAX_METRICS 256
#define MAX_LABELS  256
#define MAX_NAME_LEN 64

// Simple in-memory metric storage (not thread-safe, meant for single-threaded batch operations)
typedef struct {
    char name[MAX_NAME_LEN];
    char labels[MAX_LABELS];
    double value;
    int type;  // 0=counter, 1=timer/summary
} metric_entry_t;

static metric_entry_t g_metrics[MAX_METRICS];
static int g_metric_count = 0;

static metric_entry_t* find_or_create(const char* name, const char* labels, int type) {
    for (int i = 0; i < g_metric_count; i++) {
        if (strcmp(g_metrics[i].name, name) == 0 && strcmp(g_metrics[i].labels, labels) == 0) {
            return &g_metrics[i];
        }
    }
    if (g_metric_count >= MAX_METRICS) return NULL;
    metric_entry_t* m = &g_metrics[g_metric_count++];
    strncpy(m->name, name, MAX_NAME_LEN - 1);
    m->name[MAX_NAME_LEN - 1] = '\0';
    strncpy(m->labels, labels, MAX_LABELS - 1);
    m->labels[MAX_LABELS - 1] = '\0';
    m->value = 0;
    m->type = type;
    return m;
}

// ====== Logging ======

static void timestamp_iso8601(char* buf, size_t size) {
    time_t now = time(NULL);
    struct tm* tm = gmtime(&now);
    snprintf(buf, size, "%04d-%02d-%02dT%02d:%02d:%02dZ",
             tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
             tm->tm_hour, tm->tm_min, tm->tm_sec);
}

void log_json(const char* level, const char* event, const char* fmt, ...) {
    char ts[32];
    timestamp_iso8601(ts, sizeof(ts));
    
    // Build the extra fields from fmt
    char fields[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(fields, sizeof(fields), fmt, args);
    va_end(args);
    
    // Output JSON line
    fprintf(stderr, "{\"ts\":\"%s\",\"level\":\"%s\",\"event\":\"%s\"", ts, level, event);
    if (fields[0]) {
        fprintf(stderr, ",%s", fields);
    }
    fprintf(stderr, "}\n");
}

// ====== Metrics ======

void metric_counter_inc(const char* name, const char* labels, double amount) {
    metric_entry_t* m = find_or_create(name, labels, 0);
    if (m) m->value += amount;
}

void metric_timer_record(const char* name, const char* labels, double seconds) {
    metric_entry_t* m = find_or_create(name, labels, 1);
    if (m) {
        // Simple: store sum and count in the same entry for now
        // value = sum, we track count separately... actually let's just store average
        // For simplicity, store total time and we'll count occurrences
        m->value += seconds;
    }
}

metric_timer_ctx_t metric_timer_start(const char* name, const char* labels) {
    metric_timer_ctx_t ctx;
    ctx.name = name;
    ctx.labels = labels;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ctx.start = ts.tv_sec + ts.tv_nsec * 1e-9;
    return ctx;
}

void metric_timer_stop(metric_timer_ctx_t* ctx) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double end = ts.tv_sec + ts.tv_nsec * 1e-9;
    double duration = end - ctx->start;
    if (duration < 0) duration = 0;
    metric_timer_record(ctx->name, ctx->labels, duration);
}

// ====== Prometheus Export ======

int metrics_prometheus_format(char* buf, size_t buf_size) {
    char* p = buf;
    char* end = buf + buf_size;
    
    // Count occurrences for timer metrics
    // For simplicity, we'll just output what we have
    // In a real implementation, you'd track count/sum/buckets
    
    int n = snprintf(p, end - p, "# MyDB Metrics\n");
    if (n < 0 || n >= end - p) return -1;
    p += n;
    
    for (int i = 0; i < g_metric_count; i++) {
        metric_entry_t* m = &g_metrics[i];
        if (m->labels[0]) {
            n = snprintf(p, end - p, "%s{%s} %.6f\n", m->name, m->labels, m->value);
        } else {
            n = snprintf(p, end - p, "%s %.6f\n", m->name, m->value);
        }
        if (n < 0 || n >= end - p) return -1;
        p += n;
    }
    
    return (int)(p - buf);
}

int metrics_prometheus_write(const char* filepath) {
    char buf[16384];
    int len = metrics_prometheus_format(buf, sizeof(buf));
    if (len < 0) return -1;
    
    FILE* fp = fopen(filepath, "w");
    if (!fp) return -1;
    fwrite(buf, 1, len, fp);
    fclose(fp);
    return 0;
}

void metrics_reset(void) {
    g_metric_count = 0;
}
