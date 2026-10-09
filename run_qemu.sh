#!/bin/bash

# Path to your Buildroot output
BR_OUT="$HOME/github/tinit/buildroot/output/images"

# Run QEMU
# We use -initrd to load the cpio archive directly into RAM
qemu-system-x86_64 \
    -kernel $BR_OUT/bzImage \
    -initrd $BR_OUT/rootfs.cpio \
    -nographic \
    -append "console=ttyS0 root=/dev/ram0 nokssmdepy=y panic=1"
