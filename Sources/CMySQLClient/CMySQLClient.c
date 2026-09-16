// CMySQLClient 实现
//
// 算法说明见 docs/tech-designs/03-mysql-layer.md
//
// ⚠️ 本文件是 Phase 0 的产物：结构完整但**尚未经过编译验证与端到端测试**。
//    Phase 0 的首要任务就是 `make build` + `make smoke` 把它跑通。

#include "CMySQLClient.h"

#include <mysql.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct MTLConn {
    MYSQL              *mysql;
    int                 is_open;
    int                 use_ssl;
    int                 skip_verify;
    unsigned int        connect_timeout;      /* 秒，0 = 用库默认 */
    unsigned int        rw_timeout;           /* 秒，0 = 用库默认 */
    unsigned long       thread_id;
    int                 needs_reset;

    /* 取消标志：可能被其他线程置位，用 volatile 即可（只做轮询，不做同步） */
    volatile int        cancel_requested;

    char                last_error[MTL_ERRBUF_SIZE];
    unsigned int        last_errno;
    char                last_sqlstate[8];
};

/* ------------------------------------------------------------------ */
/* 内部工具                                                            */
/* ------------------------------------------------------------------ */

static void mtl__clear_error(MTLConn *c) {
    c->last_error[0] = '\0';
    c->last_sqlstate[0] = '\0';
    c->last_errno = 0;
}

/** 记录来自 MYSQL* 的错误；m 可以为 NULL。 */
static void mtl__set_error(MTLConn *c, MYSQL *m, const char *fallback) {
    if (m != NULL) {
        c->last_errno = mysql_errno(m);
        snprintf(c->last_error, sizeof(c->last_error), "%s", mysql_error(m));
        const char *state = mysql_sqlstate(m);
        snprintf(c->last_sqlstate, sizeof(c->last_sqlstate), "%s", state ? state : "");
    } else {
        c->last_errno = 0;
        snprintf(c->last_error, sizeof(c->last_error), "%s", fallback ? fallback : "");
        c->last_sqlstate[0] = '\0';
    }
    if (c->last_error[0] == '\0' && fallback != NULL) {
        snprintf(c->last_error, sizeof(c->last_error), "%s", fallback);
    }
}

static void mtl__write_err(char *err, size_t err_len, const char *message) {
    if (err != NULL && err_len > 0) {
        snprintf(err, err_len, "%s", message ? message : "");
    }
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

MTLConn *mtl_conn_create(void) {
    MTLConn *c = (MTLConn *)calloc(1, sizeof(MTLConn));
    if (c == NULL) {
        return NULL;
    }
    c->mysql = NULL;
    c->is_open = 0;
    c->use_ssl = 0;
    c->skip_verify = 0;
    c->connect_timeout = 10;
    c->rw_timeout = 0;
    c->thread_id = 0;
    c->needs_reset = 0;
    c->cancel_requested = 0;
    mtl__clear_error(c);
    return c;
}

void mtl_conn_free(MTLConn *c) {
    if (c == NULL) {
        return;
    }
    mtl_conn_close(c);
    free(c);
}

void mtl_conn_set_ssl(MTLConn *c, int use_ssl, int skip_verify) {
    if (c == NULL) return;
    c->use_ssl = use_ssl ? 1 : 0;
    c->skip_verify = skip_verify ? 1 : 0;
}

void mtl_conn_set_connect_timeout(MTLConn *c, unsigned int seconds) {
    if (c == NULL) return;
    c->connect_timeout = seconds;
}

void mtl_conn_set_read_write_timeout(MTLConn *c, unsigned int seconds) {
    if (c == NULL) return;
    c->rw_timeout = seconds;
}

int mtl_conn_open(MTLConn *c,
                  const char *host, unsigned int port,
                  const char *user, const char *password,
                  const char *database, const char *charset,
                  const char *unix_socket,
                  char *err, size_t err_len) {
    if (c == NULL || host == NULL || user == NULL) {
        mtl__write_err(err, err_len, "invalid arguments");
        return MTL_ERR_INVALID;
    }
    mtl_conn_close(c);
    mtl__clear_error(c);
    c->needs_reset = 0;

    c->mysql = mysql_init(NULL);
    if (c->mysql == NULL) {
        mtl__write_err(err, err_len, "mysql_init 失败（内存不足）");
        return MTL_ERR_INVALID;
    }

    unsigned int t = c->connect_timeout;
    if (t > 0) {
        mysql_options(c->mysql, MYSQL_OPT_CONNECT_TIMEOUT, &t);
    }
    if (c->rw_timeout > 0) {
        mysql_options(c->mysql, MYSQL_OPT_READ_TIMEOUT, &c->rw_timeout);
        mysql_options(c->mysql, MYSQL_OPT_WRITE_TIMEOUT, &c->rw_timeout);
    }
    if (charset != NULL && charset[0] != '\0') {
        mysql_options(c->mysql, MYSQL_SET_CHARSET_NAME, charset);
    }

    /* SSL：默认 PREFERRED（服务器不支持时自动回退）；
       要求 TLS 但跳过证书校验用 REQUIRED；其余用 VERIFY_CA。 */
#if defined(MYSQL_OPT_SSL_MODE)
    {
        unsigned int mode = SSL_MODE_PREFERRED;
        if (c->use_ssl) {
            mode = c->skip_verify ? SSL_MODE_REQUIRED : SSL_MODE_VERIFY_CA;
        }
        mysql_options(c->mysql, MYSQL_OPT_SSL_MODE, &mode);
    }
#endif

    /* 禁止 LOAD DATA LOCAL INFILE，避免客户端被诱导读本地文件 */
#if defined(MYSQL_OPT_LOCAL_INFILE)
    {
        unsigned int off = 0;
        mysql_options(c->mysql, MYSQL_OPT_LOCAL_INFILE, &off);
    }
#endif

    /* 不启用自动重连：重连由上层（ConnectionSession）显式控制，
       库层的静默重连会让用户以为会话还在 */

    unsigned long client_flag = CLIENT_MULTI_STATEMENTS;

    MYSQL *ok = mysql_real_connect(c->mysql,
                                   host,
                                   user,
                                   (password != NULL && password[0] != '\0') ? password : NULL,
                                   (database != NULL && database[0] != '\0') ? database : NULL,
                                   port,
                                   (unix_socket != NULL && unix_socket[0] != '\0') ? unix_socket : NULL,
                                   client_flag);
    if (ok == NULL) {
        mtl__set_error(c, c->mysql, "mysql_real_connect 失败");
        mtl__write_err(err, err_len, c->last_error);
        mysql_close(c->mysql);
        c->mysql = NULL;
        return MTL_ERR_INVALID;
    }

    /* 让 mysql_real_escape_string 使用正确的字符集 */
    if (charset != NULL && charset[0] != '\0') {
        if (mysql_set_character_set(c->mysql, charset) != 0) {
            mtl__set_error(c, c->mysql, "设置字符集失败");
            mtl__write_err(err, err_len, c->last_error);
            mysql_close(c->mysql);
            c->mysql = NULL;
            return MTL_ERR_INVALID;
        }
    }

    c->is_open = 1;
    c->thread_id = mysql_thread_id(c->mysql);
    return MTL_OK;
}

void mtl_conn_close(MTLConn *c) {
    if (c == NULL || c->mysql == NULL) {
        if (c != NULL) { c->is_open = 0; }
        return;
    }
    mysql_close(c->mysql);
    c->mysql = NULL;
    c->is_open = 0;
    c->thread_id = 0;
}

int mtl_conn_is_open(MTLConn *c) {
    return (c != NULL && c->mysql != NULL && c->is_open) ? 1 : 0;
}

int mtl_conn_ping(MTLConn *c) {
    if (!mtl_conn_is_open(c)) {
        return MTL_ERR_INVALID;
    }
    if (mysql_ping(c->mysql) != 0) {
        mtl__set_error(c, c->mysql, "ping 失败");
        c->needs_reset = 1;
        return MTL_ERR_INVALID;
    }
    return MTL_OK;
}

unsigned long mtl_conn_thread_id(MTLConn *c) {
    return (c != NULL) ? c->thread_id : 0;
}

unsigned int mtl_conn_errno(MTLConn *c) {
    return (c != NULL) ? c->last_errno : 0;
}

const char *mtl_conn_error(MTLConn *c) {
    return (c != NULL) ? c->last_error : "";
}

const char *mtl_conn_sqlstate(MTLConn *c) {
    return (c != NULL) ? c->last_sqlstate : "";
}

const char *mtl_conn_server_version(MTLConn *c) {
    if (!mtl_conn_is_open(c)) return "";
    return mysql_get_server_info(c->mysql);
}

const char *mtl_conn_server_info(MTLConn *c) {
    if (!mtl_conn_is_open(c)) return "";
    return mysql_get_host_info(c->mysql);
}

int mtl_conn_needs_reset(MTLConn *c) {
    return (c != NULL) ? c->needs_reset : 1;
}

const char *mtl_client_version(void) {
    return mysql_get_client_info();
}

/* ------------------------------------------------------------------ */
/* 取消                                                                */
/* ------------------------------------------------------------------ */

void mtl_conn_cancel(MTLConn *c) {
    if (c != NULL) {
        c->cancel_requested = 1;
    }
}

void mtl_conn_clear_cancel(MTLConn *c) {
    if (c != NULL) {
        c->cancel_requested = 0;
    }
}

/* ------------------------------------------------------------------ */
/* 转义                                                                */
/* ------------------------------------------------------------------ */

size_t mtl_conn_escape(MTLConn *c, const char *in, size_t in_len,
                       char *out, size_t out_len) {
    if (c == NULL || in == NULL) {
        return 0;
    }
    if (!mtl_conn_is_open(c)) {
        /* 没有连接就拿不到正确的字符集，退化为最保守的转义 */
        size_t need = 0;
        for (size_t i = 0; i < in_len; i++) {
            char ch = in[i];
            need += (ch == '\'' || ch == '"' || ch == '\\' || ch == '\0') ? 2 : 1;
        }
        if (out == NULL || out_len < need + 1) {
            return need;
        }
        size_t w = 0;
        for (size_t i = 0; i < in_len; i++) {
            char ch = in[i];
            if (ch == '\'' || ch == '"' || ch == '\\' || ch == '\0') {
                out[w++] = '\\';
            }
            out[w++] = ch;
        }
        out[w] = '\0';
        return w;
    }

    /* mysql_real_escape_string 需要 NUL 结尾的输入，且输出最多 2*len+1 */
    char *tmp = (char *)malloc(in_len + 1);
    if (tmp == NULL) {
        return 0;
    }
    memcpy(tmp, in, in_len);
    tmp[in_len] = '\0';

    unsigned long need = (unsigned long)(in_len * 2 + 1);
    if (out == NULL || out_len < need) {
        free(tmp);
        return (size_t)need;
    }
    unsigned long written = mysql_real_escape_string(c->mysql, out, tmp, (unsigned long)in_len);
    free(tmp);
    return (size_t)written;
}

/* ------------------------------------------------------------------ */
/* 执行                                                                */
/* ------------------------------------------------------------------ */

/** 把 MYSQL_FIELD[] 转成 MTLColumn[]。字符串指针只在结果集存活期间有效。 */
static void mtl__fill_columns(MTLColumn *dest, const MYSQL_FIELD *fields, unsigned int n) {
    for (unsigned int i = 0; i < n; i++) {
        const MYSQL_FIELD *f = &fields[i];
        dest[i].name           = f->name;
        dest[i].original_name  = f->org_name;
        dest[i].table          = f->table;
        dest[i].original_table = f->org_table;
        dest[i].database       = f->db;
        dest[i].type           = (unsigned int)f->type;
        dest[i].flags          = (unsigned int)f->flags;
        dest[i].charset_nr     = (unsigned int)f->charsetnr;
        dest[i].length         = (unsigned int)f->length;
        dest[i].decimals       = (unsigned int)f->decimals;
    }
}

int mtl_conn_query(MTLConn *c, const char *sql, size_t sql_len, int unbuffered,
                   const MTLCallbacks *cb, char *err, size_t err_len) {
    if (c == NULL || sql == NULL || !mtl_conn_is_open(c)) {
        mtl__write_err(err, err_len, "连接不可用");
        return MTL_ERR_INVALID;
    }

    mtl__clear_error(c);
    c->cancel_requested = 0;

    if (mysql_real_query(c->mysql, sql, (unsigned long)sql_len) != 0) {
        mtl__set_error(c, c->mysql, "mysql_real_query 失败");
        mtl__write_err(err, err_len, c->last_error);
        return MTL_ERR_SQL;
    }

    int result_index = 0;
    int rc = MTL_OK;

    do {
        MTLResultSet rs_info;
        memset(&rs_info, 0, sizeof(rs_info));
        rs_info.result_index = result_index;

        MYSQL_RES *res = unbuffered ? mysql_use_result(c->mysql)
                                    : mysql_store_result(c->mysql);

        if (res == NULL) {
            unsigned int field_count = mysql_field_count(c->mysql);
            if (field_count == 0) {
                /* OK 包：没有结果集，只有影响行数 */
                my_ulonglong affected = mysql_affected_rows(c->mysql);
                my_ulonglong insert_id = mysql_insert_id(c->mysql);
                rs_info.column_count = 0;
                rs_info.affected_rows = (affected == (my_ulonglong)-1) ? 0 : (long long)affected;
                rs_info.last_insert_id = (unsigned long long)insert_id;
                rs_info.columns = NULL;
                if (cb != NULL && cb->on_result_set != NULL) {
                    cb->on_result_set(cb->ctx, &rs_info);
                }
            } else {
                /* 有列却拿不到结果集 → 出错 */
                mtl__set_error(c, c->mysql, "mysql_store_result / mysql_use_result 失败");
                mtl__write_err(err, err_len, c->last_error);
                if (cb != NULL && cb->on_statement_error != NULL) {
                    cb->on_statement_error(cb->ctx, result_index,
                                           mysql_errno(c->mysql),
                                           mysql_sqlstate(c->mysql),
                                           mysql_error(c->mysql));
                }
                rc = MTL_ERR_SQL;
                result_index++;
                continue;
            }
        } else {
            unsigned int n = mysql_num_fields(res);
            MYSQL_FIELD *fields = mysql_fetch_fields(res);

            MTLColumn *cols = NULL;
            if (n > 0) {
                cols = (MTLColumn *)calloc(n, sizeof(MTLColumn));
                if (cols == NULL) {
                    mysql_free_result(res);
                    mtl__write_err(err, err_len, "内存不足");
                    return MTL_ERR_INVALID;
                }
                mtl__fill_columns(cols, fields, n);
            }

            rs_info.column_count = (int)n;
            rs_info.columns = cols;
            if (cb != NULL && cb->on_result_set != NULL) {
                cb->on_result_set(cb->ctx, &rs_info);
            }

            long long row_index = 0;
            int interrupted = 0;
            MYSQL_ROW row;
            while ((row = mysql_fetch_row(res)) != NULL) {
                if (c->cancel_requested) {
                    interrupted = 1;
                    break;
                }
                unsigned long *lengths = mysql_fetch_lengths(res);
                MTLRow mr;
                mr.result_index = result_index;
                mr.row_index = row_index;
                mr.column_count = (int)n;
                mr.values = (const char *const *)row;
                mr.lengths = lengths;
                if (cb != NULL && cb->on_row != NULL) {
                    if (cb->on_row(cb->ctx, &mr) != 0) {
                        interrupted = 1;
                        break;
                    }
                }
                row_index++;
            }

            if (!interrupted && mysql_errno(c->mysql) != 0) {
                mtl__set_error(c, c->mysql, "读取结果集时出错");
                mtl__write_err(err, err_len, c->last_error);
                if (cb != NULL && cb->on_statement_error != NULL) {
                    cb->on_statement_error(cb->ctx, result_index,
                                           mysql_errno(c->mysql),
                                           mysql_sqlstate(c->mysql),
                                           mysql_error(c->mysql));
                }
                rc = MTL_ERR_SQL;
            }

            mysql_free_result(res);
            free(cols);

            if (interrupted) {
                /* 流式读取被打断时连接已不同步，必须重建 */
                c->needs_reset = 1;
                mtl__write_err(err, err_len, "查询已取消");
                return MTL_CANCELLED;
            }
        }

        result_index++;
    } while (mysql_next_result(c->mysql) == 0);

    if (mtl_conn_errno(c) != 0 && rc == MTL_OK && mysql_errno(c->mysql) != 0) {
        mtl__set_error(c, c->mysql, "读取后续结果集时出错");
        mtl__write_err(err, err_len, c->last_error);
        rc = MTL_ERR_SQL;
    }

    return rc;
}
