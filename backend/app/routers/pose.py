"""
人体关键点检测 API
接收 Flutter 发送的摄像头帧，使用 YOLO26-pose 检测，返回关键点坐标
"""
import logging

from fastapi import APIRouter, UploadFile, File, HTTPException

from app.services.pose_service import PoseService

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/detect")
async def detect_pose(file: UploadFile = File(...)):
    """
    对上传的图像进行人体关键点检测。
    接收 JPEG/PNG 图像，返回归一化坐标 [0,1] 的关键点列表及 YOLO 标注图。
    """
    # 接受 image/* 或 application/octet-stream（部分客户端未设置 contentType 时）
    ct = file.content_type or ""
    if ct and not (ct.startswith("image/") or ct == "application/octet-stream"):
        logger.warning("Rejected content-type: %s", ct)
        raise HTTPException(status_code=400, detail="请上传图像文件 (JPEG/PNG)")
    try:
        image_bytes = await file.read()
        if len(image_bytes) == 0:
            raise HTTPException(status_code=400, detail="图像为空")
        logger.info("Pose detect: received %d bytes", len(image_bytes))
        result = PoseService.detect(image_bytes)
        ann_len = len(result.get("annotated_image_base64", ""))
        logger.info("Pose detect: keypoints=%d, annotated_base64_len=%d", len(result.get("keypoints", [])), ann_len)
        return result
    except Exception as e:
        logger.exception("Pose detect failed: %s", e)
        raise HTTPException(status_code=500, detail=f"检测失败: {str(e)}")
