#!/usr/bin/env python3
"""Fully decode a native export and verify frame cadence and media metadata.

ffmpeg/ffprobe are developer verification tools, not application dependencies.
"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("folder", type=Path)
parser.add_argument("--movie", default="sample.mp4")
parser.add_argument("--frames", type=int)
parser.add_argument("--ffmpeg", default="ffmpeg")
parser.add_argument("--ffprobe", default="ffprobe")
args = parser.parse_args()
movie = args.folder / args.movie
streams = json.loads(subprocess.check_output([args.ffprobe, "-v", "error", "-count_frames", "-show_streams", "-of", "json", str(movie)]))["streams"]
video = next(s for s in streams if s["codec_type"] == "video")
audio = next(s for s in streams if s["codec_type"] == "audio")
n, d = map(int, video["r_frame_rate"].split("/"))
fps = n / d
assert fps in (30, 60)
rows = subprocess.check_output([args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0", str(movie)], text=True)
pts = [float(s.split(",")[0]) for s in rows.splitlines() if s.split(",")[0].strip()]
expected = args.frames
report = args.folder / "export.json"
if expected is None and report.exists():
    export = json.loads(report.read_text())
    if Path(export["output"]).name == args.movie:
        expected = export["frameCount"]
if expected is None:
    expected = round(float(video["duration"]) * fps)
assert len(pts) == expected and pts[0] == 0
assert all(b > a for a, b in zip(pts, pts[1:]))
error = max((abs(b - a - 1 / fps) for a, b in zip(pts, pts[1:])), default=0)
assert error < 0.000001
assert abs(float(audio["duration"]) - float(video["duration"])) < 1 / 48000
assert video["codec_name"] == "h264" and audio["codec_name"] == "aac"
assert video["color_primaries"] == "bt709" and audio["sample_rate"] == "48000" and audio["channels"] == 2
assert (video["width"], video["height"]) in ((1920, 1080), (1080, 1920))
subprocess.run([args.ffmpeg, "-v", "error", "-i", str(movie), "-f", "null", "-"], check=True)
result = {
    "fullDecodePassed": True, "frameCount": len(pts), "fps": fps,
    "width": video["width"], "height": video["height"],
    "videoCodec": video["codec_name"], "audioCodec": audio["codec_name"],
    "sampleRate": 48000, "channels": 2, "colorPrimaries": video["color_primaries"],
    "videoDuration": float(video["duration"]), "audioDuration": float(audio["duration"]),
    "firstPTS": pts[0], "lastPTS": pts[-1], "strictlyIncreasingPTS": True,
    "maximumCadenceErrorSeconds": error,
}
(args.folder / "decoded-media.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
