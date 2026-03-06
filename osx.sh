#!/usr/bin/env bash

OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
VMDIR=$(realpath $(dirname $0))
OVMF=$VMDIR/firmware
#export QEMU_AUDIO_DRV=pa
#QEMU_AUDIO_DRV=pa

MOREARGS=()

[[ "$HEADLESS" = "1" ]] && {
    MOREARGS+=(-nographic -vnc :0 -k en-us)
}

# USB passthrough - only attach if device is present and USB_PASSTHROUGH=1
# This allows running alongside win11.sh without conflict
if [[ "$USB_PASSTHROUGH" = "1" ]]; then
    MOREARGS+=(-device usb-host,vendorid=0x111d,productid=0x0000)
fi

args=(
    -enable-kvm \
    -m 8G -mem-prealloc\
    -machine q35,accel=kvm \
    -smp cores=8,threads=2,sockets=1 \
    -cpu Haswell-noTSX,vendor=GenuineIntel,kvm=on,+sse3,+sse4.2,+aes,+xsave,+avx,+xsaveopt,+xsavec,+xgetbv1,+avx2,+bmi2,+smep,+bmi1,+fma,+movbe,+invtsc,+avx2 \
    -device isa-applesmc,osk="$OSK" \
    -smbios type=2 \
    -display gtk,gl=es
    -device intel-hda -device hda-output \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$OVMF/OVMF_VARS.fd" \
    -device vmware-svga,vgamem_mb=2048 \
    -usb -device usb-ehci,id=ehci -device usb-kbd,bus=ehci.0 -device usb-tablet,bus=ehci.0 \
    -netdev user,id=net0,smb=/home/me/Public \
    -device vmxnet3,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCore,if=none,format=qcow2,file="$VMDIR/OpenCore.qcow2",cache=writeback,aio=threads \
    -device ide-hd,bus=sata.2,drive=OpenCore \
    -drive id=InstallMedia,format=raw,if=none,file="$VMDIR/BaseSystem.img" \
    -device ide-hd,bus=sata.3,drive=InstallMedia \
    -drive id=SystemDisk,if=none,format=qcow2,file="$HOME/.qemu/macOS.qcow2",cache=writeback,aio=threads \
    -device ide-hd,bus=sata.4,drive=SystemDisk \
    "${MOREARGS[@]}"
)

/usr/local/bin/qemu-system-x86_64 "${args[@]}"
