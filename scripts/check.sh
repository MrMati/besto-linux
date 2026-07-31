#!/usr/bin/env bash
#
# Fast sanity pass. Everything here runs in seconds and needs no source
# checkouts, so it is the first CI job and the thing to run before pushing.

. "$(dirname "$0")/lib.sh"

fail=0
check() { if "$@"; then printf '  ok   %s\n' "$*"; else printf '  FAIL %s\n' "$*"; fail=1; fi; }

log "shell syntax"
while IFS= read -r f; do
	bash -n "$f" || { echo "  FAIL $f"; fail=1; }
done < <(find "$TOP/scripts" "$TOP/rootfs/hooks" -name '*.sh' -type f)
for f in "$TOP"/rootfs/overlay/usr/local/sbin/* "$TOP"/npu/rknpu-info; do
	sh -n "$f" || { echo "  FAIL $f"; fail=1; }
done
echo "  ok   $(find "$TOP/scripts" -name '*.sh' | wc -l) build scripts, 3 target scripts"

log "board definition"
for v in BOARD_NAME SOC DRAM_SIZE_MB RKBIN_DDR_BIN UBOOT_DEFCONFIG KERNEL_DEFCONFIG KERNEL_DTS RK_DMA_HEAP_SIZE; do
	if [ -z "${!v:-}" ]; then echo "  FAIL $v is unset"; fail=1; fi
done
echo "  ok   board.env defines the required variables"

log "boot arguments"
# The NPU heap is sized by rk_dma_heap_cma=. A bare cma= is not just ignored:
# with CMA_INACTIVE the reservation collapses to zero and the kernel answers
# with a memblock stack dump. Neither bootargs may carry one.
pico_env="$BOARD_DIR/uboot/tree/board/luckfox/pico/pico-max.env"
if bare_cma="$(grep -nE '^[[:space:]]*(append |[A-Za-z_]*bootargs=)' \
		"$TOP/scripts/build-rootfs.sh" "$pico_env" \
		| grep -E '(^|[[:space:]])cma=')"; then
	echo '  FAIL a bootargs line still passes cma=; the knob is rk_dma_heap_cma='
	echo "$bare_cma" | sed 's/^/       /'; fail=1
else
	echo '  ok   no bootargs pass the generic cma='
fi
# The two heap sizes are written out in two places by two different toolchains,
# so nothing but this check keeps them together.
ubi_heap="$(sed -nE 's/^ubi_bootargs=.*[[:space:]]rk_dma_heap_cma=([^[:space:]]+).*$/\1/p' "$pico_env")"
if [ "$ubi_heap" != "$RK_DMA_HEAP_SIZE" ]; then
	echo "  FAIL ubi_bootargs asks for rk_dma_heap_cma=${ubi_heap:-<nothing>}, board.env says $RK_DMA_HEAP_SIZE"; fail=1
else
	echo "  ok   the NPU heap size agrees between board.env and ubi_bootargs"
fi
# Handing the card over rw skips systemd-fsck-root.service for ever, because
# its ConditionPathIsReadWrite=!/ is the only thing that ever schedules a check.
if grep -qE '^[[:space:]]*append root=@@ROOT@@ rootwait ro ' "$TOP/scripts/build-rootfs.sh"; then
	echo '  ok   the SD card is handed over read-only, so root gets fsck-ed'
else
	echo '  FAIL extlinux.conf does not hand the root filesystem over read-only'; fail=1
fi

log "u-boot overlay"
ubt="$BOARD_DIR/uboot/tree"
dtb_name="$(sed -n 's/^CONFIG_DEFAULT_DEVICE_TREE="\(.*\)"$/\1/p' "$ubt/configs/$UBOOT_DEFCONFIG")"
check test -f "$ubt/arch/arm/dts/$dtb_name.dts"
check test -f "$ubt/arch/arm/dts/$dtb_name-u-boot.dtsi"
env_name="$(sed -n 's/^CONFIG_ENV_SOURCE_FILE="\(.*\)"$/\1/p' "$ubt/configs/$UBOOT_DEFCONFIG")"
check test -f "$ubt/board/luckfox/pico/$env_name.env"
dram="$(sed -n 's/^CONFIG_LUCKFOX_PICO_DRAM_SIZE_MB=//p' "$ubt/configs/$UBOOT_DEFCONFIG")"
if [ "$dram" != "$DRAM_SIZE_MB" ]; then
	echo "  FAIL u-boot says ${dram}MB of DRAM, board.env says ${DRAM_SIZE_MB}MB"; fail=1
else
	echo "  ok   DRAM size agrees between board.env and the defconfig"
fi
# Where mk-image.sh puts u-boot.img on the card and where the SPL reads it from
# are two independent numbers, and the Rockchip default for the second one
# (0x4000, 8 MiB) is where our root partition starts.
sector="$(sed -n 's/^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=//p' "$ubt/configs/$UBOOT_DEFCONFIG")"
if [ "$(( sector / 2 ))" != "$SD_UBOOT_OFFSET_KIB" ] 2>/dev/null; then
	echo "  FAIL SPL reads u-boot from sector $sector ($(( sector / 2 )) KiB), the image writes it at ${SD_UBOOT_OFFSET_KIB} KiB"; fail=1
else
	echo "  ok   the SD u-boot offset agrees between board.env and the defconfig"
fi

log "source patches"
# A patch nobody applies is worse than no patch: it reads like the bug is
# fixed. Every patches directory has to be consumed by its build script, and
# every patch has to be a diff git can parse -- a mangled hunk header only
# turns up an hour into a build otherwise.
shopt -s nullglob
npatch=0; bad=0
for d in "$BOARD_DIR"/*/patches; do
	comp="$(basename "$(dirname "$d")")"
	script="$TOP/scripts/build-$comp.sh"
	if ! grep -q "$comp/patches/\*.patch" "$script" 2>/dev/null; then
		echo "  FAIL $comp/patches exists but build-$comp.sh never applies it"; bad=1
	fi
	for p in "$d"/*.patch; do
		npatch=$((npatch + 1))
		if ! git apply --numstat "$p" >/dev/null 2>&1; then
			echo "  FAIL $comp/patches/$(basename "$p") is not a diff git can apply"; bad=1
		fi
		grep -q '^Subject: ' "$p" || { echo "  FAIL $comp/patches/$(basename "$p") has no Subject:"; bad=1; }
	done
done
shopt -u nullglob
if [ "$bad" -eq 0 ]; then
	echo "  ok   $npatch patches, all parseable and applied by their build script"
else
	fail=1
fi

log "kernel devicetree"
check test -f "$BOARD_DIR/kernel/dts/$KERNEL_DTS.dts"
# The whole point of the board is the NPU; a DTS that forgets to enable it
# builds and boots and silently has no /dev/rknpu.
npu_node="$(sed -n '/^&npu {/,/^};/p' "$BOARD_DIR/kernel/dts/$KERNEL_DTS.dts")"
if printf '%s' "$npu_node" | grep -q 'status = "okay"'; then
	echo '  ok   &npu is enabled'
else
	echo '  FAIL &npu is not enabled in the devicetree'; fail=1
fi
# rv1106.dtsi leaves aclk_rknn on the 420 MHz PVTPLL. 500 MHz is the rated
# clock and the only faster parent the ACLK_NPU_ROOT mux has.
if printf '%s' "$npu_node" | grep -q 'assigned-clock-rates = <500000000>'; then
	echo '  ok   the NPU is clocked at 500 MHz'
else
	echo '  FAIL &npu does not pin aclk_rknn to 500 MHz'; fail=1
fi
# The TRNG is the board's only entropy source. rv1106.dtsi ships it disabled,
# and with it disabled systemd-random-seed blocks on getrandom(2) until its
# 10 minute timeout on every single boot, dragging the rest of the boot with
# it. The driver is built in, so the devicetree is the only thing keeping it
# off.
rng_node="$(sed -n '/^&rng {/,/^};/p' "$BOARD_DIR/kernel/dts/$KERNEL_DTS.dts")"
if printf '%s' "$rng_node" | grep -q 'status = "okay"'; then
	echo '  ok   &rng is enabled, the CRNG has a hardware seed'
else
	echo '  FAIL &rng is not enabled, userspace will stall on getrandom(2)'; fail=1
fi

log "kernel config fragments"
# Match only real directives, not prose that happens to name a symbol: a
# comment beginning "# CONFIG_FOO ..." is not the same thing as the kconfig
# "# CONFIG_FOO is not set" that switches FOO off.
frag_syms() {
	sed -nE 's/^CONFIG_([A-Z0-9_]+)=.*$/\1/p; s/^# CONFIG_([A-Z0-9_]+) is not set$/\1/p' "$@"
}
frags=("$BOARD_DIR"/kernel/config/*.config)
dupes="$(frag_syms "${frags[@]}" | sort | uniq -d)"
if [ -n "$dupes" ]; then
	echo "  FAIL a symbol is set in more than one place; the last fragment wins:"
	echo "$dupes" | sed 's/^/       CONFIG_/'; fail=1
else
	echo "  ok   $(frag_syms "${frags[@]}" | wc -l) symbols across ${#frags[@]} fragments, no duplicates"
fi
# DRM would flip the RKNPU memory-manager choice away from the dma-heap path
# that librknnmrt expects, and the RV1106 has no display engine anyway.
if grep -qE '^CONFIG_DRM=y' "${frags[@]}"; then
	echo '  FAIL fragment enables DRM, which switches RKNPU to the DRM GEM backend'; fail=1
else
	echo '  ok   DRM stays off, RKNPU keeps the dma-heap backend'
fi

log "rootfs overlay"
# /usr/lib/tmpfiles.d/debian.conf carries "L+ /etc/default/locale - - - -
# ../locale.conf", and L+ deletes whatever is in the way. A real file there
# survives until systemd-tmpfiles-setup.service runs and no longer, so the
# locale has to be written to /etc/locale.conf. build-rootfs.sh holds this
# against the tmpfiles.d of the rootfs it just built; this is the same claim
# without a build, because finding out an hour in is not the same as finding
# out now.
ovl="$TOP/rootfs/overlay"
if [ "$(readlink "$ovl/etc/default/locale")" = "../locale.conf" ]; then
	echo '  ok   /etc/default/locale is the symlink tmpfiles.d insists on'
else
	echo '  FAIL /etc/default/locale must be a symlink to ../locale.conf, or tmpfiles will delete it'; fail=1
fi
if grep -q '^LANG=' "$ovl/etc/locale.conf" 2>/dev/null; then
	echo '  ok   /etc/locale.conf sets LANG'
else
	echo '  FAIL /etc/locale.conf does not set LANG; pam_env will log on every login'; fail=1
fi

log "npu glibc shim"
if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
	tmp="$(mktemp -d)"
	if "${CROSS_COMPILE}gcc" -O2 -fPIC -Wall -Werror -c "$TOP/npu/uclibc-ctype-compat.c" -o "$tmp/o.o" 2>"$tmp/err"; then
		echo '  ok   uclibc-ctype-compat.c compiles clean'
	else
		echo '  FAIL uclibc-ctype-compat.c'; sed 's/^/       /' "$tmp/err"; fail=1
	fi
	rm -rf "$tmp"
else
	warn "no ${CROSS_COMPILE}gcc, skipping the shim compile"
fi

[ "$fail" -eq 0 ] || die "checks failed"
log "all checks passed"
