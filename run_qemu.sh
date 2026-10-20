#!/bin/sh
# Boot the tinit disk image under QEMU (EFI firmware from the host's OVMF) on the serial console.
# Ctrl-a x to quit. DISK overrides the image, since ltd writes grub's environment block on it;
# NETDEV overrides eth0's backend and MAC its address (the smoke test links two VMs with
# socket,listen / connect; QEMU gives every first NIC the same MAC, and a bridge drops frames
# whose source is its own address).
IMG="$(dirname "$0")/buildroot/output/images"
exec qemu-system-x86_64 -M pc -m 512 -nographic -no-reboot -bios /usr/share/ovmf/OVMF.fd \
    -drive file="${DISK:-$IMG/disk.img}",format=raw,if=virtio \
    -netdev "${NETDEV:-user}",id=n0 -device "virtio-net-pci,netdev=n0${MAC:+,mac=$MAC}"
