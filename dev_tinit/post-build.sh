#!/bin/sh
# Buildroot post-build: compile tinit with the target toolchain and install it as /sbin/init.
set -eu
CC=$(ls "$HOST_DIR"/bin/*-buildroot-linux-musl-gcc | head -1)
"$CC" -static -Os -Wall -o "$TARGET_DIR/sbin/init.tmp" "$(dirname "$0")/tinit.c"
rm -f "$TARGET_DIR/sbin/init"
mv "$TARGET_DIR/sbin/init.tmp" "$TARGET_DIR/sbin/init"
