#!/usr/bin/env bash
set -euo pipefail

# 0_set-bc.sh
# Set the Fluent boundary conditions (inlet velocities, UDF profile hook) and
# write the ready case file.  This is the first step in the HIL pipeline.
#
# Usage:
#   ./0_set-bc.sh
#   STHIL_AIR_VELOCITY=0.5 STHIL_HE_VELOCITY=10 ./0_set-bc.sh
#
# Environment variables:
#   STHIL_AIR_VELOCITY   air inlet velocity in m/s (default 0.001)
#   STHIL_HE_VELOCITY    helium inlet velocity in m/s (default 50)
#   STHIL_CASE_IN        input case file (default elbow_hil_ready.cas.h5)
#   STHIL_CASE_OUT       output case file (default same as input)

# Resolve ROOT to the directory containing this script, so the same scripts
# work in the main project or any checkpoint copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}"
FLUENT_UDF="${ROOT}/fluent_udf"

AIR_V="${STHIL_AIR_VELOCITY:-0.001}"
HE_V="${STHIL_HE_VELOCITY:-50}"
CASE_IN="${STHIL_CASE_IN:-${FLUENT_UDF}/elbow_hil_ready.cas.h5}"
CASE_OUT="${STHIL_CASE_OUT:-${CASE_IN}}"

JOURNAL="${FLUENT_UDF}/set_bc.jou"

mkdir -p "${FLUENT_UDF}/frames"

cat > "${JOURNAL}" <<EOF
; Set inlet BCs and re-hook UDF profile.
/file/set-tui-version "26.1"
chdir ${FLUENT_UDF}

/file/confirm-overwrite? no

file/read-case ${CASE_IN}
/define/user-defined/compiled-functions/load ${FLUENT_UDF}/libudf

; velocity-inlet-5 (air, left horizontal): magnitude/dir, absolute, magnitude=${AIR_V}, direction (1,0)
/define/boundary-conditions/velocity-inlet velocity-inlet-5 yes yes no ${AIR_V} no 0 no 1 no 0 no 300 no no yes 5 10 no no 0

; velocity-inlet-6 (helium, bottom vertical): magnitude/dir, absolute, magnitude=${HE_V}, direction (0,1)
; Keep UDF profile for he fraction.
/define/boundary-conditions/velocity-inlet velocity-inlet-6 yes yes no ${HE_V} no 0 no 0 no 1 no 300 no no yes 5 10 no yes yes udf species_mass_fraction::libudf

file/write-case ${CASE_OUT}
exit yes
EOF

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

# Tell the UDF where the project root is so it writes auto_frame.jou and
# frames into the same directory tree as this script.
export STHIL_ROOT="${ROOT}"

echo "Setting BCs: air=${AIR_V} m/s, helium=${HE_V} m/s"
QT_QPA_PLATFORM=offscreen /home/nulltype/ansys_inc/v261/fluent/bin/fluent 2d -t1 -driver null -i "${JOURNAL}"

echo "Wrote ${CASE_OUT}"
