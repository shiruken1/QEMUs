#!/usr/bin/env bash
#
# Optimized macOS VM launcher
# Changes from basic.sh:
#   - NVMe storage instead of IDE (native macOS support, much faster)
#   - Drive caching and I/O threading enabled
#   - Fixed SMP configuration (threads=2 instead of 4)
#   - CPU host passthrough for better performance
#   - Memory preallocation for reduced latency
#   - Optional: hugepages support (uncomment if configured on host)
#

OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
VMDIR=$(realpath $(dirname $0))
OVMF=$VMDIR/firmware

MOREARGS=()

# Display: GTK with optional OpenGL (GTK_GL=1 to enable; gl=on can cause black screen on some setups)
[[ "$HEADLESS" != "1" ]] && {
    if [[ "$GTK_GL" = "1" ]]; then
        MOREARGS+=(-display gtk,gl=es)
    else
        MOREARGS+=(-display gtk)
    fi
}

[[ "$HEADLESS" = "1" ]] && {
    MOREARGS+=(-nographic -vnc :0 -k en-us)
}

# USB passthrough - only if USB_PASSTHROUGH=1 and QEMU built with libusb
[[ "$USB_PASSTHROUGH" = "1" ]] && {
    MOREARGS+=(-device usb-host,vendorid=0x111d,productid=0x0000)
}

# Memory configuration
# -mem-prealloc can take several minutes with large RAM - disabled by default
# For hugepages support (faster prealloc), uncomment and configure:
#   sudo sysctl -w vm.nr_hugepages=12288  (for 24GB with 2MB pages)
# MEM_ARGS=(-m 16G -mem-prealloc -mem-path /dev/hugepages)
# MEM_ARGS=(-m 16G -mem-prealloc)  # Uncomment for prealloc without hugepages
MEM_ARGS=(-m 16G)

args=(
    -enable-kvm
    "${MEM_ARGS[@]}"
    -machine q35,accel=kvm
    # Fixed SMP: threads should typically be 1 or 2, not 4
    -smp cores=8,threads=2,sockets=1
    # CPU host passthrough - better performance than emulated Haswell
    # If you have boot issues, fall back to the original Haswell-noTSX line
    -cpu host,kvm=on,vendor=GenuineIntel,+invtsc,+aes,+xsave,+avx,+avx2
    -device isa-applesmc,osk="$OSK"
    -smbios type=2
    -device intel-hda -device hda-output
    -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE.fd"
    -drive if=pflash,format=raw,file="$OVMF/OVMF_VARS.fd"
    # Graphics: vmware-svga has native macOS support; QXL often gives black screen
    -device vmware-svga,vgamem_mb=1024
    # USB: keeping EHCI for compatibility, XHCI (USB 3.0) is faster but test first
    -usb -device usb-ehci,id=ehci -device usb-kbd,bus=ehci.0 -device usb-tablet,bus=ehci.0
    # Network: vmxnet3 has native macOS support
    -netdev user,id=net0,smb=/home/me/Public
    -device vmxnet3,netdev=net0,id=net0,mac=52:54:00:c9:18:27
    # Storage: Keep OpenCore and InstallMedia on SATA for boot compatibility
    # Only the main system disk uses NVMe for performance
    -device ich9-ahci,id=sata
    -drive id=OpenCore,if=none,format=qcow2,file="$VMDIR/OpenCore.qcow2",cache=writeback,aio=threads
    -device ide-hd,bus=sata.0,drive=OpenCore,bootindex=1
    -drive id=InstallMedia,if=none,format=raw,file="$VMDIR/BaseSystem.img"
    -device ide-hd,bus=sata.1,drive=InstallMedia
    # Main system disk on NVMe for better I/O performance
    -drive id=SystemDisk,if=none,format=qcow2,file="$HOME/.qemu/macOS.qcow2",cache=writeback,aio=threads
    -device nvme,drive=SystemDisk,serial=systemdisk
    "${MOREARGS[@]}"
)

/usr/local/bin/qemu-system-x86_64 "${args[@]}"
