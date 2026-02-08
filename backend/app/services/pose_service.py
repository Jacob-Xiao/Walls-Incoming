"""
YOLO26-pose 人体关键点检测服务
从接收的图像（摄像头帧）中检测人体关键点，返回归一化坐标 xyn 及 YOLO 绘制关键点后的图像流
"""
import base64
import numpy as np
from pathlib import Path
from typing import List

from app.config import settings


# COCO 17 keypoints: 0 nose, 1 left_eye, 2 right_eye, 3 left_ear, 4 right_ear,
# 5 left_shoulder, 6 right_shoulder, 7 left_elbow, 8 right_elbow, 9 left_wrist,
# 10 right_wrist, 11 left_hip, 12 right_hip, 13 left_knee, 14 right_knee,
# 15 left_ankle, 16 right_ankle
KEYPOINT_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle"
]


class PoseService:
    _instance = None
    _model = None

    @classmethod
    def get_model(cls):
        if cls._model is None:
            from ultralytics import YOLO
            model_path = settings.YOLO_POSE_MODEL
            if not Path(model_path).is_absolute():
                model_path = str(Path(__file__).resolve().parents[2] / model_path)
            cls._model = YOLO(model_path)
        return cls._model

    @classmethod
    def detect(cls, image_bytes: bytes) -> dict:
        """
        对摄像头帧进行人体关键点检测，返回 YOLO 绘制后的图像流及归一化关键点 xyn。
        :param image_bytes: JPEG/PNG 图像字节（摄像头逐帧输入）
        :return: {
            "keypoints": [[x_norm, y_norm, confidence], ...],  # 来自 result.keypoints.xyn，归一化 [0,1]
            "image_width": int,
            "image_height": int,
            "num_persons": int,
            "annotated_image_base64": str  # img = results.plot(line_width=1) 的 JPEG (base64)
        }
        """
        import cv2
        nparr = np.frombuffer(image_bytes, np.uint8)
        frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if frame is None:
            return {
                "keypoints": [],
                "image_width": 0,
                "image_height": 0,
                "num_persons": 0,
                "annotated_image_base64": "",
            }

        h, w = frame.shape[:2]
        model = cls.get_model()

        # 单帧推理
        results = model(frame, verbose=False)
        result = results[0]

        # 使用 plot(line_width=1) 生成输出视频流图像
        img = result.plot(line_width=1)

        all_keypoints: List[List[float]] = []
        num_persons = 0

        if result.keypoints is not None:
            # 使用 xyn 获取归一化坐标 [0,1]
            xyn = result.keypoints.xyn.cpu().numpy()  # shape: (N, 17, 2)
            data = result.keypoints.data.cpu().numpy()  # shape: (N, 17, 3) x,y,conf

            for i in range(xyn.shape[0]):
                num_persons += 1
                for j in range(min(xyn.shape[1], len(KEYPOINT_NAMES))):
                    x_norm = float(xyn[i, j, 0])
                    y_norm = float(xyn[i, j, 1])
                    conf = float(data[i, j, 2]) if data.ndim >= 3 else 0.0
                    if conf > 0.25:
                        x_norm = max(0.0, min(1.0, x_norm))
                        y_norm = max(0.0, min(1.0, y_norm))
                        all_keypoints.append([x_norm, y_norm, conf])

        _, jpeg_bytes = cv2.imencode(".jpg", img)
        annotated_base64 = base64.b64encode(jpeg_bytes.tobytes()).decode("utf-8")

        return {
            "keypoints": all_keypoints,
            "image_width": w,
            "image_height": h,
            "num_persons": num_persons,
            "annotated_image_base64": annotated_base64,
        }
