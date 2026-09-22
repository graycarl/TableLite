-- 手工测试用的示例数据（`make db` 首次创建时自动灌入，`make db-reset` 重灌）。
--
-- 覆盖目标：网格的两阶段加载（超长文本）、NULL、中文/emoji、二进制、
--           DECIMAL / ENUM / JSON / DATETIME(3)、外键、足够翻页的行数。

DROP DATABASE IF EXISTS tablelite_dev;
CREATE DATABASE tablelite_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE tablelite_dev;

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
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
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

-- orders：覆盖 ENUM / SET / JSON / DECIMAL
INSERT INTO orders (user_id, status, amount, tags, meta) VALUES
  (1, 'paid',     199.00, 'vip',           '{"channel":"app","items":2}'),
  (1, 'pending',   29.90, NULL,             NULL),
  (3, 'shipped', 1299.50, 'vip,gift',      '{"channel":"web","remark":"送礼"}'),
  (5, 'refunded',   0.01, 'urgent',        '{"reason":"尺码不对"}'),
  (2, 'pending',  88.80, NULL,             JSON_OBJECT('channel', 'pos'));

-- products：200 行，够验证分页 / 排序 / 过滤
INSERT INTO products (sku, name, price, stock, weight_kg, description)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200)
SELECT
  CONCAT('SKU-', LPAD(n, 4, '0')),
  CONCAT('商品-', LPAD(n, 3, '0')),
  ROUND(RAND() * 1000, 2),
  (n * 7) % 500,
  ROUND(RAND() * 5, 3),
  IF(n % 13 = 0, CONCAT(REPEAT('长描述 ', 900), '【结尾标记】'), CONCAT('第 ', n, ' 号商品的描述'))
FROM seq;
