#!/usr/bin/env bash
set -euo pipefail

# Interactive USB passthrough helper for running Win11 QEMU VMs.
# - Lists USB devices visible on host (excluding root hubs)
# - Lets you pick one device
# - Hot-plugs selected device into running QEMU VM via monitor socket

SOCKET_ARG="${1:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd lsusb
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

  local sockets=()
  for s in /tmp/qemu-win11-1000.sock /tmp/qemu-gpu-1000.sock; do
    [ -S "$s" ] && sockets+=("$s")
  done

  if [ "${#sockets[@]}" -eq 0 ]; then
    echo "No running Win11 QEMU monitor socket found." >&2
    echo "Expected one of: /tmp/qemu-win11-1000.sock or /tmp/qemu-gpu-1000.sock" >&2
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

  # Retry with sudo if socket permissions require root.
  if [ "$(id -u)" -ne 0 ]; then
    if out=$(printf '%s\n' "$cmd" | sudo socat - UNIX-CONNECT:"$socket" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf '%s\n' "$out" >&2
  return 1
}

SOCKET="$(pick_socket)"
echo "Using monitor socket: $SOCKET"
echo

mapfile -t USB_LINES < <(lsusb | grep -v -i 'Linux Foundation')
if [ "${#USB_LINES[@]}" -eq 0 ]; then
  echo "No passthrough candidate USB devices found (only root hubs visible)." >&2
  exit 1
fi

echo "USB devices on host:"
for i in "${!USB_LINES[@]}"; do
  n=$((i + 1))
  echo "  $n) ${USB_LINES[$i]}"
done
echo
echo -n "Select device [1-${#USB_LINES[@]}] (or q to quit): "
read -r sel
if [ "$sel" = "q" ] || [ "$sel" = "Q" ]; then
  exit 0
fi
if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#USB_LINES[@]}" ]; then
  echo "Invalid selection." >&2
  exit 1
fi

LINE="${USB_LINES[$((sel - 1))]}"
BUS="$(awk '{print $2}' <<<"$LINE")"
DEV="$(awk '{print $4}' <<<"$LINE" | tr -d ':')"
VIDPID="$(awk '{print $6}' <<<"$LINE")"
VID="0x${VIDPID%:*}"
PID="0x${VIDPID#*:}"

BUS_DEC=$((10#$BUS))
DEV_DEC=$((10#$DEV))
ID_SUFFIX="$(date +%s)"
DEV_ID="hostusb_${BUS}_${DEV}_${ID_SUFFIX}"

echo
echo "Selected:"
echo "  $LINE"
echo "  hostbus=$BUS_DEC hostaddr=$DEV_DEC vendorid=$VID productid=$PID"
echo

# Prefer hostbus/hostaddr to target the exact physical device instance.
CMD="device_add usb-host,id=${DEV_ID},hostbus=${BUS_DEC},hostaddr=${DEV_DEC},bus=xhci.0"
echo "Attaching to VM..."
OUT="$(send_hmp "$SOCKET" "$CMD" || true)"
echo "$OUT"

if grep -q "Error:" <<<"$OUT"; then
  if grep -q "Bus 'xhci.0' not found" <<<"$OUT"; then
    echo
    echo "VM is missing xHCI controller. Start VM with: -device qemu-xhci,id=xhci" >&2
  fi
  exit 1
fi

echo
echo "Done. Device attached to VM as id=${DEV_ID}"
echo "To detach back to Lubuntu later:"
echo "  printf 'device_del ${DEV_ID}\n' | sudo socat - UNIX-CONNECT:${SOCKET}"

