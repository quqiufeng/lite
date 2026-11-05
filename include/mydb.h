#ifndef MYDB_H
#define MYDB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ====== 不透明句柄 ======
typedef struct db_instance* db_t;
typedef struct db_table*    table_t;
typedef struct db_cursor*   cursor_t;
typedef uint64_t            rowid_t;

// ====== 错误码 ======
enum {
    DB_OK                    =  0,
    DB_ERR_NOMEM             = -1,
    DB_ERR_IO                = -2,
    DB_ERR_NOENT             = -3,
    DB_ERR_EXIST             = -4,
    DB_ERR_INVAL             = -5,
    DB_ERR_RESULT_TOO_LARGE  = -6,
    DB_ERR_CORRUPTED         = -7,
    DB_ERR_WAL_REPLAY        = -8,
};

// ====== 字段类型 ======
enum db_field_type {
    DB_TYPE_INT32,
    DB_TYPE_INT64,
    DB_TYPE_UINT64,
    DB_TYPE_FLOAT,
    DB_TYPE_DOUBLE,
    DB_TYPE_STRING,
    DB_TYPE_VARSTRING,
    DB_TYPE_BOOL,
};

// ====== 字段定义（Schema） ======
typedef struct {
    const char* name;
    size_t      offset;
    size_t      size;
    int         type;
} db_field_def_t;

// ====== WHERE 条件 ======
typedef struct {
    size_t      field_offset;
    size_t      field_size;
    const void* value;
    int         op;            // 0=等于, 1=大于, 2=小于
} db_condition_t;

// ====== 流式查询回调 ======
typedef int (*db_row_cb_t)(const char* json, void* user_data);

// ====== 数据库 ======
db_t db_open(const char* db_dir, size_t pool_size);
void db_close(db_t db);
int  db_sync(db_t db);

// 数据库诊断：检查完整性，返回 0=正常，负数=错误码
int db_check(const char* db_dir);
const char* db_errstr(db_t db);

// ====== 配置 ======
void db_config_max_rows(db_t db, size_t max_rows);

// ====== WAL 恢复 / Checkpoint ======
int db_wal_replay(db_t db);
int db_checkpoint(db_t db);

// ====== Schema 注册（编译时宏自动生成调用）=====
table_t db_table_register(db_t db, const char* name, size_t row_size,
                          const db_field_def_t* fields, size_t field_count);
table_t db_table(db_t db, const char* name);
int     db_table_drop  (db_t db, const char* name);
size_t  db_table_count (table_t table);

// ====== 索引 ======
int db_table_add_index(table_t table, const char* field_name, size_t field_offset, int field_type);
int db_table_add_index_composite(table_t table, db_field_def_t* fields, size_t field_count);

// ====== CRUD ======
rowid_t db_insert(table_t table, const void* row, size_t row_size);
size_t  db_batch_insert(table_t table, const void* rows, size_t row_size, size_t count);

int db_update(table_t table, rowid_t id, const void* row, size_t row_size);
int db_delete(table_t table, rowid_t id);

// ====== 查询 - 完整 JSON 模式 ======
const char* db_select_by_pk_json(table_t table, rowid_t id);
const char* db_select_all_json(table_t table);
const char* db_select_where_json(table_t table,
                                 const db_condition_t* conditions,
                                 size_t condition_count);
const char* db_select_json(table_t table,
                            const db_condition_t* conditions, size_t condition_count,
                            size_t order_field_offset, int ascending,
                            size_t limit_offset, size_t limit_count);
const char* db_join_json(table_t left_table,  size_t left_field_offset,
                          table_t right_table, size_t right_field_offset,
                          size_t field_size);
void db_json_free(const char* json);

// ====== 查询 - 流式模式 ======
int db_select_all_stream(table_t table, db_row_cb_t cb, void* user_data);
int db_select_where_stream(table_t table,
                           const db_condition_t* conditions, size_t condition_count,
                           db_row_cb_t cb, void* user_data);
int db_select_stream(table_t table,
                     const db_condition_t* conditions, size_t condition_count,
                     size_t order_field_offset, int ascending,
                     size_t limit_offset, size_t limit_count,
                     db_row_cb_t cb, void* user_data);

// ====== Compact（内存回收）=====
size_t db_table_compact(table_t table);
size_t db_compact(db_t db);

// ====== 事务 ======
int db_begin  (db_t db);
int db_commit (db_t db);
int db_rollback(db_t db);

// ====== 编译时宏：自动注册 Schema ======
// DB_FIELD 直接引用 struct 名称，不需要 typedef
#define DB_FIELD(struct_name, field_name, field_type) \
    {#field_name, offsetof(struct struct_name, field_name), sizeof(((struct struct_name*)0)->field_name), field_type}

// DB_TABLE：生成注册函数
#define DB_TABLE(struct_name, table_name_str, ...) \
    static void db_register_##struct_name(db_t db) { \
        db_field_def_t fields[] = {__VA_ARGS__}; \
        db_table_register(db, table_name_str, sizeof(struct struct_name), fields, sizeof(fields)/sizeof(fields[0])); \
    }

// ====== 版本信息 ======
const char* mydb_version(void);
int         mydb_version_major(void);
int         mydb_version_minor(void);
int         mydb_version_patch(void);

#ifdef __cplusplus
}
#endif

#endif
