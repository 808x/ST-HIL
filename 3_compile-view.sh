#!/usr/bin/env bash
set -euo pipefail

# 3_compile-view.sh
# Compile the UDF and/or build the animation from saved frames.
# This is the fourth step in the HIL pipeline.
#
# Usage:
#   ./3_compile-view.sh --compile              compile the UDF only
#   ./3_compile-view.sh --video              build MP4/GIF from frames
#   ./3_compile-view.sh --constant           build constant-frame-rate MP4/GIF
#   ./3_compile-view.sh --compile --video    compile UDF then build video
#   ./3_compile-view.sh --all                compile + build all videos

# Resolve ROOT to the directory containing this script, so the same scripts
# work in the main project or any checkpoint copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}"
FLUENT_UDF="${ROOT}/fluent_udf"

cd "${FLUENT_UDF}"

DO_COMPILE=0
DO_VIDEO=0
DO_CONSTANT=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --compile)
            DO_COMPILE=1
            shift
            ;;
        --video)
            DO_VIDEO=1
            shift
            ;;
        --constant)
            DO_CONSTANT=1
            shift
            ;;
        --all)
            DO_COMPILE=1
            DO_VIDEO=1
            DO_CONSTANT=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--compile] [--video] [--constant] [--all]"
            exit 1
            ;;
    esac
done

if [ "${DO_COMPILE}" = "0" ] && [ "${DO_VIDEO}" = "0" ] && [ "${DO_CONSTANT}" = "0" ]; then
    echo "Nothing to do. Use --compile, --video, --constant, or --all."
    exit 1
fi

if [ "${DO_COMPILE}" = "1" ]; then
    echo "=== Compiling UDF ==="
    if [ ! -d "${FLUENT_UDF}/libudf" ]; then
        echo "Creating libudf skeleton ..."
        mkdir -p "${FLUENT_UDF}/libudf/src"
        ln -sf "${FLUENT_UDF}/species_uart_control.c" "${FLUENT_UDF}/libudf/src/species_uart_control.c"
    fi
    cd "${FLUENT_UDF}/libudf"
    make clean && make
    cd "${FLUENT_UDF}"
fi

if [ "${DO_VIDEO}" = "1" ]; then
    echo "=== Building adaptive-frame MP4/GIF ==="
    FRAME_DIR="frames"
    MP4_OUT="helium_smooth.mp4"
    GIF_OUT="helium_smooth.gif"

    FRAME_COUNT=$(ls -1 "${FRAME_DIR}"/helium_adaptive_*.png 2>/dev/null | wc -l)
    if [ "${FRAME_COUNT}" -eq 0 ]; then
        echo "Error: no frames found in ${FRAME_DIR}"
        exit 1
    fi

    echo "Found ${FRAME_COUNT} adaptive frames."

    FRAME_LIST=$(mktemp)
    trap 'rm -f "${FRAME_LIST}"' EXIT

    for f in $(ls -1 "${FRAME_DIR}"/helium_adaptive_*.png | sort); do
        echo "file '${f}'" >> "${FRAME_LIST}"
    done

    echo "Creating ${MP4_OUT} ..."
    ffmpeg -y -f concat -safe 0 -i "${FRAME_LIST}" \
        -vf "fps=20,format=yuv420p" -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "${MP4_OUT}"

    echo "Creating ${GIF_OUT} ..."
    ffmpeg -y -f concat -safe 0 -i "${FRAME_LIST}" \
        -vf "fps=10,scale=720:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" \
        -loop 0 "${GIF_OUT}"

    echo "Done: ${MP4_OUT}, ${GIF_OUT}"
fi

if [ "${DO_CONSTANT}" = "1" ]; then
    echo "=== Building constant-frame-rate MP4/GIF ==="
    python3 "${FLUENT_UDF}/make_constant_framerate.py"
fi
