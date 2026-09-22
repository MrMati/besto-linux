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
for f in "$TOP"/rootfs/overlay/usr/local/sbin/*; do
	sh -n "$f" || { echo "  FAIL $f"; fail=1; }
done
echo "  ok   $(find "$TOP/scripts" -name '*.sh' | wc -l) build scripts, 2 target scripts"

log "board definition"
for v in BOARD_NAME SOC DRAM_SIZE_MB RKBIN_DDR_BIN RKBIN_LOADER_INI UBOOT_DEFCONFIG KERNEL_DEFCONFIG KERNEL_DTS; do
	if [ -z "${!v:-}" ]; then echo "  FAIL $v is unset"; fail=1; fi
done
echo "  ok   board.env defines the required variables"

log "boot arguments"
env_name="$(sed -n 's/^CONFIG_ENV_SOURCE_FILE="\(.*\)"$/\1/p' "$BOARD_DIR/uboot/tree/configs/$UBOOT_DEFCONFIG")"
pico_env="$BOARD_DIR/uboot/tree/board/luckfox/pico/$env_name.env"
if grep -q '^ubi_bootargs=.*root=ubi0:rootfs.*rootfstype=ubifs' "$pico_env"; then
	echo '  ok   U-Boot has a UBIFS fallback for the NAND-root release image'
else
	echo '  FAIL U-Boot has no UBIFS NAND-root fallback'; fail=1
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

if grep -q 'CONFIG_SPL_OPTEE_IMAGE=y' "$ubt/configs/$UBOOT_DEFCONFIG" ||
   grep -Eqi 'op-tee|optee' "$TOP/Makefile" "$TOP"/scripts/build-*.sh ||
   grep -R -Eqi --include='*.env' --include='*.config' --include='*.dts*' \
		'op-tee|optee' "$BOARD_DIR"; then
	echo '  FAIL OP-TEE is still referenced by the board build'; fail=1
else
	echo '  ok   boot chain and board configuration contain no OP-TEE'
fi

log "source patches"
# Ensure every patch gets applied
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


log "kernel config fragments"
# Match only real directives, not prose that happens to name a symbol: a
# comment beginning "# CONFIG_FOO ..." is not the same thing as the kconfig
# "# CONFIG_FOO is not set" that switches FOO off.
frag_syms() {
	sed -nE 's/^CONFIG_([A-Z0-9_]+)=.*$/\1/p; s/^# CONFIG_([A-Z0-9_]+) is not set$/\1/p' "$@"
}
config_dir="${KERNEL_CONFIG_DIR:-$BOARD_DIR/kernel/config}"
frags=("$config_dir"/*.config)
dupes="$(frag_syms "${frags[@]}" | sort | uniq -d)"
if [ -n "$dupes" ]; then
	echo "  FAIL a symbol is set in more than one place; the last fragment wins:"
	echo "$dupes" | sed 's/^/       CONFIG_/'; fail=1
else
	echo "  ok   $(frag_syms "${frags[@]}" | wc -l) symbols across ${#frags[@]} fragments, no duplicates"
fi
if grep -q '^# CONFIG_ROCKCHIP_RKNPU is not set$' "${frags[@]}"; then
	echo '  ok   accelerator driver is explicitly disabled'
else
	echo '  FAIL kernel fragment does not disable the accelerator driver'; fail=1
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

log "USB RNDIS access"
if grep -q 'functions/rndis.usb0' "$ovl/usr/local/sbin/luckfox-usb-gadget" &&
   grep -q '^CONFIG_USB_CONFIGFS_RNDIS=y$' "${frags[@]}" &&
   grep -q 'enable_unit ssh.service' "$TOP/rootfs/hooks/customize.sh"; then
	echo '  ok   RNDIS gadget receives an address and SSH is enabled'
else
	echo '  FAIL RNDIS and SSH are not both configured'; fail=1
fi

if grep -q '^LABEL=LUCKFOX-DATA /mnt/sdcard' "$ovl/etc/fstab"; then
	echo '  ok   NAND-root release mounts labelled FAT32 user storage'
else
	echo '  FAIL FAT32 user-storage mount is missing'; fail=1
fi

[ "$fail" -eq 0 ] || die "checks failed"
log "all checks passed"
