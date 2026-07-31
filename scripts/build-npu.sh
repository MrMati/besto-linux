#!/usr/bin/env bash
#
# Assemble the NPU userspace.
#
# Rockchip ships the RV1106 runtime (librknnmrt) as a uClibc build only: an .so
# linked against uClibc, plus a static .a. On a glibc rootfs the .so is
# unloadable and the .a leaves two uClibc-private ctype tables undefined, which
# is why every glibc RKNN project on this SoC ends up statically linking the
# archive and carrying its own compat shim.
#
# We do it once, properly, and ship a real shared library instead:
#
#   librknnmrt.so.2   glibc-native, no text relocations, full RKNN API exported
#   librknnmrt.a      the untouched vendor archive, for static links
#   rknn_api.h etc.   the vendor headers
#   librknnmrt.pc     so `pkg-config --libs rknnmrt` just works
#
# Outputs into $OUT/npu-staging, laid out as a rootfs overlay.

. "$(dirname "$0")/lib.sh"

need curl "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}nm" "${CROSS_COMPILE}readelf"

# rknn-toolkit2 is several gigabytes of example models around the four files we
# actually need, so pull them straight out of the tag instead of cloning.
raw="${RKNPU2_URL%.git}"
raw="${raw/https:\/\/github.com/https:\/\/raw.githubusercontent.com}/$RKNPU2_REF/rknpu2/runtime/Linux/librknn_api"
api="$OUT/rknpu2"
rm -rf "$api"
fetch_file "$raw/armhf-uclibc/librknnmrt.a" "$api/armhf-uclibc/librknnmrt.a"
for h in rknn_api.h rknn_custom_op.h rknn_matmul_api.h; do
	fetch_file "$raw/include/$h" "$api/include/$h"
done

stage="$OUT/npu-staging"
libdir="$stage/usr/lib/arm-linux-gnueabihf"
rm -rf "$stage"
mkdir -p "$libdir/pkgconfig" "$stage/usr/include/rknn" "$stage/usr/lib/udev/rules.d"

work="$OUT/npu-build"
rm -rf "$work"; mkdir -p "$work"

log "building glibc librknnmrt.so.2 from the vendor archive"
"${CROSS_COMPILE}gcc" -O2 -fPIC -Wall -c "$TOP/npu/uclibc-ctype-compat.c" \
	-o "$work/uclibc-ctype-compat.o"
"${CROSS_COMPILE}gcc" -shared -Wl,-soname,librknnmrt.so.2 \
	-o "$work/librknnmrt.so.2" \
	"$work/uclibc-ctype-compat.o" \
	-Wl,--whole-archive "$api/armhf-uclibc/librknnmrt.a" -Wl,--no-whole-archive \
	-lm

# A shared object with text relocations, or one still importing uClibc
# internals, would fail at dlopen time on the board rather than here. Catch it
# now instead of on the device.
if "${CROSS_COMPILE}readelf" -d "$work/librknnmrt.so.2" | grep -q TEXTREL; then
	die "librknnmrt.so.2 has text relocations"
fi
if "${CROSS_COMPILE}nm" -D --undefined-only "$work/librknnmrt.so.2" | grep -qE '__ctype_(b|tolower)$'; then
	die "librknnmrt.so.2 still imports uClibc ctype tables"
fi
for sym in rknn_init rknn_run rknn_query rknn_outputs_get rknn_destroy; do
	"${CROSS_COMPILE}nm" -D --defined-only "$work/librknnmrt.so.2" | grep -q " T $sym\$" \
		|| die "librknnmrt.so.2 does not export $sym"
done
log "librknnmrt.so.2 verified"

install -m 0755 "$work/librknnmrt.so.2" "$libdir/librknnmrt.so.2"
ln -sf librknnmrt.so.2 "$libdir/librknnmrt.so"
install -m 0644 "$api/armhf-uclibc/librknnmrt.a" "$libdir/librknnmrt.a"
install -m 0644 "$api/include"/*.h "$stage/usr/include/rknn/"

cat > "$libdir/pkgconfig/librknnmrt.pc" <<-EOF
	prefix=/usr
	libdir=\${prefix}/lib/arm-linux-gnueabihf
	includedir=\${prefix}/include/rknn

	Name: librknnmrt
	Description: Rockchip RKNPU2 micro runtime for RV1103/RV1106 (glibc build)
	Version: ${RKNPU2_REF#v}
	Libs: -L\${libdir} -lrknnmrt
	Cflags: -I\${includedir}
EOF

# /dev/rknpu is created by the in-kernel driver with root-only permissions.
# Put it in the "render" group so an unprivileged user can run inference, the
# same way DRM render nodes work everywhere else.
cat > "$stage/usr/lib/udev/rules.d/60-rknpu.rules" <<-'EOF'
	KERNEL=="rknpu", GROUP="render", MODE="0660"
EOF

mkdir -p "$stage/usr/bin"
install -m 0755 "$TOP/npu/rknpu-info" "$stage/usr/bin/rknpu-info"

echo "${RKNPU2_REF#v}" > "$stage/usr/lib/arm-linux-gnueabihf/.rknnmrt-version"

log "npu staging tree:"
find "$stage" -type f -o -type l | sed "s|$stage||" | sort
