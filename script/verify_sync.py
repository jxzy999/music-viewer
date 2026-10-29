#!/usr/bin/env python3
"""Decode the native pulse export and measure media alignment, not metadata alone.

Requires developer tools ffmpeg/ffprobe and numpy; the Mac app has no such runtime dependency.
"""
import argparse
import json
import subprocess
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("folder", type=Path)
parser.add_argument("--ffmpeg", default="ffmpeg")
parser.add_argument("--ffprobe", default="ffprobe")
args = parser.parse_args()
folder = args.folder
expected = json.loads((folder / "expected.json").read_text())
movie = folder / "pulse.mp4"
streams = json.loads(subprocess.check_output([args.ffprobe, "-v", "error", "-show_streams", "-of", "json", str(movie)]))["streams"]
video = next(s for s in streams if s["codec_type"] == "video")
n, d = map(int, video["r_frame_rate"].split("/"))
fps = n / d
rate = expected["sampleRate"]
events = expected["events"]
audio_bytes = subprocess.check_output([args.ffmpeg, "-v", "error", "-i", str(movie), "-map", "0:a:0", "-ac", "1", "-ar", str(int(rate)), "-f", "f32le", "-"])
audio = np.abs(np.frombuffer(audio_bytes, dtype="<f4"))
peak = float(audio.max())
assert peak > 0.005, "Diagnostic audio is silent"
threshold = peak * 0.08
audio_onsets = []
for event in events:
    center = round(event["start"] * rate)
    a, b = max(0, center - round(rate * 0.05)), min(len(audio), center + round(rate * 0.05))
    crossing = np.flatnonzero(audio[a:b] >= threshold)
    assert crossing.size, f"Missing audio pulse: {event['id']}"
    audio_onsets.append((a + int(crossing[0])) / rate)

x, y = expected["pixelCenterX"] - 4, expected["pixelCenterY"] - 4
pixels = subprocess.check_output([args.ffmpeg, "-v", "error", "-i", str(movie), "-an", "-vf", f"crop=8:8:{x}:{y},format=rgb24", "-f", "rawvideo", "-"])
rgb = np.frombuffer(pixels, dtype=np.uint8).reshape(-1, 8, 8, 3).mean(axis=(1, 2))
contrast = (rgb[:,1] + rgb[:,2]) * 0.5 - rgb[:,0]
active = contrast > 18
visual_onsets = []
for event in events:
    center = int(event["start"] * fps)
    a, b = max(0, center - 2), min(len(active), center + 5)
    crossing = np.flatnonzero(active[a:b])
    assert crossing.size, f"Missing visual pulse: {event['id']}"
    visual_onsets.append((a + int(crossing[0])) / fps)

audio_error = np.array(audio_onsets) - np.array([e["start"] for e in events])
visual_error = np.array(visual_onsets) - np.array([e["start"] for e in events])
relative = np.array(visual_onsets) - np.array(audio_onsets)
allowed = 1 / fps + 1 / rate
result = {
    "eventsChecked": len(events), "fps": fps, "sampleRate": rate,
    "durationSeconds": expected["duration"], "allowedErrorSeconds": allowed,
    "maximumAudioOffsetSeconds": float(np.max(np.abs(audio_error))),
    "maximumVisualOffsetSeconds": float(np.max(np.abs(visual_error))),
    "maximumRelativeErrorSeconds": float(np.max(np.abs(relative))),
    "firstRelativeErrorSeconds": float(relative[0]), "lastRelativeErrorSeconds": float(relative[-1]),
    "relativeDriftSeconds": float(relative[-1] - relative[0]),
    "frameHash": expected["frameHash"], "deterministicAfterSeeking": expected["deterministicAfterSeeking"],
    "scope": expected["geometryScope"],
    "passed": bool(np.max(np.abs(relative)) <= allowed and np.max(np.abs(audio_error)) <= allowed and np.max(np.abs(visual_error)) <= allowed)
}
(folder / "sync-validation.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
assert result["passed"], "Decoded audio/visual events exceed one frame plus one sample"
