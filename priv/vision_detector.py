#!/usr/bin/env python3
"""
YOLO vision detector sidecar for Vivino (Gleam/BEAM).

Reads RTSP stream, runs GPU inference, outputs JSON lines to stdout.
Receives commands on stdin (optional).

Output format (one JSON object per line):
{"ts":1707840000123,"fps":14.8,"detections":[
  {"class":"person","conf":0.87,"bbox":[120,45,340,360],"area":48400}
],"motion":0.034,"frame":1042,"inference_ms":1.2}
"""
import sys
import json
import time
import threading
import argparse
import numpy as np

# Must be set before importing cv2
import os
os.environ["YOLO_VERBOSE"] = "false"
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;udp"

try:
    from ultralytics import YOLO
except ImportError:
    print(json.dumps({"error": "ultralytics not installed. Run: pip install ultralytics"}),
          flush=True)
    sys.exit(1)

import cv2


class VisionDetector:
    def __init__(self, rtsp_url, model_path="yolo11s.pt", conf=0.35,
                 target_classes=None, imgsz=640):
        self.rtsp_url = rtsp_url
        self.conf = conf
        self.imgsz = imgsz
        self.target_classes = target_classes
        self.running = True
        self.frame_count = 0
        self.prev_gray = None
        self.fps_ema = 0.0

        # Load model (auto-detects .engine for TensorRT)
        self.model = YOLO(model_path)

        # Warm up GPU
        dummy = np.zeros((360, 640, 3), dtype=np.uint8)
        self.model.predict(dummy, verbose=False, device=0)
        print(json.dumps({"status": "ready", "model": model_path}), flush=True)

    def compute_motion(self, frame):
        """Compute motion score via frame differencing."""
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (21, 21), 0)
        if self.prev_gray is None:
            self.prev_gray = gray
            return 0.0
        delta = cv2.absdiff(self.prev_gray, gray)
        self.prev_gray = gray
        return float(np.mean(delta) / 255.0)

    def process_frame(self, frame):
        """Run YOLO + motion detection on a single frame."""
        t0 = time.monotonic()

        results = self.model.predict(
            frame,
            conf=self.conf,
            device=0,
            imgsz=self.imgsz,
            verbose=False,
            half=True,
            classes=self.target_classes,
        )

        motion = self.compute_motion(frame)

        detections = []
        for box in results[0].boxes:
            cls_id = int(box.cls[0])
            cls_name = results[0].names[cls_id]
            confidence = float(box.conf[0])
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            bbox = [int(x1), int(y1), int(x2), int(y2)]
            area = int((x2 - x1) * (y2 - y1))
            detections.append({
                "class": cls_name,
                "conf": round(confidence, 3),
                "bbox": bbox,
                "area": area,
            })

        elapsed = time.monotonic() - t0
        fps = 1.0 / elapsed if elapsed > 0 else 0
        self.fps_ema = 0.9 * self.fps_ema + 0.1 * fps if self.fps_ema > 0 else fps
        self.frame_count += 1

        return {
            "ts": int(time.time() * 1000),
            "fps": round(self.fps_ema, 1),
            "detections": detections,
            "motion": round(motion, 4),
            "frame": self.frame_count,
            "inference_ms": round(elapsed * 1000, 1),
        }

    def listen_stdin(self):
        """Listen for commands on stdin (from Erlang port)."""
        try:
            for line in sys.stdin:
                cmd = line.strip()
                if cmd == "STOP":
                    self.running = False
                    break
                elif cmd.startswith("CONF:"):
                    try:
                        self.conf = float(cmd[5:])
                    except ValueError:
                        pass
                elif cmd.startswith("CLASSES:"):
                    try:
                        self.target_classes = [int(c) for c in cmd[8:].split(",")]
                    except ValueError:
                        pass
        except Exception:
            self.running = False

    def run(self):
        """Main loop: capture RTSP frames and process them."""
        stdin_thread = threading.Thread(target=self.listen_stdin, daemon=True)
        stdin_thread.start()

        cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
        if not cap.isOpened():
            print(json.dumps({"error": "Cannot open RTSP stream",
                              "url": self.rtsp_url}), flush=True)
            sys.exit(1)

        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        try:
            while self.running:
                ret, frame = cap.read()
                if not ret:
                    print(json.dumps({"error": "frame_drop",
                                      "frame": self.frame_count}), flush=True)
                    time.sleep(1)
                    cap.release()
                    cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
                    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                    continue

                result = self.process_frame(frame)
                sys.stdout.write(json.dumps(result, separators=(',', ':')) + '\n')
                sys.stdout.flush()

        except KeyboardInterrupt:
            pass
        finally:
            cap.release()
            print(json.dumps({"status": "stopped"}), flush=True)


def main():
    parser = argparse.ArgumentParser(description="YOLO Vision Detector for Vivino")
    parser.add_argument("rtsp_url", help="RTSP stream URL")
    parser.add_argument("--model", default="yolo11s.pt", help="Model path (.pt or .engine)")
    parser.add_argument("--conf", type=float, default=0.35, help="Confidence threshold")
    parser.add_argument("--imgsz", type=int, default=640, help="Inference image size")
    parser.add_argument("--classes", default=None,
                        help="Comma-separated class IDs (e.g., 0,1,2)")
    args = parser.parse_args()

    target_classes = None
    if args.classes:
        target_classes = [int(c) for c in args.classes.split(",")]

    detector = VisionDetector(
        rtsp_url=args.rtsp_url,
        model_path=args.model,
        conf=args.conf,
        target_classes=target_classes,
        imgsz=args.imgsz,
    )
    detector.run()


if __name__ == "__main__":
    main()
