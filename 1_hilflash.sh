#!/usr/bin/env bash
set -euo pipefail

# 1_hilflash.sh
# Build the FPGA firmware and flash it to the Tang Nano 20K board.
# This is the second step in the HIL pipeline.
#
# Usage:
#   ./1_hilflash.sh              build + load to SRAM + flash to persistent flash
#   ./1_hilflash.sh --sram-only  build + load to SRAM only (faster for dev)
#   ./1_hilflash.sh --flash-only flash existing build/st_hil.fs to persistent flash

ROOT="/home/nulltype/Projects/ST-HIL/st-hil_260803-adaptive"
FPGA_DIR="${ROOT}/fpga_firmware"
BUILD_DIR="${FPGA_DIR}/build"

DEVICE="GW2AR-LV18QN88C8/I7"
FAMILY="GW2A-18C"
BOARD="tangnano20k"

SRAM_ONLY=0
FLASH_ONLY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sram-only)
            SRAM_ONLY=1
            shift
            ;;
        --flash-only)
            FLASH_ONLY=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--sram-only|--flash-only]"
            exit 1
            ;;
    esac
done

cd "${FPGA_DIR}"

if [ "${FLASH_ONLY}" = "0" ]; then
    mkdir -p "${BUILD_DIR}"

    echo "=== Step 1: synthesis (yosys) ==="
    yosys -p "
      read_verilog src/uart_rx.v
      read_verilog src/uart_tx.v
      read_verilog src/species_fsm.v
      read_verilog src/top.v
      synth_gowin -top top -json ${BUILD_DIR}/st_hil.json
    "

    echo "=== Step 2: place-and-route (nextpnr-himbaechel) ==="
    nextpnr-himbaechel \
      --json "${BUILD_DIR}/st_hil.json" \
      --write "${BUILD_DIR}/st_hil_pnr.json" \
      --device "${DEVICE}" \
      --vopt family="${FAMILY}" \
      --vopt cst=src/pins.cst

    echo "=== Step 3: pack bitstream (gowin_pack) ==="
    gowin_pack -d "${FAMILY}" -o "${BUILD_DIR}/st_hil.fs" "${BUILD_DIR}/st_hil_pnr.json"

    echo "=== Step 4: load bitstream into SRAM for immediate test ==="
    openFPGALoader -b "${BOARD}" "${BUILD_DIR}/st_hil.fs"
fi

if [ "${SRAM_ONLY}" = "0" ]; then
    if [ ! -f "${BUILD_DIR}/st_hil.fs" ]; then
        echo "Error: ${BUILD_DIR}/st_hil.fs not found. Build first."
        exit 1
    fi
    echo "=== Step 5: flash bitstream to persistent external flash ==="
    openFPGALoader -b "${BOARD}" -f "${BUILD_DIR}/st_hil.fs"
    echo "Done. Power-cycle the board to load from flash."
fi
