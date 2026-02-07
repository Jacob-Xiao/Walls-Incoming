"""
YOLO26-pose 人体关键点检测服务
从接收的图像中检测人体关键点，返回归一化坐标 [0,1] 及 YOLO 绘制关键点后的图像
"""
import base64
import numpy as np
from pathlib import Path
from typing import List, Tuple

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
        对图像进行人体关键点检测，并返回 YOLO 绘制关键点后的图像。
        :param image_bytes: JPEG/PNG 图像字节
        :return: {
            "keypoints": [[x_norm, y_norm, confidence], ...],  # 归一化到 [0,1]
            "image_width": int,
            "image_height": int,
            "num_persons": int,
            "annotated_image_base64": str  # YOLO 绘制关键点后的 JPEG 图像 (base64)
        }
        """
        import cv2
        nparr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if img is None:
            return {
                "keypoints": [],
                "image_width": 0,
                "image_height": 0,
                "num_persons": 0,
                "annotated_image_base64": "",
            }

        h, w = img.shape[:2]
        model = cls.get_model()
        results = model(img, verbose=False)

        all_keypoints: List[List[float]] = []
        num_persons = 0

        for r in results:
            if r.keypoints is None:
                continue
            kpts = r.keypoints
            for i in range(kpts.shape[0]):
                num_persons += 1
                person_kpts = kpts[i]  # Keypoints 对象，用 .data 取 (num_kpts, 3) 的 x,y,conf
                data = person_kpts.data.cpu().numpy()
                if data.ndim == 3:
                    data = data[0]
                for j in range(min(data.shape[0], len(KEYPOINT_NAMES))):
                    x, y, conf = float(data[j, 0]), float(data[j, 1]), float(data[j, 2])
                    if conf > 0.25:  # 置信度阈值
                        x_norm = x / w if w > 0 else 0
                        y_norm = y / h if h > 0 else 0
                        x_norm = max(0, min(1, x_norm))
                        y_norm = max(0, min(1, y_norm))
                        all_keypoints.append([x_norm, y_norm, float(conf)])
                        name = KEYPOINT_NAMES[j]
                        print(f"[关键点] {name}: 像素(x={x:.1f}, y={y:.1f}) 归一化(x={x_norm:.3f}, y={y_norm:.3f}) 置信度={conf:.2f}")

        # 使用 YOLO 自带的 plot 方法绘制关键点到图像上
        annotated_img = results[0].plot() if results and len(results) > 0 else img
        _, jpeg_bytes = cv2.imencode(".jpg", annotated_img)
        annotated_base64 = base64.b64encode(jpeg_bytes.tobytes()).decode("utf-8")

        return {
            "keypoints": all_keypoints,
            "image_width": w,
            "image_height": h,
            "num_persons": num_persons,
            "annotated_image_base64": annotated_base64,
        }
