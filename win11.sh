#!/usr/bin/env bash

VMDIR=$(realpath $(dirname $0))
OVMF=$VMDIR/firmware
SECBOOT_CODE_SYS="/usr/share/OVMF/OVMF_CODE.secboot.fd"
SECBOOT_VARS_SYS="/usr/share/OVMF/OVMF_VARS.secboot.fd"
OVMF_CODE_FILE="$OVMF/OVMF_CODE.fd"
OVMF_VARS_WIN="$OVMF/OVMF_VARS_win11.fd"
WIN11_DISK="${WIN11_DISK:-$HOME/.qemu/win11.qcow2}"
WIN11_ISO="${WIN11_ISO:-$VMDIR/Win11.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-$VMDIR/virtio-win.iso}"
if [ -z "$XDG_RUNTIME_DIR" ] && [ -n "$SUDO_USER" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")"
fi
# Use /tmp for TPM socket - swtpm often can't create sockets in /run/user/
TPM_STATE_DIR="${TPM_STATE_DIR:-$HOME/.local/state/osxvm-tpm-$(id -u)}"
TPM_SOCKET_DIR="${TPM_SOCKET_DIR:-/tmp/osxvm-tpm-$(id -u)}"
TPM_SOCKET="$TPM_SOCKET_DIR/swtpm-sock"

# Always reset OVMF_VARS from template to prevent boot hangs from UEFI variable corruption
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
if [ -f "$OVMF_VARS_TEMPLATE" ]; then
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_WIN"
elif [ -f "$OVMF/OVMF_VARS.fd" ]; then
    cp "$OVMF/OVMF_VARS.fd" "$OVMF_VARS_WIN"
fi
(ls "$WIN11_DISK" >> /dev/null 2>&1 && echo "") || qemu-img create -f qcow2 "$WIN11_DISK" 64G

# Clean up stale TPM socket if swtpm isn't running
if [ -e "$TPM_SOCKET" ] && ! pgrep -f "swtpm.*$TPM_SOCKET" > /dev/null; then
    echo "Removing stale TPM socket..."
    rm -f "$TPM_SOCKET"
fi

if [ ! -S "$TPM_SOCKET" ]; then
    mkdir -p "$TPM_STATE_DIR" "$TPM_SOCKET_DIR"
    chmod 700 "$TPM_STATE_DIR" "$TPM_SOCKET_DIR"
    if [ -e "$TPM_SOCKET" ]; then
        rm -f "$TPM_SOCKET"
    fi
    swtpm socket --tpm2 --tpmstate dir="$TPM_STATE_DIR" --ctrl type=unixio,path="$TPM_SOCKET" --daemon
    if [ $? -ne 0 ]; then
        echo "Failed to start swtpm. Try running without sudo or set TPM_DIR to a writable path."
        exit 1
    fi
fi

NETDEV="user,id=net0"
echo "SMB share: \\\\10.0.2.2\\samba -> /home/me (via system Samba)"

MOREARGS=()
DISKARGS=()
AUDIOARGS=()

# Display mode: SPICE (default), GTK, or headless VNC
# SPICE enables clipboard sharing, auto-resolution, and better integration
DISPLAYARGS=(-display spice-app)
SPICEARGS=(
    -device virtio-serial-pci
    -chardev spicevmc,id=vdagent,debug=0,name=vdagent
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
)
if [ "$HEADLESS" = "1" ]; then
    DISPLAYARGS=(-nographic -vnc :1 -k en-us)
    SPICEARGS=()
elif [ "$DISPLAY_MODE" = "gtk" ]; then
    DISPLAYARGS=(-display gtk)
    SPICEARGS=()
fi

if [ "${INCLUDE_INSTALL_MEDIA:-0}" = "1" ]; then
    if [ ! -f "$WIN11_ISO" ]; then
        echo "Missing Windows 11 ISO at $WIN11_ISO"
        exit 1
    fi
    MOREARGS+=(
        -drive id=InstallMedia,if=none,format=raw,file="$WIN11_ISO"
        -device ide-cd,bus=sata.2,drive=InstallMedia
        -boot order=d
    )
else
    MOREARGS+=(-boot order=c)
fi

if [ "${INCLUDE_VIRTIO:-1}" = "1" ] && [ -f "$VIRTIO_ISO" ]; then
    MOREARGS+=(
        -drive id=VirtioISO,if=none,format=raw,file="$VIRTIO_ISO"
        -device ide-cd,bus=sata.3,drive=VirtioISO
    )
fi

if [ "${USE_SATA_DISK:-1}" = "1" ]; then
    DISKARGS+=(
        -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache=writeback,aio=threads
        -device ide-hd,bus=sata.4,drive=SystemDisk
    )
else
    DISKARGS+=(
        -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache=writeback,aio=threads
        -device virtio-blk-pci,drive=SystemDisk
    )
fi

AUDIO_BACKEND="${AUDIO_BACKEND:-pipewire}"
if [ "$AUDIO_BACKEND" = "none" ]; then
    AUDIOARGS=()
else
    AUDIOARGS=(
        -audiodev "$AUDIO_BACKEND",id=audio0
        -device ich9-intel-hda
        -device hda-output,audiodev=audio0
    )
fi

args=(
    -enable-kvm \
    -m 16G -mem-prealloc \
    -machine q35,accel=kvm,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -global ICH9-LPC.disable_s3=1 \
    -smp cores=8,threads=2,sockets=1 \
    -cpu host,kvm=on \
    -boot menu=on \
    -monitor unix:/tmp/qemu-win11.sock,server,nowait \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_FILE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_WIN" \
    "${AUDIOARGS[@]}" \
    "${DISPLAYARGS[@]}" \
    -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
    -device ich9-ahci,id=sata \
    -netdev "$NETDEV" \
    -device virtio-net-pci,netdev=net0,id=net0 \
    "${DISKARGS[@]}" \
    -chardev socket,id=chrtpm,path="$TPM_SOCKET" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -device virtio-vga,max_hostmem=8589934592 \
    "${SPICEARGS[@]}" \
    "${MOREARGS[@]}"
)

/usr/local/bin/qemu-system-x86_64 "${args[@]}"
