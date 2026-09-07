#!/usr/bin/env bash
set -euo pipefail

# 2_simulate.sh
# Generate the animation journal and run the Fluent HIL simulation.
# This is the third step in the HIL pipeline.
#
# Usage:
#   ./2_simulate.sh                         default 500-step run, save every step
#   ./2_simulate.sh --clear-frames          wipe frames/ before running
#   ./2_simulate.sh --smoke               short 3-step smoke test
#   ./2_simulate.sh --nogfx               run without PNG frame export
#
# Combine options in any order.
# Note: frame skipping is controlled by STHIL_MIN_FRAME_EVERY (default 1).
#       Set STHIL_MIN_FRAME_EVERY=5 for adaptive-style skipping.
#
# Key environment variables (all have defaults):
#   STHIL_N_STEPS          number of time steps (default 500)
#   STHIL_TIME_STEP        time step size in seconds (default 0.01)
#   STHIL_INNER_ITERS      inner iterations per time step (default 10)
#   STHIL_AIR_VELOCITY     air inlet velocity in m/s (default 0.001)
#   STHIL_HE_VELOCITY      helium inlet velocity in m/s (default 50)
#   STHIL_N_PROCS          Fluent parallel procs (default 4)
#   STHIL_DRIVER           graphics driver: null | opengl2 (default null)
#   STHIL_X_RES            PNG width (default 1280)
#   STHIL_Y_RES            PNG height (default 720)
#   STHIL_SAVE_FINAL       write final case/data? 1/0 (default 1)
#
# Controller tuning (forwarded to the UDF):
#   STHIL_SETPOINT         target sensor byte (default 100)
#   STHIL_KP               proportional gain (default 8)
#   STHIL_KI               integral gain (default 0)
#   STHIL_SLEW             max duty change per frame (default 32)
#   STHIL_MAX_DUTY         upper clamp (default 255)
#   STHIL_FILTER           sensor EMA alpha (default 128)
#   STHIL_DEADBAND         error deadband (default 2)
#   STHIL_MIN_FRAME_EVERY  minimum frame interval in time steps (default 1)
#   STHIL_SAVE_ALL_FRAMES  force save every frame? 1/0 (default 0)
#   STHIL_FORCE_SOFTWARE   disable FPGA, use software controller? 1/0 (default 0)

# Resolve ROOT to the directory containing this script, so the same scripts
# work in the main project or any checkpoint copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}"
FLUENT_UDF="${ROOT}/fluent_udf"

export QT_QPA_PLATFORM=offscreen

# Tell the UDF where the project root is so it writes auto_frame.jou and
# frames into the same directory tree as this script.
export STHIL_ROOT="${ROOT}"

# Defaults
export STHIL_N_STEPS="${STHIL_N_STEPS:-500}"
export STHIL_TIME_STEP="${STHIL_TIME_STEP:-0.01}"
export STHIL_INNER_ITERS="${STHIL_INNER_ITERS:-10}"
export STHIL_AIR_VELOCITY="${STHIL_AIR_VELOCITY:-0.001}"
export STHIL_HE_VELOCITY="${STHIL_HE_VELOCITY:-50}"
export STHIL_N_PROCS="${STHIL_N_PROCS:-4}"
export STHIL_DRIVER="${STHIL_DRIVER:-null}"
export STHIL_X_RES="${STHIL_X_RES:-1280}"
export STHIL_Y_RES="${STHIL_Y_RES:-720}"
export STHIL_SAVE_FINAL="${STHIL_SAVE_FINAL:-1}"

# Controller defaults
export STHIL_SETPOINT="${STHIL_SETPOINT:-100}"
export STHIL_KP="${STHIL_KP:-8}"
export STHIL_KI="${STHIL_KI:-0}"
export STHIL_SLEW="${STHIL_SLEW:-32}"
export STHIL_MAX_DUTY="${STHIL_MAX_DUTY:-255}"
export STHIL_FILTER="${STHIL_FILTER:-128}"
export STHIL_DEADBAND="${STHIL_DEADBAND:-2}"
export STHIL_MIN_FRAME_EVERY="${STHIL_MIN_FRAME_EVERY:-1}"
export STHIL_SAVE_ALL_FRAMES="${STHIL_SAVE_ALL_FRAMES:-0}"
export STHIL_FORCE_SOFTWARE="${STHIL_FORCE_SOFTWARE:-0}"

MODE="simulate"
CLEAR_FRAMES=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clear-frames)
            CLEAR_FRAMES=1
            shift
            ;;
        --smoke)
            MODE="smoke"
            export STHIL_N_STEPS=3
            export STHIL_MIN_FRAME_EVERY=1
            shift
            ;;
        --nogfx)
            MODE="nogfx"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--clear-frames] [--smoke] [--nogfx]"
            exit 1
            ;;
    esac
done

cd "${FLUENT_UDF}"
mkdir -p frames

if [ "${CLEAR_FRAMES}" = "1" ]; then
    echo "Clearing frames directory ..."
    rm -f frames/helium_adaptive_*.png
fi

# Recompile UDF if source is newer than the shared library.
LIB_HOST="${FLUENT_UDF}/libudf/lnamd64/2d_host/libudf.so"
LIB_NODE="${FLUENT_UDF}/libudf/lnamd64/2d_node/libudf.so"
if [ "${FLUENT_UDF}/species_uart_control.c" -nt "${LIB_HOST}" ] || \
   [ "${FLUENT_UDF}/species_uart_control.c" -nt "${LIB_NODE}" ]; then
    echo "UDF source is newer than compiled library; recompiling ..."
    bash "${ROOT}/3_compile-view.sh" --compile
fi

# Ensure license server is alive.
if ! ss -tlnp 2>/dev/null | grep -q ':1055 '; then
    echo "License server not listening on 1055; restarting ..."
    LIC_DIR="/home/nulltype/ansys_inc/shared_files/licensing"
    pkill -9 -f lmgrd 2>/dev/null || true
    pkill -9 -f ansyslmd 2>/dev/null || true
    for i in {1..10}; do
        if ! ss -tlnp 2>/dev/null | grep -q ':1055 '; then break; fi
        sleep 1
    done
    nohup "${LIC_DIR}/linx64/lmgrd" -c "${LIC_DIR}/license_files/ansyslmd.lic" -l "${LIC_DIR}/license_files/license.log" > /dev/null 2>&1 &
    sleep 3
fi

# Generate the journal from current environment.
python3 "${FLUENT_UDF}/generate_animation_journal.py"

JOURNAL="${FLUENT_UDF}/animate_hil.jou"

if [ "${MODE}" = "nogfx" ]; then
    echo "Running simulation without graphics export ..."
    /home/nulltype/ansys_inc/v261/fluent/bin/fluent 2d -t"${STHIL_N_PROCS}" -driver null -g -i "${FLUENT_UDF}/nogfx.jou"
else
    echo "Running simulation: steps=${STHIL_N_STEPS}, dt=${STHIL_TIME_STEP}, inner=${STHIL_INNER_ITERS}, procs=${STHIL_N_PROCS}"
    /home/nulltype/ansys_inc/v261/fluent/bin/fluent 2d -t"${STHIL_N_PROCS}" -driver "${STHIL_DRIVER}" -i "${JOURNAL}"
fi

echo "Simulation finished. Frames are in ${FLUENT_UDF}/frames"
