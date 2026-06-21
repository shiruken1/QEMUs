#!/usr/bin/env bash
# Start Homebrew Samba for QEMU Windows guest (Ubuntu-style Fix A).
# QEMU forwards guest TCP 445 -> host 127.0.0.1:445; share appears as \\10.0.2.2\samba

set -euo pipefail

SMBD="${SMBD:-$(command -v samba-dot-org-smbd)}"
SMB_CONF="${SMB_CONF:-/opt/homebrew/etc/smb.conf}"
SAMBA_STATE="${SAMBA_STATE:-/opt/homebrew/var/lib/samba}"
SAMBA_LOG="${SAMBA_LOG:-/opt/homebrew/var/log/samba}"

ensure_dirs() {
    mkdir -p \
        "$SAMBA_STATE"/{private,lock,cache,ncalrpc} \
        "$SAMBA_LOG/cores"
}

cmd="${1:-status}"

case "$cmd" in
    setup)
        ensure_dirs
        if [ ! -f "$SMB_CONF" ]; then
            echo "Missing $SMB_CONF — copy smb.conf.osx.example and edit path/force user."
            exit 1
        fi
        # testparm is unreliable in the source-built 4.16.x smbd; validate by
        # letting smbd parse the config in the foreground on a throwaway port.
        tmp="$(mktemp -d)"
        if timeout 4 "$SMBD" -F --debug-stdout --configfile="$SMB_CONF" --port=4456 -d0 \
            --option="private dir=$tmp" --option="lock directory=$tmp" \
            --option="state directory=$tmp" --option="cache directory=$tmp" \
            --option="pid directory=$tmp" --option="ncalrpc dir=$tmp/ncalrpc" 2>&1 \
            | grep -q "Error loading services"; then
            echo "Config FAILED to load: $SMB_CONF"; rm -rf "$tmp"; exit 1
        fi
        rm -rf "$tmp"
        echo "Samba state dirs ready. Config OK: $SMB_CONF"
        ;;
    start)
        ensure_dirs
        if [ ! -x "$SMBD" ]; then
            echo "samba-dot-org-smbd not found. Install: brew install samba"
            exit 1
        fi
        if pgrep -x samba-dot-org-smbd >/dev/null; then
            echo "samba-dot-org-smbd already running (pid $(pgrep -x samba-dot-org-smbd))"
            exit 0
        fi
        # Port 445 is privileged on macOS, so smbd must run as root.
        # -D = daemonize; -s = config file
        sudo "$SMBD" -D -s "$SMB_CONF"
        sleep 1
        if pgrep -x samba-dot-org-smbd >/dev/null; then
            echo "samba-dot-org-smbd started. Guest path: \\\\10.0.2.2\\samba"
        else
            echo "smbd failed to start. Check: tail $SAMBA_LOG/log.smbd"
            exit 1
        fi
        ;;
    stop)
        if pgrep -x samba-dot-org-smbd >/dev/null; then
            sudo pkill -x samba-dot-org-smbd
            echo "samba-dot-org-smbd stopped."
        else
            echo "samba-dot-org-smbd not running."
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        ensure_dirs
        if pgrep -x samba-dot-org-smbd >/dev/null; then
            echo "running (pid $(pgrep -x samba-dot-org-smbd))"
        else
            echo "not running"
        fi
        if [ -f "$SMB_CONF" ]; then
            grep -E '^\[samba\]|^[[:space:]]*path =|^[[:space:]]*force user =' "$SMB_CONF" || true
        fi
        echo "smbd: $("$SMBD" -V 2>/dev/null)"
        ;;
    test)
        ensure_dirs
        smbclient -N -L 127.0.0.1
        ;;
    *)
        echo "Usage: $0 {setup|start|stop|restart|status|test}"
        exit 1
        ;;
esac
