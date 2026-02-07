from pydantic_settings import BaseSettings
from typing import List


class Settings(BaseSettings):
    MYSQL_HOST: str = "localhost"
    MYSQL_PORT: int = 3306
    MYSQL_USER: str = "wallsincoming"
    MYSQL_PASSWORD: str = "wallsincoming"
    MYSQL_DATABASE: str = "wallsincoming"
    CORS_ORIGINS: List[str] = [
        "http://localhost:8080", "http://127.0.0.1:8080",
        "http://localhost:5000", "http://127.0.0.1:5000",
        "http://localhost:3000", "http://127.0.0.1:3000",
    ]
    # YOLO26-pose 模型路径，例如 C:/Users/30583/Downloads/yolo26x-pose.pt
    YOLO_POSE_MODEL: str = "C:/Users/30583/Downloads/yolo26x-pose.pt"

    class Config:
        env_file = ".env"


settings = Settings()
