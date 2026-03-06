#!/bin/bash

sudo apt update && sudo apt upgrade

sudo apt-get install qemu-system qemu-utils swtpm -y  # for Ubuntu, Debian, Mint, and PopOS.

VMDIR=$(realpath $(dirname $0))
WIN11_DISK="$VMDIR/win11.qcow2"
OVMF_VARS_WIN="$VMDIR/firmware/OVMF_VARS_win11.fd"

(ls "$WIN11_DISK" >> /dev/null 2>&1 && echo "") || qemu-img create -f qcow2 "$WIN11_DISK" 64G

(ls "$OVMF_VARS_WIN" >> /dev/null 2>&1 && echo "") || cp "$VMDIR/firmware/OVMF_VARS.fd" "$OVMF_VARS_WIN"

if [ ! -f "$VMDIR/Win11.iso" ]; then
    echo "Win11.iso not found in $VMDIR."
    echo "Place your Windows 11 ISO there or set WIN11_ISO to its path."
fi

if [ ! -f "$VMDIR/virtio-win.iso" ]; then
    echo "virtio-win.iso not found in $VMDIR."
    echo "Optional: place it there or set VIRTIO_ISO to its path."
fi

sudo ./win11.sh
