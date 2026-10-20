#!/bin/sh
# Buildroot post-image: one GPT disk with one FAT partition holding grub (EFI), its config, its
# environment block, the kernel and the initramfs. ltd rewrites the environment block at runtime.
set -eu
HERE=$(dirname "$0")
D="$BINARIES_DIR/efi-part/EFI/BOOT"
cp "$HERE/grub.cfg" "$D/grub.cfg"
# GRUB's environment block: signature, name=value lines, '#' padding to 1024 bytes.
{ printf '# GRUB Environment Block\ncmdline=console=ttyS0 panic=1 quiet\n'; tr '\0' '#' </dev/zero | head -c 1024; } | head -c 1024 >"$D/grubenv"
support/scripts/genimage.sh -c "$HERE/genimage.cfg"
