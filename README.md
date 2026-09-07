# ST-HIL: Species Transport Flow & Control Simulation

- Automated hardware validation via serial console (UART), synchronizing fluid simulation states with FPGA logic.
- Hardware-in-the-Loop (HIL) harness where outlet concentration thresholds dynamically actuate FPGA-mapped control valves (Tang Nano 20K).
- Verified system timing, protocol response boundaries, and fail-safe logic under simulated environmental conditions.
- **Adaptive frame-rate rendering:** skips PNG I/O when the outlet helium fraction and controller duty change fall below tunable thresholds (`STHIL_Y_THRESHOLD`, `STHIL_CMD_THRESHOLD`), avoiding simulation pauses for unnecessary frame dumps.

## Demo preview

![Helium concentration contour](fluent_udf/helium_smooth_constant.mp4)

*Helium-air mixing elbow contour — outlet helium mass fraction is mapped to a 0–255 sensor byte (`SENSOR_MAX=0.2`, so `STHIL_SETPOINT=100` ≈ Y_he 7.8%, or ~39% of sensor saturation). A PI controller raises inlet valve duty when the filtered sensor exceeds the setpoint (slew-limited, clamped 0–255). The image shows full-open state (duty 255) because the outlet area-averaged sensor reads near zero at frame-decision time. The video looks jittery at the start because the adaptive frame-dropping threshold skips frames when change is low; it smooths out toward the final seconds as dynamics stabilize.*

## Pipeline overview

The workflow is split into four numbered shell scripts:

| Step | Script | What it does |
|------|--------|--------------|
| 0 | `0_set-bc.sh` | Set Fluent inlet BCs and re-hook the UDF profile. |
| 1 | `1_hilflash.sh` | Build and flash the Tang Nano 20K FPGA firmware. |
| 2 | `2_simulate.sh` | Generate the journal and run the Fluent simulation. |
| 3 | `3_compile-view.sh` | Compile the UDF and/or build MP4/GIF animations. |

Run them in order.  Steps 1 and 3 can be skipped if you only want the software
fallback or if the UDF is already compiled.

## Quick start

```bash
cd /home/nulltype/Projects/ST-HIL

# 1. Set boundary conditions (air 0.001 m/s, helium 50 m/s by default)
./0_set-bc.sh

# 2. (Optional) Build and flash the FPGA
./1_hilflash.sh

# 3. Run the simulation (default: 500 steps, save every step)
./2_simulate.sh --clear-frames

# 4. Build the constant-frame-rate video
./3_compile-view.sh --constant
```

## Environment variables

All tunable parameters are exposed as environment variables.  Set them before
calling the script.

### Simulation setup

| Variable | Default | Description |
|----------|---------|-------------|
| `STHIL_N_STEPS` | 500 | Number of time steps to run. |
| `STHIL_TIME_STEP` | 0.01 | Time step size in seconds. |
| `STHIL_INNER_ITERS` | 10 | Inner iterations per time step. |
| `STHIL_AIR_VELOCITY` | 0.001 | Air inlet velocity in m/s. |
| `STHIL_HE_VELOCITY` | 50 | Helium inlet velocity in m/s. |
| `STHIL_N_PROCS` | 4 | Fluent parallel processes (`-tN`). |
| `STHIL_DRIVER` | null | Graphics driver: `null` or `opengl2`. |
| `STHIL_X_RES` | 1280 | PNG frame width. |
| `STHIL_Y_RES` | 720 | PNG frame height. |
| `STHIL_SAVE_FINAL` | 1 | Write final case/data file? 1/0. |
| `STHIL_CASE_IN` | `fluent_udf/elbow_hil_ready.cas.h5` | Input case for `0_set-bc.sh`. |
| `STHIL_CASE_OUT` | same as input | Output case from `0_set-bc.sh`. |

### Controller tuning (software fallback and UDF)

| Variable | Default | Description |
|----------|---------|-------------|
| `STHIL_SETPOINT` | 100 | Target sensor byte (0-255). |
| `STHIL_KP` | 8 | Proportional gain. |
| `STHIL_KI` | 0 | Integral gain. |
| `STHIL_SLEW` | 32 | Max duty change per frame. |
| `STHIL_MAX_DUTY` | 255 | Upper duty clamp. |
| `STHIL_FILTER` | 128 | Sensor EMA alpha. |
| `STHIL_DEADBAND` | 2 | Error deadband in sensor counts. |
| `STHIL_MIN_FRAME_EVERY` | 1 | Minimum frame interval in time steps. |
| `STHIL_SAVE_ALL_FRAMES` | 0 | Force save every frame? 1/0. |
| `STHIL_FORCE_SOFTWARE` | 0 | Disable FPGA, use software controller? 1/0. |
| `STHIL_Y_THRESHOLD` | 0.0005 | Adaptive frame threshold for outlet Y_he change. |
| `STHIL_CMD_THRESHOLD` | 2 | Adaptive frame threshold for duty change (counts). |

### Examples

```bash
# Short smoke test with software fallback
STHIL_FORCE_SOFTWARE=1 ./2_simulate.sh --smoke --clear-frames

# Adaptive frames: save at most every 5 steps, or on significant change
STHIL_MIN_FRAME_EVERY=5 ./2_simulate.sh --clear-frames

# Lower helium velocity so the plume interacts with the outlet
STHIL_HE_VELOCITY=10 STHIL_AIR_VELOCITY=0.5 ./0_set-bc.sh
STHIL_HE_VELOCITY=10 STHIL_AIR_VELOCITY=0.5 STHIL_SETPOINT=60 ./2_simulate.sh --clear-frames

# Run longer with a smaller time step
STHIL_N_STEPS=1000 STHIL_TIME_STEP=0.005 ./2_simulate.sh --clear-frames
```

## Script options

### `0_set-bc.sh`

No command-line options.  Use environment variables above.

### `1_hilflash.sh`

| Option | Description |
|--------|-------------|
| `--sram-only` | Build and load into SRAM only (faster for development). |
| `--flash-only` | Flash an existing `build/st_hil.fs` to persistent flash. |

### `2_simulate.sh`

| Option | Description |
|--------|-------------|
| `--clear-frames` | Delete existing `fluent_udf/frames/*.png` before running. |
| `--smoke` | Run a 3-step smoke test. |
| `--nogfx` | Run without PNG frame export. |

### `3_compile-view.sh`

| Option | Description |
|--------|-------------|
| `--compile` | Compile the UDF. |
| `--video` | Build MP4/GIF from the saved adaptive frames. |
| `--constant` | Build constant-frame-rate MP4/GIF by duplicating/holding frames. |
| `--all` | Compile + build both videos. |

## Directory layout

```
st-hil/
├── 0_set-bc.sh
├── 1_hilflash.sh
├── 2_simulate.sh
├── 3_compile-view.sh
├── HANDBOOK.md
├── restart_license_server.sh
├── fluent_udf/
│   ├── species_uart_control.c      # UDF source
│   ├── generate_animation_journal.py
│   ├── make_constant_framerate.py
│   ├── elbow_hil_ready.cas.h5      # case with BCs + UDF hook
│   ├── elbow.msh                   # original mesh
│   ├── frames/                     # generated PNG frames
│   └── libudf/                     # compiled UDF (created by --compile)
└── fpga_firmware/
    ├── src/                        # Verilog source
    │   ├── species_fsm.v
    │   ├── top.v
    │   ├── uart_rx.v
    │   ├── uart_tx.v
    │   └── pins.cst
    ├── build/                      # synthesis artifacts (created by 1_hilflash.sh)
    └── test_fpga.py                # interactive UART test
```

## Notes

- The UDF source has hard-coded paths pointing to this checkpoint directory.
  If you move the directory, update `FRAME_JOURNAL` and `FRAME_DIR` in
  `fluent_udf/species_uart_control.c` and rerun `3_compile-view.sh --compile`.
- `2_simulate.sh` automatically recompiles the UDF if `species_uart_control.c`
  is newer than the compiled `libudf.so`.
- The local Ansys FlexNet license server is restarted automatically if it is
  not listening on port 1055.
- The null graphics driver (`-driver null`) is the reference configuration that
  produced working PNG frames in Fluent 2026 R1.
