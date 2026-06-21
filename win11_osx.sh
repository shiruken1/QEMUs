#!/usr/bin/env bash

VMDIR=$(realpath "$(dirname "$0")")
OVMF=$VMDIR/firmware
QEMU_BIN="${QEMU_BIN:-$(command -v qemu-system-aarch64)}"
QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
QEMU_SHARE="${QEMU_SHARE:-$QEMU_PREFIX/share/qemu}"

OVMF_CODE_FILE="$OVMF/OVMF_CODE.fd"
OVMF_VARS_WIN="$OVMF/OVMF_VARS_win11.fd"
OVMF_CODE_SYS="$QEMU_SHARE/edk2-aarch64-code.fd"
OVMF_VARS_TEMPLATE="$QEMU_SHARE/edk2-arm-vars.fd"

WIN11_DISK="${WIN11_DISK:-$VMDIR/win11-arm.qcow2}"
BOOT_ISO="${BOOT_ISO:-}"
VIRTIO_ISO="${VIRTIO_ISO:-$VMDIR/virtio-win.iso}"
SMB_SHARE="${SMB_SHARE:-$HOME/Documents/BuildTrue}"
# auto = QEMU built-in smb at 10.0.2.4\qemu
# system = host Samba (samba-osx.sh) at 10.0.2.2\samba — better for VS builds
# 0 = disabled
SMB_ENABLE="${SMB_ENABLE:-system}"
SMB_HOST="${SMB_HOST:-10.0.2.4}"
SMB_SYSTEM_HOST="${SMB_SYSTEM_HOST:-10.0.2.2}"
SMB_SYSTEM_SHARE="${SMB_SYSTEM_SHARE:-samba}"

find_samba_smbd() {
    local candidate
    for candidate in \
        /opt/homebrew/sbin/samba-dot-org-smbd \
        /opt/homebrew/opt/samba/sbin/samba-dot-org-smbd \
        /usr/local/sbin/samba-dot-org-smbd \
        /usr/local/opt/samba/sbin/samba-dot-org-smbd; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

TPM_STATE_DIR="${TPM_STATE_DIR:-$HOME/.local/state/osxvm-tpm-$(id -u)}"
TPM_SOCKET_DIR="${TPM_SOCKET_DIR:-/tmp/osxvm-tpm-$(id -u)}"
TPM_SOCKET="$TPM_SOCKET_DIR/swtpm-sock"

VM_MEMORY="${VM_MEMORY:-8G}"
VM_CORES="${VM_CORES:-4}"
VM_THREADS="${VM_THREADS:-2}"
VM_SOCKETS="${VM_SOCKETS:-2}"
MEM_PREALLOC="${MEM_PREALLOC:-0}"
GPU_EDID="${GPU_EDID:-on}"
GPU_MAX_HOSTMEM="${GPU_MAX_HOSTMEM:-8589934592}"
GPU_RAMFB="${GPU_RAMFB:-0}"
GPU_VIRTIO_GPU="${GPU_VIRTIO_GPU:-1}"
DISPLAY_WIDTH="${DISPLAY_WIDTH:-1920}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-1200}"

if [ ! -x "$QEMU_BIN" ]; then
    echo "qemu-system-aarch64 not found. Install with: brew install qemu"
    exit 1
fi

INSTALL_MODE=0
if [ -n "$BOOT_ISO" ] || [ "${INSTALL:-0}" = "1" ]; then
    INSTALL_MODE=1
fi
if [ "$INSTALL_MODE" = "1" ] && [ -z "$BOOT_ISO" ]; then
    for candidate in \
        "$VMDIR"/Win11_25H2_English_Arm64_v2.iso \
        "$VMDIR"/Win11*Arm64*.iso \
        "$VMDIR"/Win11*.iso; do
        if [ -f "$candidate" ]; then
            BOOT_ISO="$candidate"
            break
        fi
    done
fi

if [ ! -f "$OVMF_CODE_FILE" ]; then
    if [ -f "$OVMF_CODE_SYS" ]; then
        OVMF_CODE_FILE="$OVMF_CODE_SYS"
    else
        echo "UEFI firmware not found in $OVMF or $QEMU_SHARE"
        exit 1
    fi
fi

mkdir -p "$OVMF"
# Install uses -bios; post-install must match or UEFI won't find Windows.
# pflash vars are only used when explicitly requested via FIRMWARE_MODE=pflash.

(ls "$WIN11_DISK" >> /dev/null 2>&1 && echo "") || qemu-img create -f qcow2 "$WIN11_DISK" 64G

if ! command -v swtpm >/dev/null 2>&1; then
    echo "swtpm not found. Install with: brew install swtpm"
    exit 1
fi

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
        echo "Failed to start swtpm. Set TPM_STATE_DIR / TPM_SOCKET_DIR to writable paths."
        exit 1
    fi
fi

NETDEV="user,id=net0"
if [ "$SMB_ENABLE" = "system" ]; then
    if ! find_samba_smbd >/dev/null; then
        echo "SMB system mode requires Samba: brew install samba"
        exit 1
    fi
    if ! pgrep -x samba-dot-org-smbd >/dev/null; then
        echo "WARNING: samba-dot-org-smbd is not running."
        echo "Start it with: $VMDIR/samba-osx.sh start"
    fi
    if [ ! -d "$SMB_SHARE" ]; then
        echo "WARNING: SMB_SHARE directory does not exist: $SMB_SHARE"
    fi
    SMB_SHARE="$(cd "$SMB_SHARE" >/dev/null 2>&1 && pwd || echo "$SMB_SHARE")"
    echo "SMB share (system Samba): \\\\${SMB_SYSTEM_HOST}\\${SMB_SYSTEM_SHARE} -> $SMB_SHARE"
    echo "In Windows use \\\\${SMB_SYSTEM_HOST}\\${SMB_SYSTEM_SHARE} — guest access, no credentials."
    echo "Start Samba on the Mac with: $VMDIR/samba-osx.sh start"
elif [ "$SMB_ENABLE" = "1" ] || { [ "$SMB_ENABLE" = "auto" ] && find_samba_smbd >/dev/null; }; then
    if ! find_samba_smbd >/dev/null; then
        echo "SMB sharing requested but Samba is not installed."
        echo "Install with: brew install samba"
        exit 1
    fi
    if [ ! -d "$SMB_SHARE" ]; then
        echo "WARNING: SMB_SHARE directory does not exist: $SMB_SHARE"
    fi
    SMB_SHARE="$(cd "$SMB_SHARE" 2>/dev/null && pwd || echo "$SMB_SHARE")"
    NETDEV="user,id=net0,smb=$SMB_SHARE"
    echo "SMB share: \\\\${SMB_HOST}\\qemu -> $SMB_SHARE (QEMU built-in)"
    echo "In Windows use \\\\${SMB_HOST}\\qemu — no username/password (guest access)."
else
    echo "SMB share disabled (install Samba with: brew install samba, or set SMB_ENABLE=1)"
fi

MOREARGS=()
DISKARGS=()
FIRMWAREARGS=()
AUDIOARGS=()
USB_AUDIO=0
MEM_ARGS=(-m "$VM_MEMORY")
DISPLAYARGS=(-display cocoa)

if [ "$MEM_PREALLOC" = "1" ]; then
    MEM_ARGS+=(-mem-prealloc)
fi

if [ "$HEADLESS" = "1" ]; then
    DISPLAYARGS=(-nographic -vnc :1 -k en-us)
elif [ "$DISPLAY_MODE" = "gtk" ] || [ "$DISPLAY_MODE" = "spice" ]; then
    echo "Note: $DISPLAY_MODE is unavailable on macOS; using cocoa display."
    DISPLAYARGS=(-display cocoa)
fi

AUDIO_BACKEND="${AUDIO_BACKEND:-coreaudio}"
if [ "$AUDIO_BACKEND" != "none" ]; then
    AUDIOARGS=(-audiodev "$AUDIO_BACKEND",id=audio0,out.frequency=48000)
    USB_AUDIO=1
fi

MOREARGS+=(
    -device qemu-xhci,id=xhci
    -device usb-kbd,bus=xhci.0
    -device usb-tablet,bus=xhci.0
    -object rng-random,id=rng0,filename=/dev/urandom
    -device virtio-rng-pci,rng=rng0
)
if [ "$USB_AUDIO" = "1" ]; then
    MOREARGS+=(-device usb-audio,bus=xhci.0,audiodev=audio0)
fi

if [ "$INSTALL_MODE" = "1" ]; then
    if [ ! -f "$BOOT_ISO" ]; then
        echo "Missing boot ISO at $BOOT_ISO"
        exit 1
    fi
    echo "Install mode: $BOOT_ISO"
    FIRMWAREARGS=(-bios "$OVMF_CODE_FILE")
    MOREARGS+=(
        -device ramfb
        -drive id=InstallMedia,if=none,format=raw,media=cdrom,file="$BOOT_ISO"
        -device usb-storage,bus=xhci.0,drive=InstallMedia,removable=on,bootindex=1
    )
    if [ "${INCLUDE_VIRTIO:-1}" = "1" ]; then
        if [ ! -f "$VIRTIO_ISO" ]; then
            echo "ERROR: virtio-win.iso is required for install (VirtIO disk is invisible without it)."
            echo "Download from: https://virtio-win.github.io/ and place at $VIRTIO_ISO"
            exit 1
        fi
        MOREARGS+=(
            -drive id=VirtioISO,if=none,format=raw,media=cdrom,file="$VIRTIO_ISO"
            -device usb-storage,bus=xhci.0,drive=VirtioISO,removable=on
        )
        echo ""
        echo "=== No disk in the installer? Load the VirtIO storage driver ==="
        echo "  1. On 'Where do you want to install Windows?' click Load driver"
        echo "  2. Click Browse and open the virtio-win USB/CD drive"
        echo "  3. Pick folder: viostor\\w11\\ARM64  (or viostor\\2k25\\ARM64 for 25H2)"
        echo "  4. Install 'Red Hat VirtIO SCSI pass-through controller'"
        echo "  5. The ${WIN11_DISK##*/} drive should appear (default size: 64G)"
        echo ""
        echo "=== No internet during setup? ==="
        echo "  Quick (skip network): Shift+F10, run:  OOBE\\BYPASSNRO"
        echo "  Then choose 'I don't have internet' and continue with a local account."
        echo ""
        echo "  Or enable network: after install, run virtio-win-guest-tools.exe from the"
        echo "  virtio-win drive (or load NetKVM\\w11\\ARM64 in Device Manager)."
        echo ""
    fi
    DISKARGS+=(
        -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache=writeback
        -device virtio-blk-pci,drive=SystemDisk,bootindex=2
    )
else
  FIRMWARE_MODE="${FIRMWARE_MODE:-bios}"
  if [ "$FIRMWARE_MODE" = "pflash" ]; then
      if [ ! -f "$OVMF_VARS_WIN" ]; then
          if [ -f "$OVMF_VARS_TEMPLATE" ]; then
              cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_WIN"
          elif [ -f "$OVMF/OVMF_VARS.fd" ]; then
              cp "$OVMF/OVMF_VARS.fd" "$OVMF_VARS_WIN"
          else
              echo "ERROR: pflash vars template not found; use FIRMWARE_MODE=bios (default)."
              exit 1
          fi
      fi
      FIRMWAREARGS=(
          -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_FILE"
          -drive if=pflash,format=raw,file="$OVMF_VARS_WIN"
      )
  else
      FIRMWAREARGS=(-bios "$OVMF_CODE_FILE")
  fi
  if [ "$GPU_RAMFB" = "1" ]; then
      MOREARGS+=(-device ramfb)
  fi
  if [ "$GPU_VIRTIO_GPU" = "1" ]; then
      MOREARGS+=(-device "virtio-gpu-pci,edid=$GPU_EDID,max_hostmem=$GPU_MAX_HOSTMEM,max_outputs=1,xres=$DISPLAY_WIDTH,yres=$DISPLAY_HEIGHT")
  fi
#   always attach the virtio-win iso
    MOREARGS+=(
        -drive id=VirtioISO,if=none,format=raw,media=cdrom,file="$VIRTIO_ISO"
        -device usb-storage,bus=xhci.0,drive=VirtioISO,removable=on
    )

  DISKARGS+=(
      -drive id=SystemDisk,if=none,format=qcow2,file="$WIN11_DISK",cache=writeback
      -device virtio-blk-pci,drive=SystemDisk,bootindex=1
  )
fi

args=(
    -accel hvf
    "${MEM_ARGS[@]}"
    -machine virt,gic-version=3,highmem=on
    -smp "cores=$VM_CORES,threads=$VM_THREADS,sockets=$VM_SOCKETS"
    -cpu host
    -monitor "unix:/tmp/qemu-win11.sock,server,nowait"
    "${FIRMWAREARGS[@]}"
    "${AUDIOARGS[@]}"
    "${DISPLAYARGS[@]}"
    "${DISKARGS[@]}"
    "${MOREARGS[@]}"
    -netdev "$NETDEV"
    -device virtio-net-pci,netdev=net0,id=net0
    -chardev socket,id=chrtpm,path="$TPM_SOCKET"
    -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis-device,tpmdev=tpm0
)

if [ "$INSTALL_MODE" = "1" ]; then
    echo "Starting Windows 11 ARM64 install (HVF)."
    echo "After install, rerun without INSTALL=1 or BOOT_ISO (plain ./win11_osx.sh)."
    echo "If you land in the UEFI Shell: type exit -> Boot Manager -> pick the USB install entry."
else
    echo "Starting Windows 11 ARM64 VM (HVF)."
    if [ "$GPU_VIRTIO_GPU" = "1" ]; then
        echo ""
        echo "Dynamic resize: install vgpusrv as a Windows service (once), then reboot:"
        echo "  copy virtio-win\\viogpudo\\w11\\ARM64\\vgpusrv.exe -> C:\\Windows\\System32\\"
        echo "  copy virtio-win\\viogpudo\\w11\\ARM64\\viogpuap.exe -> C:\\Windows\\System32\\"
        echo "  Admin CMD: cd C:\\Windows\\System32 && vgpusrv.exe -i"
        echo "  Verify: services.msc -> VioGpu Resolution Service -> Running"
        echo ""
        echo "Boot with: GPU_RAMFB=0 GPU_VIRTIO_GPU=1 ./win11_osx.sh"
        echo "Two monitors in Settings? Device Manager -> Monitors -> disable the extra"
        echo "  'Generic Monitor' (keep 'Generic Monitor (QEMU Monitor)')."
        echo "If resize stops working, re-run: vgpusrv.exe -i  (Admin, in System32)."
        echo "Fixed resolution fallback: ./win11_osx-resolution.sh ${DISPLAY_WIDTH} ${DISPLAY_HEIGHT}"
        echo ""
    fi
    if [ "$GPU_RAMFB" = "1" ] && [ "$GPU_VIRTIO_GPU" = "1" ]; then
        echo "WARNING: dual display (ramfb + virtio-gpu) breaks resize. Use GPU_RAMFB=0."
    elif [ "$GPU_RAMFB" = "1" ]; then
        echo "ramfb only. Press F10 at boot -> Device Manager -> OVMF Platform Configuration for 1024x768."
    fi
fi
exec "$QEMU_BIN" "${args[@]}"
