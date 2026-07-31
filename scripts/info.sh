#!/usr/bin/env bash
# Print what this tree is pinned to and what has been built so far.

. "$(dirname "$0")/lib.sh"

printf '%-14s %s\n' board   "$BOARD_DESC"
printf '%-14s %s\n' soc     "$SOC (${DRAM_SIZE_MB}MB DDR3L)"
echo
printf '%-14s %s\n' u-boot  "$UBOOT_URL"
printf '%-14s %s\n' ''      "@ $UBOOT_REF"
printf '%-14s %s\n' kernel  "$KERNEL_URL ($KERNEL_BRANCH)"
printf '%-14s %s\n' ''      "@ $KERNEL_REF"
printf '%-14s %s\n' rkbin   "$RKBIN_URL @ $RKBIN_REF"
printf '%-14s %s\n' rknpu2  "$RKNPU2_URL @ $RKNPU2_REF"
printf '%-14s %s\n' rootfs  "debian $ROOTFS_SUITE/$ROOTFS_ARCH, profile $ROOTFS_PROFILE"
echo

if [ -d "$OUT" ]; then
	echo "built:"
	[ -f "$OUT/kernel.release" ] && printf '  %-26s %s\n' kernel "$(cat "$OUT/kernel.release")"
	for f in idbloader.img u-boot.img "$KERNEL_IMAGE" "$KERNEL_DTS.dtb" \
	         "$BOARD-sdcard.img" "$BOARD-rootfs.ubi"; do
		[ -f "$OUT/$f" ] && printf '  %-26s %s\n' "$f" "$(du -h "$OUT/$f" | cut -f1)"
	done
	[ -f "$OUT/rootfs.size-mib" ] && printf '  %-26s %s MiB\n' rootfs "$(cat "$OUT/rootfs.size-mib")"
else
	echo "nothing built yet"
fi
