#!/bin/sh
# Boot the tinit initramfs under QEMU on the serial console. Ctrl-a x to quit.
IMG="$(dirname "$0")/buildroot/output/images"
exec qemu-system-x86_64 -M pc -m 512 -nographic -no-reboot \
    -kernel "$IMG/bzImage" -initrd "$IMG/rootfs.cpio.gz" \
    -append "console=ttyS0 panic=1 quiet"
