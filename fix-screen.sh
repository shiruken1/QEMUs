#!/usr/bin/env bash
#
# fix-screen.sh -- launched in the background by win11_osx.sh when FIX_SCREEN=1.
#
# The VM is booting in ramfb recovery mode (always-on display, no virtio-gpu).
# This script:
#   1. Waits for Windows to finish booting (OpenSSH Server answers on the
#      hostfwd port -- sshd is Automatic per win11-post-install.ps1).
#   2. Triggers display re-detection inside Windows (pnputil /scan-devices,
#      the scriptable equivalent of Device Manager -> "Scan for hardware
#      changes") and lists the monitors it sees.
#   3. Shuts Windows down (SSH shutdown, with ACPI system_powerdown via the
#      QEMU monitor socket as fallback).
#
# Boot normally afterwards (plain ./win11_osx.sh) to get virtio-gpu back with
# a clean scanout.
#
# Required env: WIN_USER (Windows account name).
# Optional env: SSH_KEY, SSH_HOST_PORT, MONITOR_SOCK, BOOT_TIMEOUT,
#               SETTLE_SECONDS.
set -u

MONITOR_SOCK="${MONITOR_SOCK:-/tmp/qemu-win11.sock}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
WIN_USER="${WIN_USER:?Set WIN_USER to your Windows account name (e.g. FIX_SCREEN=1 WIN_USER=andres ./win11_osx.sh)}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_win11}"    # private key matching the one post-install step 4b installed
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"          # seconds to wait for sshd before giving up
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"       # extra settle time after first SSH answer

SSH_OPTS=(-p "$SSH_HOST_PORT" -i "$SSH_KEY"
          -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=5 -o LogLevel=ERROR)

echo "[fix-screen] Waiting for Windows to boot (ssh $WIN_USER@127.0.0.1:$SSH_HOST_PORT, timeout ${BOOT_TIMEOUT}s)..."
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until ssh "${SSH_OPTS[@]}" "$WIN_USER@127.0.0.1" exit 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "[fix-screen] Timed out waiting for sshd. Leaving the VM running" >&2
        echo "[fix-screen] so you can fix things manually. Is key-based SSH set" >&2
        echo "[fix-screen] up (post-install step 4b)? Is WIN_USER correct?" >&2
        exit 1
    fi
    sleep 5
done

echo "[fix-screen] Windows is up. Letting the display stack settle ${SETTLE_SECONDS}s..."
sleep "$SETTLE_SECONDS"

echo "[fix-screen] Triggering display detection (pnputil /scan-devices)..."
ssh "${SSH_OPTS[@]}" "$WIN_USER@127.0.0.1" \
    'pnputil /scan-devices; Get-PnpDevice -Class Monitor | Format-Table FriendlyName,Status -AutoSize' \
    2>/dev/null || echo "[fix-screen] scan command failed; continuing to shutdown anyway"

echo "[fix-screen] Shutting Windows down..."
ssh "${SSH_OPTS[@]}" "$WIN_USER@127.0.0.1" 'shutdown /s /t 5' 2>/dev/null || {
    echo "[fix-screen] SSH shutdown failed; using ACPI powerdown via monitor socket."
    printf 'system_powerdown\n' | nc -U "$MONITOR_SOCK"
}
echo "[fix-screen] Done. Boot normally (plain ./win11_osx.sh) to get virtio-gpu back."
