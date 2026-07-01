#!/usr/bin/env bash

VMDIR=$(realpath "$(dirname "$0")")
OVMF=$VMDIR/firmware
QEMU_BIN="${QEMU_BIN:-$(command -v qemu-system-aarch64)}"
QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
QEMU_SHARE="${QEMU_SHARE:-$QEMU_PREFIX/share/qemu}"

OVMF_CODE_FILE="${OVMF_CODE_FILE:-$OVMF/OVMF_CODE.fd}"
OVMF_VARS_WIN="$OVMF/OVMF_VARS_win11_osx.fd"
OVMF_CODE_SYS="$QEMU_SHARE/edk2-aarch64-code.fd"
OVMF_VARS_TEMPLATE="$QEMU_SHARE/edk2-arm-vars.fd"

# Firmware/display selection.
#   FIRMWARE=system (default): boot with the UEFI firmware that ships with QEMU
#     (edk2-aarch64-code.fd) in pflash mode. The older bundled AAVMF
#     (firmware/OVMF_CODE.fd, the "legacy" path below) renders black on current
#     macOS, so we use the QEMU-shipped firmware instead.
#   Display device is chosen separately with GPU= (see below). NOTE: both ramfb
#     and virtio-gpu render correctly on the HOST with this firmware (verified
#     headless at 1600x1280 under HVF on macOS 26.x). The black "Display output
#     is not active" screen people hit with virtio-gpu is a GUEST-side problem:
#     Windows' viogpudo driver switches the scanout off unless the VioGpu
#     Resolution Service (vgpusrv) is installed (see notes at the bottom). It is
#     NOT a QEMU/macOS rendering bug.
#   FIRMWARE=legacy: original setup (-bios firmware/OVMF_CODE.fd + virtio-gpu).
#     Kept for reference / other hosts; black on this Mac.
FIRMWARE="${FIRMWARE:-system}"

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
MONITOR_SOCK="${MONITOR_SOCK:-/tmp/qemu-win11.sock}"

VM_MEMORY="${VM_MEMORY:-8G}"
VM_CORES="${VM_CORES:-4}"
VM_THREADS="${VM_THREADS:-2}"
VM_SOCKETS="${VM_SOCKETS:-2}"
MEM_PREALLOC="${MEM_PREALLOC:-0}"
GPU_EDID="${GPU_EDID:-on}"
GPU_MAX_HOSTMEM="${GPU_MAX_HOSTMEM:-8589934592}"
GPU_RAMFB="${GPU_RAMFB:-}"
GPU_VIRTIO_GPU="${GPU_VIRTIO_GPU:-}"
DISPLAY_WIDTH="${DISPLAY_WIDTH:-1600}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-1280}"

# Display device convenience switch (overridable by GPU_RAMFB / GPU_VIRTIO_GPU):
#   GPU=ramfb  (default): plain always-on framebuffer. Safe, can't be blanked by
#              the guest, but fixed/low resolution (good for first boot/recovery).
#   GPU=virtio: virtio-gpu, arbitrary resolution (incl. 1600x1280) + dynamic
#              resize. Requires the Windows VioGpu Resolution Service (vgpusrv);
#              without it Windows turns the display off after boot -> recover with
#              RECOVER=1 ./win11_osx.sh, install vgpusrv, then boot GPU=virtio again.
GPU="${GPU:-virtio}"
if [ "$GPU" = "virtio" ]; then
    [ -z "$GPU_RAMFB" ] && GPU_RAMFB=0
    [ -z "$GPU_VIRTIO_GPU" ] && GPU_VIRTIO_GPU=1
elif [ "$GPU" = "ramfb" ]; then
    [ -z "$GPU_RAMFB" ] && GPU_RAMFB=1
    [ -z "$GPU_VIRTIO_GPU" ] && GPU_VIRTIO_GPU=0
fi

# RECOVER=1: boot with a plain always-on ramfb framebuffer instead of virtio-gpu.
# Use this when the normal window is black with "Display output is not active"
# (Windows' GPU driver switched the virtio-gpu output off). ramfb can't be
# blanked by the guest, so you regain a visible screen to fix the display config.
if [ "${RECOVER:-0}" = "1" ]; then
    GPU_RAMFB=1
    GPU_VIRTIO_GPU=0
    echo "RECOVER mode: using ramfb (always-on display). Fix the Windows display"
    echo "config, then boot normally (plain ./win11_osx.sh) to get virtio-gpu back."
fi

if [ ! -x "$QEMU_BIN" ]; then
    echo "qemu-system-aarch64 not found. Install with: brew install qemu"
    exit 1
fi

# Guard: a VM already holding this disk. Launching again would fail on the qcow2
# write lock. This commonly happens when macOS auto-reboots (e.g. an overnight
# update) while the VM is running, then you start it again.
RUNNING_PID="$(pgrep -f "qemu-system-aarch64.*$WIN11_DISK" 2>/dev/null | head -1)"
if [ -n "$RUNNING_PID" ]; then
    echo "A VM using this disk is already running (pid $RUNNING_PID):"
    echo "  $WIN11_DISK"
    echo
    echo "If its window is small/black with 'Display output is not active', the VM"
    echo "is up but the display output is off. Recover it with:"
    echo "  printf 'system_powerdown\\n' | nc -U $MONITOR_SOCK   # graceful shutdown (~60s)"
    echo "  RECOVER=1 $0                                          # restart in ramfb mode"
    echo
    echo "Attach to the QEMU monitor any time with: nc -U $MONITOR_SOCK"
    exit 1
fi

# Remove a stale monitor socket left by a previous unclean shutdown so the new
# instance can bind it.
if [ -S "$MONITOR_SOCK" ]; then
    rm -f "$MONITOR_SOCK"
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

# Apply the working firmware/display combo for normal (non-install) boots.
if [ "$INSTALL_MODE" != "1" ] && [ "$FIRMWARE" = "system" ]; then
    OVMF_CODE_FILE="$OVMF_CODE_SYS"
    FIRMWARE_MODE="${FIRMWARE_MODE:-pflash}"
    [ -z "$GPU_RAMFB" ] && GPU_RAMFB=1
    [ -z "$GPU_VIRTIO_GPU" ] && GPU_VIRTIO_GPU=0
fi
# Fallback defaults if not set by FIRMWARE/RECOVER logic above.
[ -z "$GPU_RAMFB" ] && GPU_RAMFB=0
[ -z "$GPU_VIRTIO_GPU" ] && GPU_VIRTIO_GPU=1

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
    #echo "Start Samba on the Mac with: $VMDIR/samba-osx.sh start"
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

# Forward host 127.0.0.1:$RDP_HOST_PORT -> guest 3389 (Remote Desktop). Lets you
# reach Windows even when the local QEMU display is black ("Display output is not
# active"). Requires Remote Desktop enabled inside Windows. Disable with RDP_FORWARD=0.
# NOTE: Windows 11 *Home* cannot host RDP — only Pro/Enterprise/Education. If RDP
# fails, run winver in the guest; Home users should use the cocoa window + vdagent.
RDP_HOST_PORT="${RDP_HOST_PORT:-13389}"
if [ "${RDP_FORWARD:-1}" = "1" ]; then
    NETDEV="$NETDEV,hostfwd=tcp:127.0.0.1:$RDP_HOST_PORT-:3389"
    echo "RDP: Windows App -> 127.0.0.1:$RDP_HOST_PORT (Pro/Enterprise only; enable in Settings -> Remote Desktop)."
fi

# Bidirectional clipboard (cocoa display <-> guest vdagent). Requires the virtio
# serial driver plus SPICE vdagent in Windows (see startup notes). Disable with
# CLIPBOARD=0. SPICE display is not built on Homebrew macOS QEMU; qemu-vdagent is
# the supported path here (same as Linux win11.sh but without -display spice-app).
CLIPBOARD_ENABLE="${CLIPBOARD:-1}"
CLIPBOARDARGS=()
if [ "$CLIPBOARD_ENABLE" = "1" ]; then
    CLIPBOARDARGS=(
        -device virtio-serial-pci,id=virtio-serial0
        -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on,mouse=off
        -device virtserialport,bus=virtio-serial0.0,chardev=vdagent,name=com.redhat.spice.0
    )
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

# Turn an accidental in-guest Restart into a clean QEMU exit instead of the flaky
# ARM warm-reset (see the boot notes below). You then relaunch for a cold boot.
# Default on; disable with NO_REBOOT=0 (e.g. when letting Windows Update reboot
# itself). Never applied during install — Windows Setup reboots several times.
NO_REBOOT="${NO_REBOOT:-1}"
REBOOTARGS=()
if [ "$NO_REBOOT" = "1" ] && [ "$INSTALL_MODE" != "1" ]; then
    REBOOTARGS=(-no-reboot)
fi

args=(
    -accel hvf
    "${MEM_ARGS[@]}"
    -machine virt,gic-version=3,highmem=on
    -smp "cores=$VM_CORES,threads=$VM_THREADS,sockets=$VM_SOCKETS"
    -cpu host
    -monitor "unix:$MONITOR_SOCK,server,nowait"
    "${FIRMWAREARGS[@]}"
    "${AUDIOARGS[@]}"
    "${DISPLAYARGS[@]}"
    "${DISKARGS[@]}"
    "${MOREARGS[@]}"
    "${CLIPBOARDARGS[@]}"
    -netdev "$NETDEV"
    -device virtio-net-pci,netdev=net0,id=net0
    -chardev socket,id=chrtpm,path="$TPM_SOCKET"
    -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis-device,tpmdev=tpm0
    "${REBOOTARGS[@]}"
)

if [ "$INSTALL_MODE" = "1" ]; then
    echo "Starting Windows 11 ARM64 install (HVF)."
    echo "After install, rerun without INSTALL=1 or BOOT_ISO (plain ./win11_osx.sh)."
    echo "If you land in the UEFI Shell: type exit -> Boot Manager -> pick the USB install entry."
else
    echo "Starting Windows 11 ARM64 VM (HVF)."
    echo ""
    echo "*** Prefer Shut down over Restart inside Windows, then re-run this script. ***"
    echo "    ARM has no hardware reset line, so a reboot is a PSCI SYSTEM_RESET that QEMU"
    echo "    must service in place: re-zeroing vCPU sysregs + GICv3 + pflash state through"
    echo "    HVF. Gaps in that path leave the firmware wedged (hang at the UEFI text screen)."
    echo "    A cold boot (new QEMU process) rebuilds everything from scratch, so shut down +"
    echo "    relaunch is reliable; in-guest Restart is not."
    if [ "$NO_REBOOT" = "1" ]; then
        echo "    NO_REBOOT is on: an in-guest Restart cleanly exits QEMU (no warm-reset hang)."
        echo "    Just re-run this script afterwards. Set NO_REBOOT=0 to let Windows Update reboot."
    fi
    echo ""
    if [ "$GPU_VIRTIO_GPU" = "1" ]; then
        echo ""
        echo "Dynamic resize: install vgpusrv as a Windows service (once), then reboot:"
        echo "  copy D:\\viogpudo\\w11\\ARM64\\vgpusrv.exe -> C:\\Windows\\System32\\"
        echo "  copy D:\\viogpudo\\w11\\ARM64\\viogpuap.exe -> C:\\Windows\\System32\\"
        echo "  Admin CMD: cd C:\\Windows\\System32 && vgpusrv.exe -i"
        echo "  Verify: services.msc -> VioGpu Resolution Service -> Running"
        echo ""
        echo "Boot with: GPU=virtio ./win11_osx.sh   (1600x1280 by default)"
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
    if [ "$CLIPBOARD_ENABLE" = "1" ]; then
        echo ""
        echo "Clipboard sharing (QEMU cocoa window <-> Windows):"
        echo "  In Windows Admin PowerShell, run:"
        echo "    powershell -ExecutionPolicy Bypass -File guest-clipboard-setup.ps1"
        echo "  (copy guest-clipboard-setup.ps1 from this repo, or via SMB share; virtio-win ISO must be mounted)"
        echo "  Then REBOOT. After login, Task Manager should show vdagent.exe (not just vdservice.exe)."
        echo "  Host check (guest driver connected):"
        echo "    printf 'info qtree\\n' | nc -U $MONITOR_SOCK | grep -A3 virtserialport"
        echo "    'guest on' = good; 'guest off' = VirtIO serial driver still missing."
        echo ""
        echo "  RDP clipboard fallback only works on Windows 11 Pro+ with Remote Desktop enabled."
        echo "  Windows 11 Home cannot accept RDP connections (Windows App will hang/time out)."
    fi
fi

"$VMDIR/samba-osx.sh" restart &
exec "$QEMU_BIN" "${args[@]}"
