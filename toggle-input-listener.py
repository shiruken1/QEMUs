#!/usr/bin/env python3
"""
Listen for Scroll Lock on a host control input device and toggle:
  - QEMU evdev keyboard object (hostkbd)
  - QEMU USB trackpad device (trackpad0)

Run with sudo while gpu.sh VM is running.
"""

import argparse
import glob
import os
import select
import socket
import struct
import sys
import time

EV_KEY = 0x01
KEY_SCROLLLOCK = 70
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)


def hmp_command(sock_path: str, command: str) -> str:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.3)
    s.connect(sock_path)
    output = b""
    try:
        try:
            output += s.recv(4096)
        except socket.timeout:
            pass
        s.sendall((command + "\n").encode("utf-8"))
        end = time.time() + 0.5
        while time.time() < end:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                output += chunk
                if b"(qemu)" in output:
                    break
            except socket.timeout:
                break
    finally:
        s.close()
    return output.decode("utf-8", errors="ignore")


def main() -> int:
    parser = argparse.ArgumentParser(description="Toggle QEMU keyboard+trackpad with Scroll Lock")
    parser.add_argument("--monitor-sock", default="/tmp/qemu-gpu.sock")
    parser.add_argument("--kbd-evdev", default="/dev/input/by-id/usb-04f3_0103-event-kbd")
    parser.add_argument(
        "--control-evdev",
        default="auto",
        help="Control input device path, comma-separated paths, or 'auto' to scan event-kbd devices.",
    )
    parser.add_argument("--grab-toggle", default="ctrl-ctrl")
    parser.add_argument("--kbd-grab-all", choices=["on", "off"], default="off")
    parser.add_argument("--trackpad-id", default="trackpad0")
    parser.add_argument("--trackpad-vendorid", default="0x05ac")
    parser.add_argument("--trackpad-productid", default="0x0265")
    parser.add_argument("--start-mode", choices=["vm", "host"], default="host")
    parser.add_argument("--wait-seconds", type=float, default=30.0)
    args = parser.parse_args()
    if os.geteuid() != 0:
        print("Run as root (sudo) so input device + monitor socket are accessible.", file=sys.stderr)
        return 1

    if not os.path.exists(args.kbd_evdev):
        print(f"Keyboard evdev path not found: {args.kbd_evdev}", file=sys.stderr)
        return 1

    control_paths: list[str] = []
    if args.control_evdev == "auto":
        control_paths.extend(sorted(glob.glob("/dev/input/by-id/*event-kbd")))
    else:
        control_paths.extend([p.strip() for p in args.control_evdev.split(",") if p.strip()])

    if args.kbd_evdev not in control_paths:
        control_paths.append(args.kbd_evdev)
    control_paths = [p for p in control_paths if os.path.exists(p)]
    if not control_paths:
        print(f"No usable control input devices found from: {args.control_evdev}", file=sys.stderr)
        return 1

    end = time.time() + args.wait_seconds
    while not os.path.exists(args.monitor_sock) and time.time() < end:
        time.sleep(0.1)
    if not os.path.exists(args.monitor_sock):
        print(f"QEMU monitor socket not found after wait: {args.monitor_sock}", file=sys.stderr)
        return 1

    def switch_to_host() -> None:
        print("-> Switching to HOST mode")
        print(hmp_command(args.monitor_sock, "object_del hostkbd").strip())
        print(hmp_command(args.monitor_sock, f"device_del {args.trackpad_id}").strip())

    def switch_to_vm() -> None:
        print("-> Switching to VM mode")
        cmd_kbd = (
            "object_add input-linux,id=hostkbd,"
            f"evdev={args.kbd_evdev},grab_all={args.kbd_grab_all},repeat=on"
        )
        print(hmp_command(args.monitor_sock, cmd_kbd).strip())
        cmd_tp = (
            f"device_add usb-host,id={args.trackpad_id},"
            f"vendorid={args.trackpad_vendorid},productid={args.trackpad_productid},bus=xhci.0"
        )
        print(hmp_command(args.monitor_sock, cmd_tp).strip())

    vm_mode = args.start_mode == "vm"
    print("Listening on control devices:")
    for p in control_paths:
        print(f"  - {p}")
    print(f"VM keyboard device: {args.kbd_evdev}")
    print("Press Scroll Lock to toggle input.")
    print(f"Initial mode: {'VM owns keyboard+trackpad' if vm_mode else 'Host owns keyboard+trackpad'}")
    if vm_mode:
        switch_to_vm()
    else:
        switch_to_host()

    control_fds: dict[int, str] = {}
    for path in control_paths:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            control_fds[fd] = path
        except OSError as exc:
            print(f"Warning: failed to open {path}: {exc}", file=sys.stderr)
    if not control_fds:
        print("Could not open any control input devices.", file=sys.stderr)
        return 1
    last_toggle_ts = 0.0

    try:
        while True:
            readable, _, _ = select.select(list(control_fds.keys()), [], [], 1.0)
            if not readable:
                continue
            saw_toggle = False
            for fd in readable:
                try:
                    data = os.read(fd, EVENT_SIZE)
                except BlockingIOError:
                    continue
                if len(data) != EVENT_SIZE:
                    continue
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
                if etype == EV_KEY and code == KEY_SCROLLLOCK and value == 1:
                    saw_toggle = True
                    break
            if not saw_toggle:
                continue

            now = time.time()
            if now - last_toggle_ts < 0.35:
                continue
            last_toggle_ts = now

            if vm_mode:
                switch_to_host()
                vm_mode = False
            else:
                switch_to_vm()
                vm_mode = True
    except KeyboardInterrupt:
        print("\nExiting listener.")
        return 0
    finally:
        for fd in control_fds:
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())

