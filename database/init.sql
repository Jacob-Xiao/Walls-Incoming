-- Walls Incoming - MySQL 初始化脚本
-- 创建数据库和用户（需用 root 执行或已有权限）

-- 确保本会话使用 UTF-8，避免中文等字符报错
SET NAMES 'utf8mb4';

CREATE DATABASE IF NOT EXISTS wallsincoming
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- 创建应用用户（密码需与 backend/.env 中 MYSQL_PASSWORD 一致）
-- 若 .env 使用其他密码，请将下方 'wallsincoming' 改为该密码，或创建后执行：
--   ALTER USER 'wallsincoming'@'localhost' IDENTIFIED BY '你的密码'; FLUSH PRIVILEGES;
CREATE USER IF NOT EXISTS 'wallsincoming'@'localhost' IDENTIFIED BY 'wallsincoming';
GRANT ALL PRIVILEGES ON wallsincoming.* TO 'wallsincoming'@'localhost';
FLUSH PRIVILEGES;

USE wallsincoming;

CREATE TABLE IF NOT EXISTS levels (
  id INT PRIMARY KEY AUTO_INCREMENT,
  level_number INT NOT NULL UNIQUE,
  name VARCHAR(64) NOT NULL,
  difficulty VARCHAR(32) NOT NULL,
  hole_type VARCHAR(32) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS scores (
  id INT PRIMARY KEY AUTO_INCREMENT,
  level_id INT NOT NULL,
  player_name VARCHAR(64),
  score INT DEFAULT 0,
  passed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (level_id) REFERENCES levels(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 若表已存在且为旧字符集，转为 utf8mb4
ALTER TABLE levels CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE scores CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

INSERT INTO levels (level_number, name, difficulty, hole_type)
VALUES (1, '半圆之门', '简单', 'semicircle')
ON DUPLICATE KEY UPDATE name = VALUES(name), difficulty = VALUES(difficulty), hole_type = VALUES(hole_type);
