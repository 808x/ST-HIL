#!/usr/bin/env bash
set -euo pipefail

# compile_udf.sh
# Compile the species_uart_control UDF directly with the generated Makefile.
# This is also available as ./3_compile-view.sh --compile.

cd /home/nulltype/Projects/ST-HIL/st-hil_260803-adaptive/fluent_udf/libudf
make clean && make
