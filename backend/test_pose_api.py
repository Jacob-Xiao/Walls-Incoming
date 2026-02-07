"""快速测试 /api/pose/detect 接口"""
import io
import json
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# 创建 100x100 的简单测试图像 (RGB)
try:
    from PIL import Image
    img = Image.new("RGB", (100, 100), color=(128, 128, 128))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    image_bytes = buf.getvalue()
except ImportError:
    # 无 PIL 时用最小有效 JPEG 占位
    image_bytes = (
        b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
        b'\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t\x08\n\x0c'
        b'\xff\xd9'  # 最小 JPEG
    )

url = "http://localhost:8000/api/pose/detect"
boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="frame.jpg"\r\n'
    "Content-Type: image/jpeg\r\n\r\n"
).encode() + image_bytes + f"\r\n--{boundary}--\r\n".encode()

req = Request(url, data=body, method="POST")
req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

try:
    with urlopen(req, timeout=60) as r:
        d = json.loads(r.read().decode())
        print(f"Status: {r.status}")
        print(f"keypoints: {len(d.get('keypoints', []))}")
        print(f"annotated_image_base64 length: {len(d.get('annotated_image_base64', ''))}")
        print("OK - API 工作正常")
except (URLError, HTTPError) as e:
    print(f"Request failed: {e}")
    sys.exit(1)
