from fastapi import APIRouter, HTTPException
from app.database import get_connection

router = APIRouter()


@router.get("")
def list_levels():
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, level_number, name, difficulty, hole_type FROM levels ORDER BY level_number"
        )
        return cur.fetchall()


@router.get("/{level_number:int}")
def get_level(level_number: int):
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, level_number, name, difficulty, hole_type FROM levels WHERE level_number = %s",
            (level_number,),
        )
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="关卡不存在")
    return row
