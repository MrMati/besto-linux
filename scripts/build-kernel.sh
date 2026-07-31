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
# than failing, and olddefconfig can drop more afterwards. This used to be
# guarded by a hand-written list of a dozen symbols, which is exactly as good
# as the day someone last updated it -- when it was last audited, 33 of the
# fragments' assignments were being discarded, including all of USB.
#
# So do not maintain a list. Every line in the fragments is a claim about the
# final .config; hold all of them.
fail=0
while read -r sym want; do
	if [ "$want" = n ]; then
		if grep -q "^CONFIG_$sym=" "$kb/.config"; then
			warn "CONFIG_$sym should be off, came out as $(grep -m1 "^CONFIG_$sym=" "$kb/.config")"
			fail=1
		fi
	elif ! grep -qxF "CONFIG_$sym=$want" "$kb/.config"; then
		# Almost always an unmet dependency, a bool written as =m, or a
		# symbol that does not exist in this tree. `make menuconfig` and
		# / to search for the symbol will say which.
		warn "CONFIG_$sym=$want did not take"
		fail=1
	fi
done < <(sed -nE 's/^CONFIG_([A-Za-z0-9_]+)=(.*)$/\1 \2/p; s/^# CONFIG_([A-Za-z0-9_]+) is not set$/\1 n/p' \
	"$BOARD_DIR"/kernel/config/*.config)
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
