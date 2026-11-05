/*
 * metrics.h — Structured logging and Prometheus metrics
 * 
 * Usage:
 *   LOG_INFO("import.started", "book=%s pages=%d", title, pages);
 *   METRIC_COUNTER_INC("mydb_imports_total", "format=epub");
 *   METRIC_TIMER_RECORD("mydb_import_duration_seconds", "format=epub", 11.2);
 * 
 * Prometheus export:
 *   metrics_prometheus_write("/tmp/metrics.txt");
 */

#ifndef METRICS_H
#define METRICS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ====== Structured Logging ======
// Output: {"ts":"2024-01-15T10:30:00Z","level":"INFO","event":"import.started","book":"DDIA","pages":500}

void log_json(const char* level, const char* event, const char* fmt, ...);

#define LOG_DEBUG(event, ...) log_json("DEBUG", event, __VA_ARGS__)
#define LOG_INFO(event, ...)  log_json("INFO",  event, __VA_ARGS__)
#define LOG_WARN(event, ...)  log_json("WARN",  event, __VA_ARGS__)
#define LOG_ERROR(event, ...) log_json("ERROR", event, __VA_ARGS__)

// ====== Metrics ======

typedef struct metric_counter metric_counter_t;
typedef struct metric_timer  metric_timer_t;

// Counter (monotonically increasing)
void metric_counter_inc(const char* name, const char* labels, double amount);
#define METRIC_COUNTER_INC(name, labels) metric_counter_inc(name, labels, 1.0)

// Timer (records duration in seconds)
void metric_timer_record(const char* name, const char* labels, double seconds);

// Convenience: start/stop timer
typedef struct { const char* name; const char* labels; double start; } metric_timer_ctx_t;
metric_timer_ctx_t metric_timer_start(const char* name, const char* labels);
void metric_timer_stop(metric_timer_ctx_t* ctx);

// ====== Prometheus Export ======
// Write all metrics in Prometheus text format
int metrics_prometheus_write(const char* filepath);

// Write metrics to a string buffer (caller provides buffer)
int metrics_prometheus_format(char* buf, size_t buf_size);

// Reset all metrics (useful for testing)
void metrics_reset(void);

#ifdef __cplusplus
}
#endif

#endif
