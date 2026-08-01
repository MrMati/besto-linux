#!/usr/bin/env bash
#
# Write images to the board.
#
#   flash.sh sd /dev/sdX     write the microSD image to a card
#   flash.sh nand            write the boot chain (and optionally the UBI
#                            rootfs) into the on-board SPI NAND over USB


. "$(dirname "$0")/lib.sh"

mode="${1:-}"; shift || true

case "$mode" in
sd)
	dev="${1:-}"
	[ -b "$dev" ] || die "usage: flash.sh sd /dev/sdX   (must be a block device)"
	img="$OUT/$BOARD-sdcard.img"
	[ -f "$img" ] || die "no $img (make images)"

	# Refuse to write to something that is mounted or looks like a system disk.
	if lsblk -no MOUNTPOINT "$dev" | grep -q .; then
		die "$dev has mounted partitions; unmount them first"
	fi
	size_gb=$(( $(sudo blockdev --getsize64 "$dev") / 1000000000 ))
	echo "About to overwrite $dev ($(lsblk -dno MODEL,SIZE "$dev" | xargs), ${size_gb}GB)"
	printf 'Type Y/y to confirm: '
	read -r confirm
	[ "$confirm" = "Y" ] || [ "$confirm" = "y" ] || die "aborted"

	log "writing $(basename "$img") to $dev"
	sudo dd if="$img" of="$dev" bs=4M conv=fsync status=progress
	sync
	log "done. The BootROM prefers the SPI NAND: if the board has a bootable"
	log "image in NAND it will ignore the card. Use 'flash.sh nand' to put this"
	log "U-Boot in NAND, or erase the NAND, to boot from the card."
	;;

nand)
	need rkdeveloptool
	rkbin="$SRC/rkbin"
	loader="$OUT/rv1106_download.bin"
	[ -f "$loader" ] || die "no $loader (make uboot)"

	log "waiting for a maskrom device"
	rkdeveloptool ld | grep -qi maskrom || die "no board in maskrom mode (hold BOOT while powering on)"

	log "uploading the download loader"
	rkdeveloptool db "$loader"
	sleep 1

	# Offsets in 512-byte sectors, matching the partition map in board.env.
	log "writing idbloader.img @ $NAND_IDB_OFFSET"
	rkdeveloptool wl $(( NAND_IDB_OFFSET / 512 )) "$OUT/idbloader.img"
	log "writing u-boot.img @ $NAND_UBOOT_OFFSET"
	rkdeveloptool wl $(( NAND_UBOOT_OFFSET / 512 )) "$OUT/u-boot.img"

	ubi="$OUT/$BOARD-rootfs.ubi"
	if [ -f "$ubi" ] && [ "${1:-}" = "--with-rootfs" ]; then
		log "writing the UBI rootfs @ $NAND_UBI_OFFSET (this takes a while)"
		rkdeveloptool wl $(( NAND_UBI_OFFSET / 512 )) "$ubi"
	fi

	rkdeveloptool rd
	log "done; power cycle the board. Console is UART2 at 115200 8N1."
	;;

*)
	# The comment block at the top of this file is the usage text.
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
	exit 1
	;;
esac
