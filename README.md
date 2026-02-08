# Walls Incoming（墙来了）

基于电脑前置摄像头的体感游戏：前端 Flutter，后端 Python (FastAPI)，数据库 MySQL。

## 功能说明

- **首页**：游戏标题《Walls Incoming》，副标题「Here comes the wall」，下方「Start Game」按钮。
- **游戏页**：开启前置摄像头并显示画面；屏幕中央浮岛显示当前关卡、难度（Easy / Medium / Hard）以及「Start」按钮。
- **开始后**：浮岛消失，一面中间带空洞的矩形墙缓缓靠近玩家。墙的空洞形状随关卡不同（见下方关卡说明）。
- **过关判定**：墙与屏幕完全吻合时，对最后一帧做人体关键点检测；若有关键点落在墙上（空洞外）则未过关，否则过关。关键点实时叠加显示（绿色），未过关时落在墙上的关键点显示为红色。
- **计分**：过关时每个检测到的关键点计 10 分；未过关时，在空洞内的关键点（绿色）每点 10 分，在墙上的关键点（红色）每点 5 分。每关结束后的浮岛显示本局得分（Score）与历史最高分（Best）。
- **关卡推进**：过关后浮岛出现「NEXT LEVEL」可进入下一关；亦可「PLAY AGAIN」重玩当前关或「BACK TO HOME」返回首页。

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

## 关卡说明

- **墙动画**：墙以约 8 秒从远处缩放至与屏幕完全吻合，模拟「墙来了」的效果。过关判定在墙闭合的最后一帧进行，使用该帧的墙几何与关键点做对比（Path.contains）。
- **过关判定**：使用 YOLO26-pose 对最后一帧进行人体关键点检测；空洞路径与绘制完全一致。若所有关键点均在空洞内则过关，否则未过关。关键点实时叠加在视频流上（绿色），未过关时落在墙上的关键点标红显示。

### 关卡 1 — 半圆之门（Easy）

- 空洞为屏幕底部中央的巨大半圆形门（宽度约为短边的 85%）。
- 难度：简单。

### 关卡 2 — 竖条之门（Medium）

- 空洞为屏幕中央的竖直矩形条，贯穿整面墙到底部，宽度中等（约为短边的 40%）。
- 难度：中等。

### 关卡 3 — 人形之门（Hard）

- 空洞为人形轮廓：头部为圆形，躯干为圆角矩形，头与躯干组合成单一空洞路径。
- 难度：困难。

### 人体关键点检测（YOLO26-pose）

需在 `backend/.env` 中配置模型路径：

```env
YOLO_POSE_MODEL=C:/Users/30583/Downloads/yolo26x-pose.pt
```

首次启动后端时会加载模型，可能需要下载依赖（ultralytics、opencv 等）。确保模型文件存在。
