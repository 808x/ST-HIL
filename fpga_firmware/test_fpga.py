#!/usr/bin/env python3
"""Interactive test for the Tang Nano 20K practical HIL controller.

Protocol:
  Host -> FPGA: 0xAA <sensor_byte>   normal control frame
                0xBB                 request 16-byte diagnostic dump
                0xBC <addr> <value>  write config register

  FPGA -> Host: 1 byte valve opening (0x00 = closed, 0xFF = full open)
                16 bytes for diagnostic dump

Default config registers (addr -> meaning):
  0  SETPOINT   target sensor value (0-255)
  1  Kp         proportional gain (0-15)
  2  Ki         integral gain per frame, scaled (0-15)
  3  SLEW       max duty change per frame (0-255)
  4  MAX_DUTY   upper clamp (0-255)
  5  FILTER     sensor EMA alpha (0-255, 0 = none, 128 = 0.5, 255 = raw)
  6  DEADBAND   error deadband (0-15 sensor counts)

Usage:
  python3 test_fpga.py              # auto-detect FPGA port
  python3 test_fpga.py /dev/ttyUSB0 # use specific port
  python3 test_fpga.py --kill       # kill any process using the FPGA port
"""

import argparse
import glob
import os
import signal
import sys
import serial
import time

BAUD = 115200
TIMEOUT = 0.2
PROBE_TIMEOUT = 0.3


def find_process_using_port(device):
    """Return (pid, cmdline) of the process holding the device, or None."""
    dev_path = os.path.realpath(device)
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            fd_dir = f"/proc/{pid}/fd"
            for fd in os.listdir(fd_dir):
                try:
                    link = os.readlink(f"{fd_dir}/{fd}")
                    if link == dev_path or link == device:
                        with open(f"/proc/{pid}/cmdline", "rb") as f:
                            cmdline = f.read().replace(b"\x00", b" ").decode("utf-8", errors="replace").strip()
                        return int(pid), cmdline
                except (OSError, PermissionError):
                    continue
        except (OSError, PermissionError):
            continue
    return None


def probe_port(port):
    """Send test frame and wait for a valid FPGA reply."""
    port.write(bytes([0xAA, 0x00]))
    port.flush()
    reply = port.read(1)
    return len(reply) == 1


def find_fpga_port(preferred=None, kill_occupant=False):
    """Find the FPGA UART port, preferring the Sipeed debugger if01 interface."""
    candidates = []
    if preferred:
        candidates.append(preferred)
    else:
        # Sipeed Tang Nano 20K debugger exposes two interfaces:
        #   if00 -> BL702 secondary channel (may echo old firmware)
        #   if01 -> FPGA UART (the one we want)
        by_id = sorted(glob.glob("/dev/serial/by-id/*"))
        for link in by_id:
            if "if01" in os.path.basename(link):
                candidates.append(os.path.realpath(link))
        for link in by_id:
            if "if00" in os.path.basename(link):
                candidates.append(os.path.realpath(link))
        candidates.extend(sorted(glob.glob("/dev/ttyUSB*")))
        candidates.extend(sorted(glob.glob("/dev/ttyACM*")))

    responders = []
    for device in candidates:
        if not os.path.exists(device):
            continue

        occupant = find_process_using_port(device)
        if occupant:
            pid, cmdline = occupant
            if kill_occupant:
                print(f"Killing process {pid} using {device}: {cmdline}")
                try:
                    os.kill(pid, signal.SIGTERM)
                    for _ in range(20):
                        if find_process_using_port(device) is None:
                            break
                        time.sleep(0.05)
                except ProcessLookupError:
                    pass
            else:
                print(f"Warning: {device} is already in use by process {pid}: {cmdline}")
                print("Run with --kill to terminate it, or stop that process first.")
                continue

        try:
            port = serial.Serial(device, BAUD, timeout=PROBE_TIMEOUT)
        except serial.SerialException as e:
            print(f"Could not open {device}: {e}")
            continue

        if probe_port(port):
            responders.append(port)
        else:
            port.close()

    if not responders:
        return None

    # Prefer the port running the new 16-byte diagnostic firmware.
    for port in responders:
        port.write(bytes([0xBB]))
        port.flush()
        time.sleep(0.05)
        data = port.read(16)
        if len(data) == 16:
            print(f"Found FPGA on {port.port}")
            for p in responders:
                if p is not port:
                    p.close()
            return port

    # Fall back to the first responder (likely old firmware or BL702 echo).
    print(f"Found FPGA on {responders[0].port}")
    for p in responders[1:]:
        p.close()
    return responders[0]


def send_frame(port, sensor):
    port.write(bytes([0xAA, sensor]))
    port.flush()
    reply = port.read(1)
    if len(reply) == 1:
        return reply[0]
    return None


def send_diag_dump(port):
    port.write(bytes([0xBB]))
    port.flush()
    # 16 bytes @ 115200 baud ~= 1.4 ms; give the FPGA time to start + finish
    time.sleep(0.05)
    data = port.read(16)
    if len(data) != 16:
        print(f"  diag dump incomplete ({len(data)} bytes): {data.hex()}")
        return
    sensor = data[0]
    filtered = data[1]
    sp = data[2]
    valve = data[3]
    kp = data[4] & 0x0F
    ki = data[5] & 0x0F
    slew = data[6]
    max_duty = data[7]
    filt = data[8]
    deadband = data[9] & 0x0F
    watchdog = data[10]
    button = data[11]
    print(f"  sensor=0x{sensor:02X} filtered=0x{filtered:02X} setpoint=0x{sp:02X} "
          f"valve=0x{valve:02X} Kp={kp} Ki={ki} slew={slew} max_duty={max_duty} "
          f"filter={filt} deadband={deadband} watchdog={watchdog} button={button}")


def send_config(port, addr, value):
    port.write(bytes([0xBC, addr & 0xFF, value & 0xFF]))
    port.flush()
    reply = port.read(1)
    if len(reply) == 1:
        print(f"  config addr={addr} value={value} -> reply=0x{reply[0]:02X}")
    else:
        print("  config no reply")


def main():
    parser = argparse.ArgumentParser(description="Test FPGA UART link")
    parser.add_argument("device", nargs="?", help="UART device to use (auto-detect if omitted)")
    parser.add_argument("--kill", action="store_true", help="Kill any process occupying the FPGA port")
    args = parser.parse_args()

    port = find_fpga_port(preferred=args.device, kill_occupant=args.kill)
    if port is None:
        print("Failed to find FPGA on any UART port.")
        sys.exit(1)

    print(f"Opened {port.port} at {BAUD} baud")
    print("Commands:")
    print("  0-9,a-f  send sensor value (hex)")
    print("  d        diagnostic dump")
    print("  c aa vv  write config addr=aa value=vv (hex)")
    print("  r        repeat last sensor value")
    print("  q        quit")
    print()

    last_sensor = 0x00
    while True:
        try:
            cmd = input("> ").strip().lower()
        except EOFError:
            break
        if not cmd:
            continue
        if cmd == "q":
            break
        if cmd == "r":
            sensor = last_sensor
        elif cmd == "d":
            send_diag_dump(port)
            continue
        elif cmd.startswith("c "):
            parts = cmd.split()
            if len(parts) != 3:
                print("Invalid config command; use: c aa vv")
                continue
            try:
                addr = int(parts[1], 16)
                value = int(parts[2], 16)
            except ValueError:
                print("Invalid hex value")
                continue
            send_config(port, addr, value)
            continue
        else:
            try:
                sensor = int(cmd, 16) & 0xFF
            except ValueError:
                print("Invalid input")
                continue

        last_sensor = sensor
        reply = send_frame(port, sensor)
        if reply is None:
            print(f"  sensor=0x{sensor:02X} -> NO REPLY (timeout)")
        elif reply == 0x00:
            print(f"  sensor=0x{sensor:02X} -> 0x00 CLOSED")
        elif reply == 0xFF:
            print(f"  sensor=0x{sensor:02X} -> 0xFF FULL OPEN")
        else:
            print(f"  sensor=0x{sensor:02X} -> 0x{reply:02X} ({reply / 255.0 * 100:.1f}% open)")

    port.close()


if __name__ == "__main__":
    main()
