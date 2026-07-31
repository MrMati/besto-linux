#!/usr/bin/env bash
#
# Build the Rockchip 6.6 kernel for the board.
#
# Outputs, all in $OUT:
#   zImage                       the kernel
#   <board dts>.dtb              the devicetree
#   modules/                     staged modules tree (lib/modules/<ver>)
#   linux-headers/               kbuild tree for out-of-tree module builds

. "$(dirname "$0")/lib.sh"

need git make "${CROSS_COMPILE}gcc" bc flex bison openssl

k="$(fetch linux "$KERNEL_URL" "$KERNEL_REF" "$KERNEL_BRANCH")"
kb="$OUT/linux"
mkdir -p "$kb"

kmake() { make -C "$k" O="$kb" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" "$@"; }

# --- board devicetree -------------------------------------------------------
#
# Rockchip's tree has no Luckfox board at all, so the DTS lives here and is
# dropped in before configuring. Registering it in the Makefile keeps the
# normal `make dtbs` target working.
dtsdir="$k/arch/arm/boot/dts/rockchip"
cp -f "$BOARD_DIR"/kernel/dts/*.dts "$dtsdir/"
if ! grep -q "$KERNEL_DTS.dtb" "$dtsdir/Makefile"; then
	log "registering $KERNEL_DTS.dtb"
	printf 'dtb-$(CONFIG_ARCH_ROCKCHIP) += %s.dtb\n' "$KERNEL_DTS" >> "$dtsdir/Makefile"
fi

# --- configure --------------------------------------------------------------

log "configuring kernel ($KERNEL_DEFCONFIG + glibc-distro fragment)"
kmake "$KERNEL_DEFCONFIG" >/dev/null

ARCH=arm "$k/scripts/kconfig/merge_config.sh" -m -O "$kb" \
	"$kb/.config" "$BOARD_DIR"/kernel/config/*.config >/dev/null
kmake olddefconfig >/dev/null

# merge_config.sh is advisory: it warns about symbols that did not take rather
# than failing. For a config this opinionated that is not good enough, so check
# the ones that would silently produce an unbootable or NPU-less kernel.
required=(
	CONFIG_ROCKCHIP_RKNPU=y
	CONFIG_ROCKCHIP_RKNPU_DMA_HEAP=y
	CONFIG_DMABUF_HEAPS_ROCKCHIP_CMA_HEAP=y
	CONFIG_CGROUPS=y
	CONFIG_DEVTMPFS_MOUNT=y
	CONFIG_EXT4_FS=y
	CONFIG_ZRAM=y
	CONFIG_SERIAL_8250_CONSOLE=y
	CONFIG_MMC_DW_ROCKCHIP=y
	CONFIG_DWMAC_ROCKCHIP=y
	CONFIG_REGULATOR_PWM=y
	CONFIG_UBIFS_FS=y
)
fail=0
for kv in "${required[@]}"; do
	grep -qx "$kv" "$kb/.config" || { warn "kernel config lost $kv"; fail=1; }
done
grep -qx '# CONFIG_FIQ_DEBUGGER is not set' "$kb/.config" || \
	{ warn "FIQ debugger is still enabled; the console will be ttyFIQ0"; fail=1; }
[ "$fail" -eq 0 ] || die "kernel configuration did not come out as intended"

# --- build ------------------------------------------------------------------

log "building kernel"
kmake -j"$JOBS" "$KERNEL_IMAGE" dtbs modules

kver="$(cat "$kb/include/config/kernel.release")"
log "built $kver"

rm -rf "$OUT/modules"
kmake INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 modules_install >/dev/null
# These are absolute paths into the build tree and are meaningless on target.
rm -f "$OUT/modules/lib/modules/$kver/build" "$OUT/modules/lib/modules/$kver/source"

cp -f "$kb/arch/arm/boot/$KERNEL_IMAGE" "$OUT/$KERNEL_IMAGE"
cp -f "$kb/arch/arm/boot/dts/rockchip/$KERNEL_DTS.dtb" "$OUT/$KERNEL_DTS.dtb"
echo "$kver" > "$OUT/kernel.release"

# Enough of the tree to build out-of-tree modules against, which is what you
# want on a board where you will eventually rebuild something.
log "staging kernel headers"
rm -rf "$OUT/linux-headers"
mkdir -p "$OUT/linux-headers"
( cd "$k" && find . -path ./.git -prune -o \
	\( -name Makefile\* -o -name Kconfig\* -o -name '*.sh' -o -name '*.pl' \
	   -o -path './include/*' -o -path './scripts/*' -o -path './arch/arm/include/*' \) \
	-type f -print | tar -cf - -T - ) | tar -C "$OUT/linux-headers" -xf -
( cd "$kb" && tar -cf - .config Module.symvers include scripts 2>/dev/null ) | \
	tar -C "$OUT/linux-headers" -xf - 2>/dev/null || true

log "kernel artifacts:"
ls -la "$OUT/$KERNEL_IMAGE" "$OUT/$KERNEL_DTS.dtb"
