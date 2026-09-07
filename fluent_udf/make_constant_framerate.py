#!/usr/bin/env python3
"""Build a constant-frame-rate frame sequence from adaptive frames.

The UDF saves frames adaptively (e.g., time steps 1, 12, 23, ...).  To preserve
a steady frame rate in the final video, this script duplicates/holds each saved
frame for every missing time step until the next saved frame.

Usage:
    python3 make_constant_framerate.py
    python3 make_constant_framerate.py --fps 20
"""

import os
import re
import shutil
import argparse
import subprocess

FRAME_DIR = "/home/nulltype/Projects/ST-HIL/fluent_udf/frames"
INTER_DIR = os.path.join(FRAME_DIR, "inter")


def parse_time_step(filename):
    m = re.search(r"helium_adaptive_(\d+)\.png", filename)
    return int(m.group(1)) if m else None


def main():
    parser = argparse.ArgumentParser(description="Build constant-frame-rate sequence")
    parser.add_argument("--fps", type=int, default=20, help="output video frame rate")
    parser.add_argument("--no-video", action="store_true", help="only create inter frames, no MP4/GIF")
    args = parser.parse_args()

    frames = sorted(
        [f for f in os.listdir(FRAME_DIR) if f.endswith(".png") and parse_time_step(f) is not None],
        key=lambda f: parse_time_step(f),
    )

    if not frames:
        print(f"No frames found in {FRAME_DIR}")
        return 1

    # Remove and recreate inter directory
    if os.path.isdir(INTER_DIR):
        shutil.rmtree(INTER_DIR)
    os.makedirs(INTER_DIR)

    # Build filled sequence
    last_step = parse_time_step(frames[-1])
    frame_idx = 0
    saved_idx = 0

    for step in range(0, last_step + 1):
        # If this step has a saved frame, advance to it; otherwise hold previous
        if saved_idx < len(frames) and parse_time_step(frames[saved_idx]) == step:
            current_frame = frames[saved_idx]
            saved_idx += 1

        src = os.path.join(FRAME_DIR, current_frame)
        dst = os.path.join(INTER_DIR, f"helium_adaptive_{step:04d}.png")
        shutil.copy2(src, dst)
        frame_idx += 1

    print(f"Created {frame_idx} constant-frame-rate frames in {INTER_DIR}")

    if args.no_video:
        return 0

    mp4_out = "/home/nulltype/Projects/ST-HIL/fluent_udf/helium_smooth_constant.mp4"
    gif_out = "/home/nulltype/Projects/ST-HIL/fluent_udf/helium_smooth_constant.gif"

    # MP4
    subprocess.run(
        [
            "ffmpeg", "-y", "-framerate", str(args.fps),
            "-i", os.path.join(INTER_DIR, "helium_adaptive_%04d.png"),
            "-vf", "fps=" + str(args.fps) + ",format=yuv420p",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
            "-movflags", "+faststart", mp4_out,
        ],
        check=True,
    )
    print(f"Created {mp4_out}")

    # GIF
    subprocess.run(
        [
            "ffmpeg", "-y", "-framerate", str(args.fps),
            "-i", os.path.join(INTER_DIR, "helium_adaptive_%04d.png"),
            "-vf",
            "fps=" + str(args.fps) + ",scale=720:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer",
            "-loop", "0", gif_out,
        ],
        check=True,
    )
    print(f"Created {gif_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
