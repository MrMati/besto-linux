#!/usr/bin/env bash
#
# Assemble flashable images from the artifacts in $OUT.
#
#   luckfox-pico-max-sdcard.img   full microSD image: boot chain in the first
#                                 megabyte, then a GPT with a single ext4 root
#   luckfox-pico-max-rootfs.ubifs UBI image for the 237MB volume in SPI NAND
#   idbloader.img / u-boot.img    written into NAND with rkdeveloptool
#
# The SD image is built to fit its contents; luckfox-growroot expands it to the
# whole card on first boot.

. "$(dirname "$0")/lib.sh"

need sgdisk mkfs.ext4 sfdisk truncate

# The rootfs is full of root-owned files; reading it back needs root too.
elevate "$@"

rootdir="$OUT/rootfs"
[ -d "$rootdir" ] || die "no rootfs at $rootdir (make rootfs)"
[ -f "$OUT/idbloader.img" ] || die "no idbloader.img (make uboot)"

img="$OUT/$BOARD-sdcard.img"
rootmib="$(cat "$OUT/rootfs.size-mib")"
# ext4 metadata plus the slack that makes the first boot pleasant.
partmib=$(( rootmib + rootmib / 8 + SD_ROOT_SLACK_MIB ))
startmib=8
totalmib=$(( startmib + partmib + 2 ))

log "sd image: ${totalmib} MiB (rootfs ${rootmib} MiB -> ${partmib} MiB partition)"

rm -f "$img"
truncate -s "${totalmib}M" "$img"

# GPT, with the first 8 MiB left alone for the Rockchip boot chain. sgdisk puts
# its own tables at LBA1 and the end of the disk; LBA1 is safely before the
# idblock at LBA 64.
sgdisk --clear \
	--new=1:$(( startmib * 2048 )):0 --typecode=1:8300 \
	--change-name=1:rootfs --partition-guid=1:R \
	"$img" >/dev/null

rootuuid="$(sgdisk --info=1 "$img" | awk -F': ' '/Partition unique GUID/ {print tolower($2)}')"
log "root PARTUUID=$rootuuid"

# Render extlinux.conf from its template before the filesystem is created.
# Always from the template, never in place: sed on the previous output is a
# no-op the second time around, which would silently ship an image whose root=
# points at the partition UUID of an earlier build.
extlinux="$rootdir/boot/extlinux"
[ -f "$extlinux/extlinux.conf.in" ] || die "no extlinux.conf.in (rebuild the rootfs)"
sed "s|@@ROOT@@|PARTUUID=$rootuuid|" \
	"$extlinux/extlinux.conf.in" > "$extlinux/extlinux.conf"

log "creating ext4 root"
rootimg="$OUT/rootfs.ext4"
rm -f "$rootimg"
truncate -s "${partmib}M" "$rootimg"
# ^metadata_csum_seed keeps the fs mountable by older tools; 64bit off keeps
# resize2fs simple on a 32-bit target.
mkfs.ext4 -q -F -L rootfs -U "$rootuuid" \
	-O ^64bit,^metadata_csum_seed \
	-E lazy_itable_init=0,lazy_journal_init=0 \
	-d "$rootdir" "$rootimg"
e2fsck -fp "$rootimg" >/dev/null 2>&1 || true

log "writing the boot chain and the root partition into the image"
dd if="$rootimg" of="$img" bs=1M seek="$startmib" conv=notrunc status=none
dd if="$OUT/idbloader.img" of="$img" bs=1K seek="$SD_IDB_OFFSET_KIB" conv=notrunc status=none
dd if="$OUT/u-boot.img"    of="$img" bs=1K seek="$SD_UBOOT_OFFSET_KIB" conv=notrunc status=none
rm -f "$rootimg"

log "sd image: $img"

# ------------------------------------------------------------------- UBI ---
#
# For running entirely out of the on-board NAND. Skipped when mtd-utils is not
# installed, since it is the secondary target.
if command -v mkfs.ubifs >/dev/null 2>&1 && command -v ubinize >/dev/null 2>&1; then
	log "creating the UBI image for SPI NAND"
	ubifs="$OUT/rootfs.ubifs"
	# max_leb_cnt: how many LEBs the volume may ever grow to.
	leb_cnt=$(( (NAND_UBI_SIZE - 0) / NAND_BLOCK_SIZE - 4 ))
	mkfs.ubifs -q -r "$rootdir" -o "$ubifs" \
		-m "$NAND_PAGE_SIZE" -e "$NAND_LEB_SIZE" -c "$leb_cnt" \
		-x zstd -F

	cat > "$OUT/ubinize.cfg" <<-EOF
		[rootfs]
		mode=ubi
		image=$ubifs
		vol_id=0
		vol_type=dynamic
		vol_name=rootfs
		vol_flags=autoresize
	EOF
	ubinize -o "$OUT/$BOARD-rootfs.ubi" \
		-m "$NAND_PAGE_SIZE" -p "$NAND_BLOCK_SIZE" -s "$NAND_SUBPAGE_SIZE" \
		"$OUT/ubinize.cfg"
	rm -f "$ubifs"
	log "ubi image: $OUT/$BOARD-rootfs.ubi ($(du -h "$OUT/$BOARD-rootfs.ubi" | cut -f1))"
else
	warn "mtd-utils not installed; skipping the SPI NAND image"
fi

give_back "$OUT"/*.img "$OUT"/*.ubi 2>/dev/null

log "artifacts:"
ls -lh "$OUT"/*.img "$OUT"/*.ubi 2>/dev/null | sed 's|.*/||'
