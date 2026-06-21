#!/usr/bin/env bash
set -euo pipefail

# Inverse of usb-to-win11.sh: remove every hot-plugged usb-host device that
# script added (QEMU ids look like hostusb_<bus>_<addr>_<epoch>).
# Uses the same monitor socket discovery (plus win11.sh / gpu.sh defaults).
# Does not remove other usb-host backends (e.g. gpu.sh trackpad0).

SOCKET_ARG="${1:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd socat

pick_socket() {
  local s
  if [ -n "$SOCKET_ARG" ]; then
    if [ -S "$SOCKET_ARG" ]; then
      echo "$SOCKET_ARG"
      return
    fi
    echo "Monitor socket not found: $SOCKET_ARG" >&2
    exit 1
  fi

  local candidates=(
    "/tmp/qemu-win11.sock"
    "/tmp/qemu-win11-$(id -u).sock"
    "/tmp/qemu-gpu-$(id -u).sock"
    "/tmp/qemu-win11-1000.sock"
    "/tmp/qemu-gpu-1000.sock"
  )
  local sockets=()
  local seen="|"
  for s in "${candidates[@]}"; do
    [ -S "$s" ] || continue
    case "$seen" in
      *"|$s|"*) continue ;;
    esac
    seen+="$s|"
    sockets+=("$s")
  done

  if [ "${#sockets[@]}" -eq 0 ]; then
    echo "No running Win11 QEMU monitor socket found." >&2
    echo "Expected a socket such as /tmp/qemu-win11.sock or /tmp/qemu-gpu-$(id -u).sock" >&2
    echo "(or pass the path as the first argument.)" >&2
    exit 1
  fi

  if [ "${#sockets[@]}" -eq 1 ]; then
    echo "${sockets[0]}"
    return
  fi

  echo "Multiple running QEMU monitor sockets found:"
  local i=1
  for s in "${sockets[@]}"; do
    echo "  $i) $s"
    i=$((i + 1))
  done
  echo -n "Select socket [1-${#sockets[@]}]: "
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#sockets[@]}" ]; then
    echo "Invalid selection." >&2
    exit 1
  fi
  echo "${sockets[$((idx - 1))]}"
}

send_hmp() {
  local socket="$1"
  local cmd="$2"
  local out=""

  if out=$(printf '%s\n' "$cmd" | socat - UNIX-CONNECT:"$socket" 2>&1); then
    printf '%s\n' "$out"
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if out=$(printf '%s\n' "$cmd" | sudo socat - UNIX-CONNECT:"$socket" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf '%s\n' "$out" >&2
  return 1
}

list_hostusb_ids() {
  local socket="$1"
  local qtree
  if ! qtree="$(send_hmp "$socket" "info qtree")"; then
    return 1
  fi
  printf '%s\n' "$qtree" | sed -n 's/.*dev: usb-host, id "\(hostusb_[^"]*\)".*/\1/p' | sort -u
}

SOCKET="$(pick_socket)"
echo "Using monitor socket: $SOCKET"
echo

mapfile -t IDS < <(list_hostusb_ids "$SOCKET" || true)
if [ "${#IDS[@]}" -eq 0 ] || [ -z "${IDS[0]:-}" ]; then
  echo "No usb-to-win11 hotplug devices found (no hostusb_* usb-host entries in qtree)."
  exit 0
fi

echo "Removing from VM:"
for id in "${IDS[@]}"; do
  echo "  device_del $id"
  OUT="$(send_hmp "$SOCKET" "device_del ${id}" || true)"
  if grep -q "Error:" <<<"$OUT"; then
    echo "$OUT" >&2
  else
    echo "$OUT"
  fi
done

echo
echo "Done."
