// CMySQLClient —— libmysqlclient 的薄封装层
//
// 设计说明见 docs/tech-designs/03-mysql-layer.md
//
// 这一层的职责：
//   1. 隔离 mysql.h 的宏与结构体，让 Swift 只看到简单类型
//   2. 提供行级回调接口，避免一次性把大结果集读进内存
//   3. 不抛异常；错误通过返回值 + err 缓冲传递
//
// 线程约定（重要）：
//   除 mtl_conn_cancel 之外，所有函数都必须在**同一条串行队列**上调用。
//   MTLConn 内部持有的 MYSQL* 不是线程安全的。
//
// 指针有效期：
//   mTLColumn 里的字符串指针指向 libmysqlclient 的结果集内部缓冲，
//   仅在本次回调期间有效。上层必须在回调返回前复制走。

#ifndef C_MYSQL_CLIENT_H
#define C_MYSQL_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MTL_ERRBUF_SIZE 512

typedef struct MTLConn MTLConn;

/* ------------------------------------------------------------------ */
/* 列元数据                                                            */
/* ------------------------------------------------------------------ */
typedef struct {
    const char  *name;            /* 结果集列名（可能是别名） */
    const char  *original_name;   /* 原始列名 org_name */
    const char  *table;           /* 结果集中的表名（可能是别名） */
    const char  *original_table;  /* 原始表名 org_table */
    const char  *database;        /* 所属库 db */
    unsigned int type;            /* enum_field_types */
    unsigned int flags;           /* NOT_NULL_FLAG / PRI_KEY_FLAG / UNSIGNED_FLAG /
                                     BINARY_FLAG / AUTO_INCREMENT_FLAG / BLOB_FLAG ... */
    unsigned int charset_nr;      /* 字符集编号，63 = binary */
    unsigned int length;          /* 显示宽度 */
    unsigned int decimals;        /* 小数位数 */
} MTLColumn;

/* ------------------------------------------------------------------ */
/* 一行数据                                                            */
/* ------------------------------------------------------------------ */
typedef struct {
    int                  result_index;  /* 第几个结果集，从 0 开始 */
    long long            row_index;     /* 结果集内行序号，从 0 开始 */
    int                  column_count;
    const char *const   *values;        /* values[i] == NULL 表示 SQL NULL */
    const unsigned long *lengths;       /* 每列的字节长度（不含结尾 \0） */
} MTLRow;

/* ------------------------------------------------------------------ */
/* 结果集开始                                                          */
/* ------------------------------------------------------------------ */
typedef struct {
    int                result_index;
    int                column_count;     /* >0 表示结果集；==0 表示 OK / 影响行数 */
    long long          affected_rows;
    unsigned long long last_insert_id;
    const MTLColumn   *columns;          /* column_count == 0 时为 NULL */
} MTLResultSet;

/* ------------------------------------------------------------------ */
/* 回调集合                                                            */
/* ------------------------------------------------------------------ */
typedef struct {
    void *ctx;

    /* 每个结果集开始时回调一次 */
    void (*on_result_set)(void *ctx, const MTLResultSet *rs);

    /* 每行回调一次；返回非 0 表示上层要求中止 */
    int  (*on_row)(void *ctx, const MTLRow *row);

    /* 语句级错误：记录后继续处理后续结果集 */
    void (*on_statement_error)(void *ctx, int result_index,
                               unsigned int code, const char *sqlstate,
                               const char *message);
} MTLCallbacks;

/* ------------------------------------------------------------------ */
/* 返回值                                                              */
/* ------------------------------------------------------------------ */
enum {
    MTL_OK          = 0,
    MTL_ERR_INVALID = -1,
    MTL_CANCELLED   = 2,
    MTL_ERR_SQL     = 3
};

/* ------------------------------------------------------------------ */
/* 连接生命周期                                                        */
/* ------------------------------------------------------------------ */

MTLConn *mtl_conn_create(void);
void     mtl_conn_free(MTLConn *c);

/* 以下三项须在 mtl_conn_open 之前调用 */
void mtl_conn_set_ssl(MTLConn *c, int use_ssl, int skip_verify);
void mtl_conn_set_connect_timeout(MTLConn *c, unsigned int seconds);
void mtl_conn_set_read_write_timeout(MTLConn *c, unsigned int seconds);

/*
 * 建立连接。password / database / charset / unix_socket 均可为 NULL。
 * 返回 MTL_OK 成功；失败返回非 0 并把错误文本写入 err。
 */
int  mtl_conn_open(MTLConn *c,
                   const char *host, unsigned int port,
                   const char *user, const char *password,
                   const char *database, const char *charset,
                   const char *unix_socket,
                   char *err, size_t err_len);

void mtl_conn_close(MTLConn *c);
int  mtl_conn_is_open(MTLConn *c);

/* 保活心跳。返回 0 正常 */
int mtl_conn_ping(MTLConn *c);

/* 服务器线程 id，用于从另一条连接发 KILL QUERY */
unsigned long mtl_conn_thread_id(MTLConn *c);

/* 最近一次错误的 errno；error / sqlstate 的指针在下一次调用前有效 */
unsigned int mtl_conn_errno(MTLConn *c);
const char  *mtl_conn_error(MTLConn *c);
const char  *mtl_conn_sqlstate(MTLConn *c);

const char *mtl_conn_server_version(MTLConn *c);
const char *mtl_conn_server_info(MTLConn *c);

/* 客户端库版本（mysql_get_client_info），不需要已建立的连接 */
const char *mtl_client_version(void);

/*
 * 取消后连接可能已不同步（流式读取被打断），上层应当重建连接。
 * 返回 1 表示需要重建。
 */
int mtl_conn_needs_reset(MTLConn *c);

/* ------------------------------------------------------------------ */
/* 执行                                                                */
/* ------------------------------------------------------------------ */

/*
 * 执行一段 SQL（可含多条语句，连接时已开启 CLIENT_MULTI_STATEMENTS）。
 *
 *   unbuffered = 0：mysql_store_result，适合分页查询
 *   unbuffered = 1：mysql_use_result，逐行流式，适合导出 / 大结果
 *
 * 返回 MTL_OK / MTL_CANCELLED / MTL_ERR_SQL / MTL_ERR_INVALID。
 */
int mtl_conn_query(MTLConn *c, const char *sql, size_t sql_len, int unbuffered,
                   const MTLCallbacks *cb, char *err, size_t err_len);

/* 请求中止当前正在执行的查询。可从任意线程调用。 */
void mtl_conn_cancel(MTLConn *c);

/* 清除取消标志（每次执行前由上层调用） */
void mtl_conn_clear_cancel(MTLConn *c);

/*
 * 转义字符串（不含首尾引号）。必须在 mtl_conn_open 成功之后调用。
 * 返回写入 out 的字节数；out_len 不足时返回所需长度且不写入。
 */
size_t mtl_conn_escape(MTLConn *c, const char *in, size_t in_len,
                       char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* C_MYSQL_CLIENT_H */
