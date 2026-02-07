import pymysql
from app.config import settings

_connection = None


def get_connection():
    global _connection
    if _connection is None:
        _connection = pymysql.connect(
            host=settings.MYSQL_HOST,
            port=settings.MYSQL_PORT,
            user=settings.MYSQL_USER,
            password=settings.MYSQL_PASSWORD,
            database=settings.MYSQL_DATABASE,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.DictCursor,
        )
    return _connection


def init_db():
    """Create tables if not exist."""
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS levels (
                id INT PRIMARY KEY AUTO_INCREMENT,
                level_number INT NOT NULL UNIQUE,
                name VARCHAR(64) NOT NULL,
                difficulty VARCHAR(32) NOT NULL,
                hole_type VARCHAR(32) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS scores (
                id INT PRIMARY KEY AUTO_INCREMENT,
                level_id INT NOT NULL,
                player_name VARCHAR(64),
                score INT DEFAULT 0,
                passed BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (level_id) REFERENCES levels(id)
            )
        """)
        cur.execute("SELECT COUNT(*) AS n FROM levels")
        if cur.fetchone()["n"] == 0:
            cur.execute("""
                INSERT INTO levels (level_number, name, difficulty, hole_type)
                VALUES (1, '半圆之门', '简单', 'semicircle')
            """)
        conn.commit()
