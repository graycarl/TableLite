#!/usr/bin/env python3
"""生成 200 列宽表 wide_test 的建表与灌数 SQL（3000 行），输出到 stdout。

由 db.sh 的 seed() 追加在 seed.sql 之后执行（同一条 mysql 连接，seed.sql 已
USE tablelite_dev 并放开 cte_max_recursion_depth）。改列构成请改本文件，
然后 `make db-reset` 生效；不要手改它生成的 SQL。

用途：验证数据浏览界面在超宽表下的滚动性能，以及各字段类型的渲染。
列构成：id + 199 个数据列 = 200 列 —— 整数(10)、BIT(3)、浮点/定点(5)、
布尔(1)、日期时间(7)、JSON(5)、ENUM(6)、SET(4)、CHAR(5)、二进制(5)、
BLOB(4)、TEXT(4)、VARCHAR(140)。
"""
import sys

COLS = []  # (列名, DDL, 以 n 为行号的取值表达式)


def add(name, ddl, expr):
    COLS.append((name, ddl, expr))


def n17(expr):
    """约 1/17 的行的值为 NULL，用来和空串 / 空 JSON 区分。"""
    return f"IF(n % 17 = 0, NULL, {expr})"


# ---- 整数：有符号 / 无符号 × 5 档 ----
add("i_tiny",    "TINYINT NULL",            n17("(n % 255) - 128"))
add("i_utiny",   "TINYINT UNSIGNED NULL",   "n % 256")
add("i_small",   "SMALLINT NULL",           "(n % 65535) - 32768")
add("i_usmall",  "SMALLINT UNSIGNED NULL",  "(n * 37) % 65536")
add("i_medium",  "MEDIUMINT NULL",          "(n % 16777215) - 8388608")
add("i_umedium", "MEDIUMINT UNSIGNED NULL", "(n * 101) % 16777216")
add("i_int",     "INT NULL",                n17("(n % 2000000000) - 1000000000"))
add("i_uint",    "INT UNSIGNED NULL",       "n * 7919")
add("i_big",     "BIGINT NULL",             "n * 1000000000003 - 500000000000")
add("i_ubig",    "BIGINT UNSIGNED NULL",    "n * 1000000000003")

# ---- BIT ----
add("bit_1",  "BIT(1) NULL",  "n % 2")
add("bit_8",  "BIT(8) NULL",  "n % 256")
add("bit_32", "BIT(32) NULL", "n")

# ---- 浮点 / 定点 ----
add("f_float",   "FLOAT NULL",           n17("ROUND(RAND() * 1000, 3)"))
add("f_double",  "DOUBLE NULL",          "ROUND(RAND() * 1000000, 6)")
add("dec_9_2",   "DECIMAL(9,2) NULL",    "ROUND((n % 1000000) / 100, 2)")
add("dec_18_6",  "DECIMAL(18,6) NULL",   "ROUND(n * 3.141592653589793, 6)")
add("dec_30_10", "DECIMAL(30,10) NULL",  "ROUND(n / 7, 10)")

# ---- 布尔 ----
add("flag", "TINYINT(1) NOT NULL DEFAULT 0", "n % 2")

# ---- 日期时间 ----
add("dt_date",   "DATE NULL",       n17("DATE('2023-01-01') + INTERVAL (n % 1095) DAY"))
add("dt_time",   "TIME NULL",       "SEC_TO_TIME((n * 613) % 86400)")
add("dt_time3",  "TIME(3) NULL",    "ADDTIME(SEC_TO_TIME((n * 613) % 86400), CONCAT('0 0:0:0.', LPAD(n % 1000, 3, '0')))")
add("dt_dtime",  "DATETIME NULL",   "DATE('2022-06-01') + INTERVAL (n % 700) DAY + INTERVAL ((n * 97) % 86400) SECOND")
add("dt_dtime6", "DATETIME(6) NULL", "'2022-06-01 00:00:00' + INTERVAL (n % 700) DAY + INTERVAL ((n * 97) % 86400) SECOND + INTERVAL (n % 1000000) MICROSECOND")
add("dt_ts",     "TIMESTAMP NULL",  "'2024-01-01 00:00:00' + INTERVAL n HOUR")
add("dt_year",   "YEAR NULL",       n17("1980 + (n % 50)"))

# ---- JSON ----
add("json_1", "JSON NULL", n17("JSON_OBJECT('seq', n, '名称', CONCAT('行', n))"))
add("json_2", "JSON NULL", "JSON_ARRAY(n, CONCAT('item', n), (n % 2) = 0)")
add("json_3", "JSON NULL", "IF(n % 3 = 0, CAST('{}' AS JSON), JSON_OBJECT('channel', ELT(1 + (n % 3), 'app', 'web', 'pos'), 'seq', n))")
add("json_4", "JSON NULL", "JSON_OBJECT('a', JSON_OBJECT('b', JSON_ARRAY(1, 2, n)), 'note', '嵌套结构')")
add("json_5", "JSON NULL", "JSON_OBJECT('quote', 'say \"hi\"', 'emoji', '🐳🚀', 'path', 'C:\\\\tmp')")

# ---- ENUM ----
enum_3_members = [f"v{i:02d}" for i in range(1, 13)]
add("enum_1", "ENUM('pending','paid','shipped','refunded') NULL",
    n17("ELT(1 + (n % 4), 'pending', 'paid', 'shipped', 'refunded')"))
add("enum_2", "ENUM('小','中','大','特大') NULL",
    "ELT(1 + (n % 4), '小', '中', '大', '特大')")
add("enum_3", f"ENUM({','.join(repr(m) for m in enum_3_members)}) NULL",
    f"ELT(1 + (n % 12), {', '.join(repr(m) for m in enum_3_members)})")
add("enum_4", "ENUM('alpha','beta','gamma','delta','epsilon') NULL",
    "ELT(1 + (n % 5), 'alpha', 'beta', 'gamma', 'delta', 'epsilon')")
add("enum_5", "ENUM('yes','no','maybe') NULL", n17("ELT(1 + (n % 3), 'yes', 'no', 'maybe')"))
add("enum_6", "ENUM('0','1','2') NULL", "ELT(1 + (n % 3), '0', '1', '2')")

# ---- SET ----
add("set_1", "SET('vip','gift','urgent') NULL",
    "ELT(1 + (n % 4), 'vip', 'vip,gift', 'urgent', 'vip,gift,urgent')")
add("set_2", "SET('热','新','促','限量') NULL",
    "ELT(1 + (n % 4), '热', '热,新', '促', '热,新,促,限量')")
add("set_3", "SET('a','b','c','d','e','f','g','h') NULL",
    n17("ELT(1 + (n % 5), 'a', 'a,b,c', 'd,e', 'f,g,h', 'a,b,c,d,e,f,g,h')"))
add("set_4", "SET('1','2','4','8') NULL",
    "ELT(1 + (n % 4), '1', '1,2', '4,8', '1,2,4,8')")

# ---- CHAR ----
add("ch_1",  "CHAR(1) NULL",  n17("CHAR(65 + (n % 26))"))
add("ch_4",  "CHAR(4) NULL",  "CONCAT('C', LPAD(n % 1000, 3, '0'))")
add("ch_8",  "CHAR(8) NULL",  "LPAD(HEX(n), 8, '0')")
add("ch_13", "CHAR(13) NULL", "CONCAT('690', LPAD(n, 10, '0'))")
add("ch_36", "CHAR(36) NULL",
    "LOWER(CONCAT(LEFT(MD5(n), 8), '-', SUBSTRING(MD5(n), 9, 4), '-', SUBSTRING(MD5(n), 13, 4), '-', SUBSTRING(MD5(n), 17, 4), '-', SUBSTRING(MD5(n), 21, 12)))")

# ---- BINARY / VARBINARY ----
add("bin_4",  "BINARY(4) NULL",     n17("UNHEX(LPAD(HEX(n), 8, '0'))"))
add("bin_16", "BINARY(16) NULL",    "UNHEX(MD5(n))")
add("vb_32",  "VARBINARY(32) NULL", "UNHEX(SHA1(n))")
add("vb_255", "VARBINARY(255) NULL", n17("UNHEX(SHA2(n, 256))"))
add("vb_512", "VARBINARY(512) NULL", "UNHEX(REPEAT(SHA2(n, 256), 4))")

# ---- BLOB（少量行放大内容，验证大值列的两阶段加载）----
PNG_1PX = ("89504E470D0A1A0A0000000D49484452000000010000000108020000009077"
           "53DE0000000C4944415478DA6378606000000334014186EB313F0000000049454E44AE426082")
add("blob_tiny", "TINYBLOB NULL", "UNHEX(MD5(CONCAT('t', n)))")
add("blob_s", "BLOB NULL",
    f"IF(n % 50 = 1, UNHEX('{PNG_1PX}'), REPEAT(CONCAT('row', n, '-'), 20))")
add("blob_m", "MEDIUMBLOB NULL",
    "IF(n % 20 = 0, REPEAT(CONCAT('块', n, '-'), 3000), REPEAT(CONCAT('块', n), 20))")
add("blob_l", "LONGBLOB NULL",
    "IF(n % 50 = 0, REPEAT(CONCAT('L', n, '-'), 20000), REPEAT(CONCAT('L', n), 5))")

# ---- TEXT ----
add("txt_tiny", "TINYTEXT NULL",   "CONCAT('短文本-', n)")
add("txt_s",    "TEXT NULL",       n17("CONCAT('第 ', n, ' 行的普通文本内容，用于测试 TEXT 类型显示。')"))
add("txt_m",    "MEDIUMTEXT NULL",
    "IF(n % 20 = 0, CONCAT(REPEAT('这是一段较长的中文文本，用于验证宽表里 TEXT 列的渲染与两阶段加载。', 200), '【结尾标记】'), CONCAT('第 ', n, ' 行'))")
add("txt_l",    "LONGTEXT NULL",
    "IF(n % 50 = 0, CONCAT(REPEAT('超长文本内容 ', 5000), '【结尾标记】'), '短')")

# ---- VARCHAR：140 列，三种长度 ----
def varchar_expr(k, size):
    if size == 20:
        t = k % 7
        return [
            f"IF(n % 3 = 0, NULL, CONCAT('v', LPAD(n, 5, '0')))",
            n17("CONCAT('行', n)"),
            "IF(n % 11 = 0, CONCAT('🐳', n % 100), CONCAT('s', n))",
            "IF(n % 13 = 0, '', CONCAT('x', n))",
            "IF(n % 19 = 0, 'O''Brien', CONCAT('q', n))",
            "LPAD(n, 10, '0')",
            f"CONCAT('值', n, '-', {k})",
        ][t]
    if size == 50:
        t = k % 5
        return [
            n17(f"CONCAT('商品名称-', n, '-规格-', {k})"),
            "CONCAT(REPEAT('ab', n % 20), '-', n)",
            "IF(n % 13 = 0, '', CONCAT('较长的描述文本-', n))",
            "IF(n % 23 = 0, '反斜杠\\\\与\"引号\"混合', CONCAT('m', n))",
            "CONCAT('🚀emoji前缀-', n, '-后缀')",
        ][t]
    # size == 255
    t = k % 4
    return [
        n17("CONCAT(REPEAT('长值', n % 40), '-', n)"),
        "CONCAT(REPEAT('w', 50 + (n % 150)), '-', n)",
        "IF(n % 29 = 0, REPEAT('临近截断的长字符串', 12), CONCAT('c', n))",
        f"CONCAT('URL https://example.com/path/', n, '?q=关键词&col=', {k})",
    ][t]


VARCHAR_SIZES = [(20, 100), (50, 30), (255, 10)]  # (长度, 列数)
k = 0
for size, count in VARCHAR_SIZES:
    for _ in range(count):
        k += 1
        add(f"v_{k:03d}", f"VARCHAR({size}) NULL", varchar_expr(k, size))

assert len(COLS) == 199, f"数据列应为 199（+id=200），实际 {len(COLS)}"
assert len({c[0] for c in COLS}) == len(COLS), "列名有重复"

# ---- 输出 SQL ----
out = sys.stdout
out.write("-- =====================================================================\n")
out.write("-- 本段由 scripts/dev/gen_wide_seed.py 生成，请勿手改（改生成器后 make db-reset）。\n")
out.write("-- wide_test：200 列（含 id）× 3000 行，覆盖 MySQL 常见字段类型，\n")
out.write("-- 用于验证数据浏览界面在超宽表下的滚动性能与各类型渲染。\n")
out.write("-- =====================================================================\n")
out.write("SET SESSION cte_max_recursion_depth = 100000;\n\n")

ddl_lines = ["  id INT PRIMARY KEY AUTO_INCREMENT"]
ddl_lines += [f"  {name} {ddl}" for name, ddl, _ in COLS]
ddl_lines.append("  KEY idx_v_001 (v_001)")
out.write("CREATE TABLE wide_test (\n" + ",\n".join(ddl_lines) + "\n) ENGINE=InnoDB;\n\n")

col_list = ",\n  ".join(name for name, _, _ in COLS)
expr_list = ",\n  ".join(expr for _, _, expr in COLS)
out.write(f"""INSERT INTO wide_test (
  {col_list}
)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000)
SELECT
  {expr_list}
FROM seq;
""")
