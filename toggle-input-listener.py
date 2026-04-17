#!/usr/bin/env python3
"""
Listen for Scroll Lock on a host control input device and toggle:
  - QEMU evdev keyboard object (hostkbd)
  - QEMU USB trackpad device (trackpad0)

Run with sudo while gpu.sh VM is running.
"""

import argparse
import errno
import glob
import os
import select
import socket
import struct
import sys
import time

EV_KEY = 0x01
KEY_SCROLLLOCK = 70
KEY_PAUSE = 119
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
    # Match gpu.sh default: /tmp/qemu-gpu-<uid>.sock (SUDO_UID when run via sudo)
    _uid = os.environ.get("SUDO_UID", str(os.geteuid()))
    _default_sock = f"/tmp/qemu-gpu-{_uid}.sock"
    parser = argparse.ArgumentParser(description="Toggle QEMU keyboard+trackpad with Scroll Lock")
    parser.add_argument("--monitor-sock", default=_default_sock, help=f"QEMU monitor socket (default: {_default_sock})")
    parser.add_argument("--kbd-evdev", default="/dev/input/by-id/usb-04f3_0103-event-kbd")
    parser.add_argument(
        "--control-evdev",
        default="auto",
        help="Control input device path, comma-separated paths, or 'auto' to scan keyboard event devices.",
    )
    parser.add_argument("--grab-toggle", default="scrolllock")
    parser.add_argument("--hotkey-code", type=int, default=KEY_PAUSE, help="Linux input keycode to trigger toggle (default: Pause/Break=119)")
    parser.add_argument("--kbd-grab-all", choices=["on", "off"], default="off")
    parser.add_argument("--trackpad-id", default="trackpad0")
    parser.add_argument("--trackpad-vendorid", default="0x05ac")
    parser.add_argument("--trackpad-productid", default="0x0265")
    parser.add_argument("--start-mode", choices=["vm", "host"], default="host")
    parser.add_argument("--wait-seconds", type=float, default=30.0)
    parser.add_argument("--debug-keys", action="store_true", help="Print observed EV_KEY codes/values from control devices.")
    parser.add_argument(
        "--include-all-events",
        action="store_true",
        help="With --control-evdev auto, also include /dev/input/event* (noisy; usually unnecessary).",
    )
    parser.add_argument("--debounce-ms", type=int, default=200, help="Hotkey debounce time in milliseconds.")
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
        # Optionally include raw event nodes for unusual keyboards.
        if args.include_all_events:
            control_paths.extend(sorted(glob.glob("/dev/input/event*")))
    else:
        control_paths.extend([p.strip() for p in args.control_evdev.split(",") if p.strip()])

    if args.kbd_evdev not in control_paths:
        control_paths.append(args.kbd_evdev)
    # Deduplicate while preserving order. Use realpath so by-id symlinks and
    # /dev/input/eventX aliases do not register twice for the same device.
    seen: set[str] = set()
    uniq_paths: list[str] = []
    for p in control_paths:
        rp = os.path.realpath(p)
        if rp in seen:
            continue
        seen.add(rp)
        uniq_paths.append(p)
    control_paths = [p for p in uniq_paths if os.path.exists(p)]
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
        # Ensure we do not inherit a stale hostkbd object from gpu.sh or prior toggles.
        print(hmp_command(args.monitor_sock, "object_del hostkbd").strip())
        cmd_kbd = (
            "object_add input-linux,id=hostkbd,"
            f"evdev={args.kbd_evdev},grab_all={args.kbd_grab_all},repeat=on,grab-toggle={args.grab_toggle}"
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
    print(f"Monitor socket: {args.monitor_sock}")
    print("Press Pause/Break to toggle input (or override with --hotkey-code).")
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
    debounce_s = max(0.0, args.debounce_ms / 1000.0)

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
                except OSError as exc:
                    # Device can disappear/re-enumerate while VM toggles inputs.
                    if exc.errno in (errno.ENODEV, errno.ENXIO, errno.EIO):
                        path = control_fds.get(fd, f"fd:{fd}")
                        print(f"Warning: control device disappeared: {path} ({exc})", file=sys.stderr)
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                        control_fds.pop(fd, None)
                        continue
                    raise
                if len(data) != EVENT_SIZE:
                    continue
                _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
                if args.debug_keys and etype == EV_KEY:
                    print(f"key event from {control_fds.get(fd, f'fd:{fd}')}: code={code} value={value}")
                if etype == EV_KEY and code == args.hotkey_code and value == 1:
                    saw_toggle = True
                    break
            if not control_fds:
                print("No control devices remain open; exiting.", file=sys.stderr)
                return 1
            if not saw_toggle:
                continue

            now = time.time()
            if now - last_toggle_ts < debounce_s:
                if args.debug_keys:
                    print(f"hotkey ignored due to debounce ({args.debounce_ms}ms)")
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

