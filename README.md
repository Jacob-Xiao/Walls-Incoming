# Walls Incoming（墙来了）

基于电脑前置摄像头的体感游戏：前端 Flutter，后端 Python (FastAPI)，数据库 MySQL。

## 功能说明

- **首页**：游戏标题《Walls Incoming》，下方「开始游戏」按钮。
- **游戏页**：开启前置摄像头并显示画面；屏幕中央浮岛显示关卡与难度，以及「开始」按钮。
- **开始后**：浮岛消失，一面中间带空洞的矩形墙缓缓靠近玩家。第一关的空洞为巨大的半圆形门。

## 环境要求

- Flutter SDK（建议 3.16+）
- Python 3.10+
- MySQL 8.0 或 5.7

## 一、数据库

1. 登录 MySQL，执行 `database/init.sql` 创建库表并插入第一关：

```bash
mysql -u root -p < database/init.sql
```

或使用已有数据库用户，在 `backend/.env` 中配置（见下方后端配置）。

## 二、后端 (Python)

### 1. 创建虚拟环境

在项目根目录下进入 `backend`，使用 Python 自带的 `venv` 创建虚拟环境：

```bash
cd backend
python -m venv venv
```

### 2. 激活虚拟环境

- **Windows (PowerShell / CMD)**  
  ```bash
  venv\Scripts\activate
  ```
- **Linux / macOS**  
  ```bash
  source venv/bin/activate
  ```

激活成功后，命令行前会出现 `(venv)`。

### 3. 安装依赖并启动

```bash
pip install -r requirements.txt
```

在 `backend` 目录下创建 `.env`（可选），用于覆盖默认配置：

```env
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_USER=wallsincoming
MYSQL_PASSWORD=wallsincoming
MYSQL_DATABASE=wallsincoming
```

### 4. 启动 API

在已激活虚拟环境的情况下执行：

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

接口示例：

- `GET /` 健康检查
- `GET /api/levels` 关卡列表
- `GET /api/levels/1` 第一关详情
- `POST /api/scores` 提交成绩

## 三、前端 (Flutter)

首次需在项目内生成各平台工程（不覆盖已有 `lib/` 与 `pubspec.yaml`）：

```bash
cd frontend
flutter create . --platforms=web,windows
flutter pub get
```

- **Windows 桌面运行（需摄像头）**  
  ```bash
  flutter run -d windows
  ```
- **Chrome 运行（摄像头权限由浏览器弹窗）**  
  ```bash
  flutter run -d chrome
  ```

说明：摄像头在 **Web (Chrome)** 上支持较好；Windows 桌面需本机已安装摄像头驱动。

## 项目结构

```
CXC2/
├── frontend/          # Flutter 应用
│   ├── lib/
│   │   ├── main.dart
│   │   └── screens/
│   │       ├── home_page.dart   # 首页
│   │       └── game_page.dart  # 游戏页（摄像头 + 浮岛 + 墙）
│   └── web/
├── backend/           # FastAPI
│   ├── app/
│   │   ├── main.py
│   │   ├── config.py
│   │   ├── database.py
│   │   └── routers/
│   └── requirements.txt
└── database/
    └── init.sql       # MySQL 建表与第一关数据
```

## 第一关说明

- 关卡 1：半圆之门，难度「简单」。
- 墙为矩形，中间空洞为巨大的半圆形门；墙以约 8 秒从远处缩放至靠近屏幕，模拟「墙来了」的效果。
- **过关判定**：当墙与屏幕大小完全吻合时，使用 YOLO26-pose 对摄像头画面进行人体关键点检测。若所有检测到的关键点均处于墙的空洞内，则过关；否则未过关。关键点会实时显示在画面上，过关/未过关结果以浮岛形式呈现，可选择「返回主页」或「再玩一次」。

### 人体关键点检测（YOLO26-pose）

需在 `backend/.env` 中配置模型路径：

```env
YOLO_POSE_MODEL=C:/Users/30583/Downloads/yolo26x-pose.pt
```

首次启动后端时会加载模型，可能需要下载依赖（ultralytics、opencv 等）。确保模型文件存在。
