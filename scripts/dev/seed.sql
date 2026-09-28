-- 手工测试用的示例数据（`make db` 首次创建时自动灌入，`make db-reset` 重灌）。
--
-- 覆盖目标：网格的两阶段加载（超长文本）、NULL、中文/emoji、二进制、
--           DECIMAL / ENUM / JSON / DATETIME(3)、外键、足够翻页的行数。
-- 行数：users 5、orders 20000（大表滚动 / 分页 / 排序）、products 200（20 列，类型铺满）。

DROP DATABASE IF EXISTS tablelite_dev;
CREATE DATABASE tablelite_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE tablelite_dev;

-- 下面靠 WITH RECURSIVE 生成两万行，默认递归深度上限只有 1000，必须放开。
SET SESSION cte_max_recursion_depth = 100000;

CREATE TABLE users (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  name       VARCHAR(64)  NOT NULL,
  email      VARCHAR(128) NULL,
  age        TINYINT UNSIGNED NULL,
  active     TINYINT(1)   NOT NULL DEFAULT 1,
  bio        TEXT         NULL,
  avatar     BLOB         NULL,
  created_at DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id         BIGINT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  status     ENUM('pending','paid','shipped','refunded') NOT NULL DEFAULT 'pending',
  amount     DECIMAL(10,2) NOT NULL,
  tags       SET('vip','gift','urgent') NULL,
  meta       JSON NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  CONSTRAINT fk_orders_user FOREIGN KEY (user_id) REFERENCES users(id)
) ENGINE=InnoDB;

CREATE TABLE products (
  id          INT PRIMARY KEY AUTO_INCREMENT,
  sku         VARCHAR(32) NOT NULL UNIQUE,
  name        VARCHAR(128) NOT NULL,
  price       DECIMAL(10,2) NOT NULL,
  stock       INT NOT NULL DEFAULT 0,
  weight_kg   DOUBLE NULL,
  description TEXT NULL,
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  category    ENUM('electronics','books','clothing','food','toys') NOT NULL DEFAULT 'toys',
  brand       VARCHAR(64) NULL,
  barcode     CHAR(13) NULL,
  cost_price  DECIMAL(12,4) NULL,
  is_deleted  TINYINT(1) NOT NULL DEFAULT 0,
  rating      TINYINT UNSIGNED NULL,
  released_on DATE NULL,
  restock_at  TIME NULL,
  model_year  YEAR NULL,
  spec        JSON NULL,
  tags        SET('hot','new','sale','limited') NULL,
  thumbnail   MEDIUMBLOB NULL
) ENGINE=InnoDB;

-- users：含超长 bio（验证大数据列的两阶段加载）、NULL 与非 ASCII
INSERT INTO users (name, email, age, active, bio, avatar) VALUES
  ('张三',    'zhangsan@example.com', 28, 1, '普通用户', NULL),
  ('李四',    NULL,                   NULL, 0, '邮箱还没填', NULL),
  ('Alice 🐳', 'alice@example.com',    35, 1,
   CONCAT(REPEAT('这是一段用于验证超长文本列加载的长文本。', 400), '【结尾标记】'),
    UNHEX('89504E470D0A1A0A')),
  ('Bob "引用" 测试', 'bob@example.com', 41, 1, NULL, NULL),
  ('O''Brien', 'obrien@example.com',   52, 0, '名字里带单引号，验证字面量生成', NULL);

-- orders 前半：手写的边界样例，覆盖 ENUM / SET / JSON / DECIMAL 与各状态取值
INSERT INTO orders (user_id, status, amount, tags, meta) VALUES
  (1, 'paid',     199.00, 'vip',           '{"channel":"app","items":2}'),
  (1, 'pending',   29.90, NULL,             NULL),
  (3, 'shipped', 1299.50, 'vip,gift',      '{"channel":"web","remark":"送礼"}'),
  (5, 'refunded',   0.01, 'urgent',        '{"reason":"尺码不对"}'),
  (2, 'pending',  88.80, NULL,             JSON_OBJECT('channel', 'pos'));

-- orders 后半：批量生成 19995 行凑满 20000，用来验证大表的滚动 / 翻页 / 排序 / 筛选。
-- tags 与 meta 故意多数为 NULL，只有零头有值，好确认「NULL 与空串/空 JSON 不同」的显示。
INSERT INTO orders (user_id, status, amount, tags, meta)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 19995)
SELECT
  1 + FLOOR(RAND() * 5),
  ELT(1 + FLOOR(RAND() * 4), 'pending', 'paid', 'shipped', 'refunded'),
  ROUND(RAND() * 2000, 2),
  IF(n % 7 = 0, ELT(1 + (n % 4), 'vip', 'vip,gift', 'urgent', 'vip,gift,urgent'), NULL),
  IF(n % 11 = 0,
     JSON_OBJECT('channel', ELT(1 + (n % 3), 'app', 'web', 'pos'), 'seq', n),
     NULL)
FROM seq;

-- products：200 行 / 20 列，验证分页 / 排序 / 过滤，以及各种类型的显示与编辑。
-- 后 12 列专门把类型铺满：数值（DECIMAL(12,4) / TINYINT / TINYINT UNSIGNED）、
-- 文本（VARCHAR / CHAR）、时间（DATE / TIME / YEAR）、ENUM / SET / JSON / BLOB。
-- thumbnail 只有 n%50 ∈ {1,2,3} 的行有值：真 PNG（能预览）、%PDF、ZIP 魔术字节。
INSERT INTO products (
  sku, name, price, stock, weight_kg, description,
  category, brand, barcode, is_deleted, rating,
  released_on, restock_at, model_year, spec, tags, thumbnail
)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200)
SELECT
  CONCAT('SKU-', LPAD(n, 4, '0')),
  CONCAT('商品-', LPAD(n, 3, '0')),
  ROUND(RAND() * 1000, 2),
  (n * 7) % 500,
  ROUND(RAND() * 5, 3),
  IF(n % 13 = 0, CONCAT(REPEAT('长描述 ', 900), '【结尾标记】'), CONCAT('第 ', n, ' 号商品的描述')),
  ELT(1 + (n % 5), 'electronics', 'books', 'clothing', 'food', 'toys'),
  CASE
    WHEN n % 11 = 0 THEN NULL
    WHEN n % 13 = 0 THEN 'Acme 🐳'
    WHEN n % 7  = 0 THEN 'O''Brien & Co.'
    WHEN n % 3  = 0 THEN '品牌-中文名'
    ELSE CONCAT('BRAND-', LPAD(n, 3, '0'))
  END,
  IF(n % 9 = 0, NULL, CONCAT('690', LPAD(n, 10, '0'))),
  IF(n % 97 = 0, 1, 0),
  IF(n % 6 = 0, NULL, 1 + (n % 5)),
  IF(n % 17 = 0, NULL, DATE('2024-01-01') + INTERVAL (n * 3) % 900 DAY),
  IF(n % 17 = 0, NULL, SEC_TO_TIME((n * 613) % 86400)),
  IF(n % 19 = 0, NULL, 2000 + (n % 26)),
  CASE
    WHEN n % 23 = 0 THEN JSON_OBJECT('备注', '出口需带说明', '批次', n)
    WHEN n % 5  = 0 THEN NULL
    ELSE JSON_OBJECT('color', ELT(1 + (n % 4), 'red', 'blue', 'green', 'black'),
                     'size', JSON_ARRAY('S', 'M', 'L'))
  END,
  CASE
    WHEN n % 4 = 0 THEN NULL
    WHEN n % 3 = 0 THEN 'hot,new'
    WHEN n % 5 = 0 THEN 'sale'
    ELSE 'limited'
  END,
  CASE
    WHEN n % 50 = 1 THEN UNHEX('89504E470D0A1A0A0000000D4948445200000001000000010802000000907753DE0000000C4944415478DA6378606000000334014186EB313F0000000049454E44AE426082')
    WHEN n % 50 = 2 THEN UNHEX('255044462D312E34')
    WHEN n % 50 = 3 THEN UNHEX('504B0304')
    ELSE NULL
  END
FROM seq;

-- cost_price 单独补：它是 price 的衍生物，不能在同一个 SELECT 里算 ——
-- 把 price 的 RAND() 放进 CTE 再引用两次，MySQL 会把 CTE 合并进外层，
-- RAND() 被重算一遍，cost 就和 price 对不上了（会出现成本高于售价的假数据）。
UPDATE products SET cost_price = IF(id % 43 = 0, NULL, ROUND(price * 0.62, 4));
