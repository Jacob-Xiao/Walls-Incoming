from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from app.database import get_connection

router = APIRouter()


class ScoreCreate(BaseModel):
    level_id: int
    player_name: str | None = None
    score: int = 0
    passed: bool = False


@router.post("")
def create_score(data: ScoreCreate):
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO scores (level_id, player_name, score, passed) VALUES (%s, %s, %s, %s)",
            (data.level_id, data.player_name, data.score, data.passed),
        )
        conn.commit()
        cur.execute("SELECT LAST_INSERT_ID() AS id")
        return {"id": cur.fetchone()["id"], **data.model_dump()}


@router.get("/level/{level_id:int}")
def list_scores_by_level(level_id: int, limit: int = 20):
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, level_id, player_name, score, passed, created_at FROM scores WHERE level_id = %s ORDER BY score DESC, created_at DESC LIMIT %s",
            (level_id, limit),
        )
        return cur.fetchall()
