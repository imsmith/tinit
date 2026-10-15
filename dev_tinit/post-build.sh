#!/bin/sh
# Buildroot post-build: install tinit as /sbin/init, precompiled Elixir, and the sysbeam harness.
set -eu
HERE=$(dirname "$0")
CC=$(ls "$HOST_DIR"/bin/*-buildroot-linux-musl-gcc | head -1)
"$CC" -static -Os -Wall -o "$TARGET_DIR/sbin/init.tmp" "$HERE/tinit.c"
rm -f "$TARGET_DIR/sbin/init"
mv "$TARGET_DIR/sbin/init.tmp" "$TARGET_DIR/sbin/init"

# Elixir precompiled for the OTP major that Buildroot's erlang package ships (26).
# Used on the host side only, to build the sysbeam release against Buildroot's host OTP.
ELIXIR_VER=1.19.6
ELIXIR_SHA=55fac8da30e7e9ee87251a6db68ae881e6006b4c192c6081b23c51c97efd187a
DL="$BASE_DIR/../dl/elixir"
ZIP="$DL/elixir-$ELIXIR_VER-otp-26.zip"
if [ ! -f "$ZIP" ]; then
	mkdir -p "$DL"
	wget -q -O "$ZIP" "https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR_VER/elixir-otp-26.zip"
fi
echo "$ELIXIR_SHA  $ZIP" | sha256sum -c - >/dev/null
if [ ! -x "$HOST_DIR/elixir/bin/mix" ]; then
	rm -rf "$HOST_DIR/elixir"
	mkdir -p "$HOST_DIR/elixir"
	unzip -q "$ZIP" 'bin/*' 'lib/*' -d "$HOST_DIR/elixir"
fi

# sysbeam release: BEAM bytecode is portable, ERTS comes from the target's erlang package.
rm -rf "$TARGET_DIR/usr/lib/sysbeam" "$TARGET_DIR/usr/lib/elixir"
(cd "$HERE/../sysbeam" && \
	PATH="$HOST_DIR/bin:$HOST_DIR/elixir/bin:$PATH" MIX_ENV=prod MIX_HOME="$BUILD_DIR/mix-home" \
	mix release --overwrite --quiet --path "$TARGET_DIR/usr/lib/sysbeam")
