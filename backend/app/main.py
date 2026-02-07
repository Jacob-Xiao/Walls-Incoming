"""
Walls Incoming - Backend API
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.database import init_db
from app.routers import levels, scores, pose

app = FastAPI(
    title="Walls Incoming API",
    description="墙来了 - 前置摄像头游戏后端",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def startup():
    init_db()


@app.get("/")
async def root():
    return {"game": "Walls Incoming", "version": "1.0.0"}


app.include_router(levels.router, prefix="/api/levels", tags=["levels"])
app.include_router(scores.router, prefix="/api/scores", tags=["scores"])
app.include_router(pose.router, prefix="/api/pose", tags=["pose"])
