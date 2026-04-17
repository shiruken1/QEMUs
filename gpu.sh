#!/usr/bin/env bash

VMDIR=$(realpath $(dirname $0))
OVMF=$VMDIR/firmware
RUN_AS_USER="${USER}"
RUN_AS_UID="$(id -u)"
RUN_AS_HOME="${HOME}"
RUN_AS_GID="$(id -g "$RUN_AS_UID" 2>/dev/null || true)"
if [ -n "${SUDO_USER:-}" ]; then
    RUN_AS_USER="$SUDO_USER"
    RUN_AS_UID="$(id -u "$SUDO_USER")"
    RUN_AS_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    RUN_AS_GID="$(id -g "$SUDO_USER" 2>/dev/null || true)"
fi
SECBOOT_CODE_SYS="/usr/share/OVMF/OVMF_CODE.secboot.fd"
SECBOOT_VARS_SYS="/usr/share/OVMF/OVMF_VARS.secboot.fd"
OVMF_CODE_FILE="$OVMF/OVMF_CODE.fd"
OVMF_VARS_WIN="$OVMF/OVMF_VARS_win11.fd"
WIN11_DISK="${WIN11_DISK:-$RUN_AS_HOME/.qemu/win11.qcow2}"
# WIN11_DISK="${WIN11_DISK:-$VMDIR/win11.qcow2}"
BOOT_ISO="${BOOT_ISO:-}"
VIRTIO_ISO="${VIRTIO_ISO:-$VMDIR/virtio-win.iso}"
if [ -z "$XDG_RUNTIME_DIR" ] && [ -n "${SUDO_USER:-}" ]; then
    XDG_RUNTIME_DIR="/run/user/$RUN_AS_UID"
fi
# If we're using PipeWire audio, surface a helpful warning early when the
# user's PipeWire socket isn't reachable.
if [ "${AUDIO_BACKEND:-pipewire}" = "pipewire" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    PW_SOCKET="${XDG_RUNTIME_DIR%/}/pipewire-0"
    if [ ! -S "$PW_SOCKET" ]; then
        echo "WARNING: PipeWire socket not found at $PW_SOCKET"
        echo "         (qemu will still start; this often causes 'host is down' errors)."
    fi
fi
# Use /tmp for TPM socket - swtpm often can't create sockets in /run/user/
TPM_STATE_DIR="${TPM_STATE_DIR:-$RUN_AS_HOME/.local/state/osxvm-tpm-gpu-$RUN_AS_UID}"
TPM_SOCKET_DIR="${TPM_SOCKET_DIR:-/tmp/osxvm-tpm-gpu-$RUN_AS_UID}"
TPM_SOCKET="$TPM_SOCKET_DIR/swtpm-sock"
MONITOR_SOCKET="${MONITOR_SOCKET:-/tmp/qemu-gpu-$RUN_AS_UID.sock}"
VFIO_GROUP_NODE=""
VFIO_GROUP_NODE_ORIG_MODE=""
IOMMU_GROUP_ID=""
IOMMU_GROUP_DEVICES=()
ORIG_GROUP_DRIVERS=()

GPU_PCI="0000:03:00.0"
GPU_VENDOR_ID="10de 2204"
GPU_NVIDIA_DEV="${GPU_NVIDIA_DEV:-/dev/nvidia1}"
GPU_X_VGA="${GPU_X_VGA:-on}"
AUDIO_BACKEND="${AUDIO_BACKEND:-pipewire}"
VM_MEMORY="${VM_MEMORY:-16G}"
VM_SOCKETS="${VM_SOCKETS:-1}"
VM_CORES="${VM_CORES:-6}"
VM_THREADS="${VM_THREADS:-2}"
CPU_MODEL="${CPU_MODEL:-host,kvm=on,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time}"
MEM_PREALLOC="${MEM_PREALLOC:-0}"
DISK_IF="${DISK_IF:-sata}"
DISK_CACHE="${DISK_CACHE:-writeback}"
DISK_AIO="${DISK_AIO:-threads}"
QEMU_CPU_PIN="${QEMU_CPU_PIN:-}"

# --- GPU VFIO bind/unbind helpers ---

bind_vfio() {
    local pci_addr="$1"
    local pci_short="${pci_addr#0000:}"
    local current_driver
    current_driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_addr/driver" 2>/dev/null)" 2>/dev/null)

    if [ "$current_driver" = "vfio-pci" ]; then
        echo "  $pci_addr already bound to vfio-pci"
        return 0
    fi

    if [ -n "$current_driver" ]; then
        echo "  $pci_addr: unbinding from $current_driver"
        echo "$pci_addr" > "/sys/bus/pci/devices/$pci_addr/driver/unbind" 2>/dev/null
    fi

    echo "  $pci_addr: binding to vfio-pci"
    echo "vfio-pci" > "/sys/bus/pci/devices/$pci_addr/driver_override"
    echo "$pci_addr" > /sys/bus/pci/drivers/vfio-pci/bind
}

unbind_vfio() {
    local pci_addr="$1"
    local original_driver="$2"

    if [ -z "$original_driver" ] || [ "$original_driver" = "vfio-pci" ]; then
        return 0
    fi

    echo "  $pci_addr: restoring to $original_driver"
    echo "$pci_addr" > "/sys/bus/pci/devices/$pci_addr/driver/unbind" 2>/dev/null
    echo "" > "/sys/bus/pci/devices/$pci_addr/driver_override"
    echo "$pci_addr" > "/sys/bus/pci/drivers/$original_driver/bind" 2>/dev/null
}

setup_vfio() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: GPU passthrough requires root. Run with sudo."
        exit 1
    fi

    if ! grep -q 'intel_iommu=on\|amd_iommu=on' /proc/cmdline; then
        echo "WARNING: IOMMU does not appear to be enabled in kernel parameters."
        echo "Add 'intel_iommu=on iommu=pt' to GRUB_CMDLINE_LINUX_DEFAULT and reboot."
    fi

    modprobe vfio-pci

    # Fail fast if userspace still has the host GPU open.
    # This avoids hanging on driver unbind/bind sysfs operations.
    if [ -e "$GPU_NVIDIA_DEV" ]; then
        GPU_BUSY_PIDS="$(fuser "$GPU_NVIDIA_DEV" 2>/dev/null | xargs)"
        if [ -n "$GPU_BUSY_PIDS" ]; then
            echo "ERROR: $GPU_NVIDIA_DEV is in use; refusing to bind GPU to vfio-pci."
            echo "Close these processes first:"
            ps -fp $GPU_BUSY_PIDS
            echo ""
            echo "Tip: run from a TTY (Ctrl+Alt+F3) after logging out of desktop apps."
            exit 1
        fi
    fi

    # Bind every device in the same IOMMU group as the target GPU.
    # QEMU requires all group members to be bound to vfio-pci.
    IOMMU_GROUP_ID="$(basename "$(readlink "/sys/bus/pci/devices/$GPU_PCI/iommu_group" 2>/dev/null)" 2>/dev/null)"
    if [ -z "$IOMMU_GROUP_ID" ]; then
        echo "ERROR: Could not resolve IOMMU group for $GPU_PCI"
        exit 1
    fi
    mapfile -t IOMMU_GROUP_DEVICES < <(ls -1 "/sys/kernel/iommu_groups/$IOMMU_GROUP_ID/devices" 2>/dev/null | sort)
    if [ "${#IOMMU_GROUP_DEVICES[@]}" -eq 0 ]; then
        echo "ERROR: No devices found in IOMMU group $IOMMU_GROUP_ID"
        exit 1
    fi

    echo "Binding IOMMU group $IOMMU_GROUP_ID to vfio-pci:"
    for dev in "${IOMMU_GROUP_DEVICES[@]}"; do
        dev="0000:${dev#0000:}"
        ORIG_GROUP_DRIVERS+=("$(basename "$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null)" 2>/dev/null)")
        bind_vfio "$dev"
    done

    # QEMU will run as $RUN_AS_USER (non-root) for PipeWire access,
    # so temporarily open the VFIO IOMMU group device node to that user.
    # The group node number usually matches the iommu_group id.
    VFIO_GROUP_NODE="/dev/vfio/${IOMMU_GROUP_ID}"
    if [ -n "$IOMMU_GROUP_ID" ] && [ -e "$VFIO_GROUP_NODE" ]; then
        VFIO_GROUP_NODE_ORIG_MODE="$(stat -c %a "$VFIO_GROUP_NODE" 2>/dev/null || true)"
        echo "Temporarily granting access to $VFIO_GROUP_NODE for $RUN_AS_USER"
        chmod a+rw "$VFIO_GROUP_NODE" 2>/dev/null || true
    fi

    echo "VFIO setup complete."
}

teardown_vfio() {
    echo ""
    echo "Restoring GPU drivers..."
    if [ "${#IOMMU_GROUP_DEVICES[@]}" -gt 0 ]; then
        local idx=0
        for dev in "${IOMMU_GROUP_DEVICES[@]}"; do
            dev="0000:${dev#0000:}"
            unbind_vfio "$dev" "${ORIG_GROUP_DRIVERS[$idx]}"
            idx=$((idx + 1))
        done
    else
        unbind_vfio "$GPU_PCI" "${ORIG_GPU_DRIVER:-nvidia}"
    fi
    if [ -n "$VFIO_GROUP_NODE" ] && [ -n "$VFIO_GROUP_NODE_ORIG_MODE" ] && [ -e "$VFIO_GROUP_NODE" ]; then
        chmod "$VFIO_GROUP_NODE_ORIG_MODE" "$VFIO_GROUP_NODE" 2>/dev/null || true
    fi
    echo "GPU drivers restored."
}

# Bind GPU to vfio-pci (and restore on exit)
setup_vfio
trap teardown_vfio EXIT

# Always reset OVMF_VARS from template to prevent boot hangs from UEFI variable corruption
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
if [ -f "$OVMF_VARS_TEMPLATE" ]; then
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_WIN"
elif [ -f "$OVMF/OVMF_VARS.fd" ]; then
    cp "$OVMF/OVMF_VARS.fd" "$OVMF_VARS_WIN"
fi
if [ -f "$OVMF_VARS_WIN" ]; then
    # QEMU will run as the invoking user (not root), so ensure it can write UEFI variables.
    chown "$RUN_AS_UID:$RUN_AS_GID" "$OVMF_VARS_WIN" 2>/dev/null || true
    chmod 600 "$OVMF_VARS_WIN" 2>/dev/null || true
fi
(ls "$WIN11_DISK" >> /dev/null 2>&1 && echo "") || qemu-img create -f qcow2 "$WIN11_DISK" 64G

# Restart swtpm for each run so each QEMU gets a clean CMD_INIT (avoids 0x9 on second launch)
pkill -f "swtpm.*$TPM_SOCKET" 2>/dev/null || true
[ -e "$TPM_SOCKET" ] && rm -f "$TPM_SOCKET"

if [ ! -S "$TPM_SOCKET" ]; then
    mkdir -p "$TPM_STATE_DIR" "$TPM_SOCKET_DIR"
    chown -R "$RUN_AS_UID:$RUN_AS_GID" "$TPM_STATE_DIR" "$TPM_SOCKET_DIR" 2>/dev/null || true
    chmod 755 "$TPM_STATE_DIR" "$TPM_SOCKET_DIR"
    if [ -e "$TPM_SOCKET" ]; then
        rm -f "$TPM_SOCKET"
    fi
    # Run swtpm as the invoking user so it can write to $TPM_STATE_DIR in user's home
    sudo -u "$RUN_AS_USER" env HOME="$RUN_AS_HOME" \
        swtpm socket --tpm2 --tpmstate dir="$TPM_STATE_DIR" --ctrl type=unixio,path="$TPM_SOCKET" --flags not-need-init --daemon
    if [ $? -ne 0 ]; then
        echo "Failed to start swtpm. Try running without sudo or set TPM_DIR to a writable path."
        exit 1
    fi
fi

# Make sure an existing or newly-created swtpm socket is reachable by non-root QEMU.
if [ -d "$TPM_SOCKET_DIR" ]; then
    chown "$RUN_AS_UID:$RUN_AS_GID" "$TPM_SOCKET_DIR" 2>/dev/null || true
    chmod 711 "$TPM_SOCKET_DIR" 2>/dev/null || true
fi
if [ -S "$TPM_SOCKET" ]; then
    chown "$RUN_AS_UID:$RUN_AS_GID" "$TPM_SOCKET" 2>/dev/null || true
    chmod 660 "$TPM_SOCKET" 2>/dev/null || true
fi

# Ensure monitor socket path is writable by the non-root QEMU process.
if [ -e "$MONITOR_SOCKET" ]; then
    rm -f "$MONITOR_SOCKET" 2>/dev/null || true
fi

NETDEV="user,id=net0"
echo "SMB share: \\\\10.0.2.2\\samba -> /home/me (via system Samba)"
INPUTARGS=()
DISKARGS=()
IOTHREADARGS=()
TRACKPAD_USB_PASSTHROUGH="${TRACKPAD_USB_PASSTHROUGH:-0}"
TRACKPAD_USB_VENDORID="${TRACKPAD_USB_VENDORID:-0x05ac}"
TRACKPAD_USB_PRODUCTID="${TRACKPAD_USB_PRODUCTID:-0x0265}"
TRACKPAD_USB_DEVICE_ID="${TRACKPAD_USB_DEVICE_ID:-trackpad0}"
HOSTKBD_GRAB_ALL="${HOSTKBD_GRAB_ALL:-off}"
GPU_DEBUG_DISPLAY="${GPU_DEBUG_DISPLAY:-0}"
DISPLAYARGS=()
if [ "$GPU_DEBUG_DISPLAY" = "1" ]; then
    DISPLAYARGS=(
        -display spice-app
        -device virtio-vga
    )
    echo "Debug display enabled (SPICE window + virtio-vga)."
else
    DISPLAYARGS=(
        -vga none
        -display none
    )
fi

if [ "${EVDEV:-1}" = "1" ]; then
    EVDEV_KBD="${EVDEV_KBD:-/dev/input/by-id/usb-04f3_0103-event-kbd}"
    if [ -n "${EVDEV_MOUSE:-}" ]; then
        EVDEV_MOUSE="$EVDEV_MOUSE"
    elif [ -e "/dev/input/by-id/usb-Logitech_USB_Receiver-if01-event-mouse" ]; then
        EVDEV_MOUSE="/dev/input/by-id/usb-Logitech_USB_Receiver-if01-event-mouse"
    elif [ -e "/dev/input/by-id/usb-Apple_Inc._Magic_Trackpad_2_CC294420060J2XQAQ-if01-event-mouse" ]; then
        EVDEV_MOUSE="/dev/input/by-id/usb-Apple_Inc._Magic_Trackpad_2_CC294420060J2XQAQ-if01-event-mouse"
    elif [ -e "/dev/input/by-id/usb-Apple_Inc._Magic_Trackpad_2_CC294420060J2XQAQ-event-mouse" ]; then
        EVDEV_MOUSE="/dev/input/by-id/usb-Apple_Inc._Magic_Trackpad_2_CC294420060J2XQAQ-event-mouse"
    else
        EVDEV_MOUSE=""
    fi
    EVDEV_MOUSE2="${EVDEV_MOUSE2:-}"
    EVDEV_GRAB_TOGGLE="${EVDEV_GRAB_TOGGLE:-scrolllock}"

    if [ -z "$EVDEV_KBD" ] || { [ -z "$EVDEV_MOUSE" ] && [ "$TRACKPAD_USB_PASSTHROUGH" != "1" ]; }; then
        echo "ERROR: EVDEV=1 requires both EVDEV_KBD and EVDEV_MOUSE."
        echo "Example:"
        echo "  sudo EVDEV=1 EVDEV_KBD=/dev/input/by-id/...-kbd EVDEV_MOUSE=/dev/input/by-id/...-mouse ./gpu.sh"
        exit 1
    fi

    if [ ! -e "$EVDEV_KBD" ] || { [ "$TRACKPAD_USB_PASSTHROUGH" != "1" ] && [ ! -e "$EVDEV_MOUSE" ]; }; then
        echo "ERROR: EVDEV device path not found."
        echo "  EVDEV_KBD=$EVDEV_KBD"
        echo "  EVDEV_MOUSE=$EVDEV_MOUSE"
        echo "Available devices:"
        ls -1 /dev/input/by-id | grep -E 'kbd|mouse'
        exit 1
    fi

    INPUTARGS=(
        -device qemu-xhci,id=xhci
        -object input-linux,id=hostkbd,evdev="$EVDEV_KBD",grab_all="$HOSTKBD_GRAB_ALL",repeat=on,grab-toggle="$EVDEV_GRAB_TOGGLE"
    )
    if [ "$TRACKPAD_USB_PASSTHROUGH" != "1" ]; then
        INPUTARGS+=(-object input-linux,id=hostmouse,evdev="$EVDEV_MOUSE",grab_all=on)
    fi
    if [ "$TRACKPAD_USB_PASSTHROUGH" != "1" ] && [ -n "$EVDEV_MOUSE2" ] && [ -e "$EVDEV_MOUSE2" ]; then
        INPUTARGS+=(-object input-linux,id=hostmouse2,evdev="$EVDEV_MOUSE2",grab_all=on)
    fi
    if [ "$TRACKPAD_USB_PASSTHROUGH" = "1" ]; then
        INPUTARGS+=(
            -device usb-host,id="$TRACKPAD_USB_DEVICE_ID",vendorid="$TRACKPAD_USB_VENDORID",productid="$TRACKPAD_USB_PRODUCTID",bus=xhci.0
        )
    fi
    echo "EVDEV input enabled. Toggle grab with $EVDEV_GRAB_TOGGLE."
    echo "  Keyboard: $EVDEV_KBD"
    if [ "$TRACKPAD_USB_PASSTHROUGH" = "1" ]; then
        echo "  Mouse:    USB passthrough ${TRACKPAD_USB_VENDORID}:${TRACKPAD_USB_PRODUCTID}"
        echo "  Detach back to host (while VM runs):"
        echo "    printf 'device_del $TRACKPAD_USB_DEVICE_ID\n' | socat - UNIX-CONNECT:$MONITOR_SOCKET"
        echo "  Re-attach to VM:"
        echo "    printf 'device_add usb-host,id=$TRACKPAD_USB_DEVICE_ID,vendorid=$TRACKPAD_USB_VENDORID,productid=$TRACKPAD_USB_PRODUCTID,bus=xhci.0\n' | socat - UNIX-CONNECT:$MONITOR_SOCKET"
    else
        echo "  Mouse:    $EVDEV_MOUSE"
    fi
    if [ "$TRACKPAD_USB_PASSTHROUGH" != "1" ] && [ -n "$EVDEV_MOUSE2" ]; then
        echo "  Mouse2:   $EVDEV_MOUSE2"
    fi
else
    INPUTARGS=(
        -device qemu-xhci,id=xhci
        -device usb-kbd,bus=xhci.0
        -device usb-tablet,bus=xhci.0
    )
fi

if [ -n "$BOOT_ISO" ]; then
    if [ ! -f "$BOOT_ISO" ]; then
        echo "Missing boot ISO at $BOOT_ISO"
        exit 1
    fi
    MOREARGS+=(
        -drive id=InstallMedia,if=none,format=raw,file="$BOOT_ISO"
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

if [ "$DISK_IF" = "virtio" ]; then
    IOTHREADARGS=(-object iothread,id=iothread0)
    DISKARGS=(
        -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache="$DISK_CACHE",aio="$DISK_AIO",discard=unmap,detect-zeroes=unmap
        -device virtio-blk-pci,drive=SystemDisk,iothread=iothread0
    )
    echo "Disk mode: virtio-blk (faster)."
else
    DISKARGS=(
        -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache="$DISK_CACHE",aio="$DISK_AIO"
        -device ide-hd,bus=sata.4,drive=SystemDisk
    )
    echo "Disk mode: SATA (compatibility). Set DISK_IF=virtio for better disk performance."
fi

# Audio: prefer emulated HDA via PipeWire (matches win11.sh) for stability.
AUDIOARGS=()
if [ "${AUDIO_BACKEND:-pipewire}" = "none" ]; then
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
    -m "$VM_MEMORY" \
    -monitor "unix:$MONITOR_SOCKET,server,nowait" \
    -machine q35,accel=kvm,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -global ICH9-LPC.disable_s3=1 \
    -smp cores="$VM_CORES",threads="$VM_THREADS",sockets="$VM_SOCKETS" \
    -cpu "$CPU_MODEL" \
    -boot menu=on \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_FILE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_WIN" \
    "${AUDIOARGS[@]}" \
    "${INPUTARGS[@]}" \
    -device ich9-ahci,id=sata \
    -netdev "$NETDEV" \
    -device virtio-net-pci,netdev=net0,id=net0 \
    "${IOTHREADARGS[@]}" \
    "${DISKARGS[@]}" \
    -chardev socket,id=chrtpm,path="$TPM_SOCKET" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    "${DISPLAYARGS[@]}" \
    -device vfio-pci,host="$GPU_PCI",multifunction=on,x-vga="$GPU_X_VGA" \
    "${MOREARGS[@]}"
)

if [ "$MEM_PREALLOC" = "1" ]; then
    args=(-mem-prealloc "${args[@]}")
fi

# VFIO needs locked memory; sudo -u resets limits so prlimit didn't help.
# Run QEMU as root and point it at the user's PipeWire session (srw-rw-rw socket).
PW_RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$RUN_AS_UID}"
echo "Launching QEMU (audio via $PW_RUNTIME)"

if [ -n "$QEMU_CPU_PIN" ]; then
    echo "CPU pinning enabled: $QEMU_CPU_PIN"
    exec env HOME="$RUN_AS_HOME" XDG_RUNTIME_DIR="$PW_RUNTIME" PIPEWIRE_RUNTIME_DIR="$PW_RUNTIME" \
        taskset -c "$QEMU_CPU_PIN" /usr/local/bin/qemu-system-x86_64 "${args[@]}"
fi

exec env HOME="$RUN_AS_HOME" XDG_RUNTIME_DIR="$PW_RUNTIME" PIPEWIRE_RUNTIME_DIR="$PW_RUNTIME" \
    /usr/local/bin/qemu-system-x86_64 "${args[@]}"
