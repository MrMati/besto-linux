#!/usr/bin/env bash
#
# Write images to the board.
#
#   flash.sh sd /dev/sdX     write the microSD image to a card
#   flash.sh nand            write the boot chain (and optionally the UBI
#                            rootfs) into the on-board SPI NAND over USB
#   flash.sh ram             run U-Boot from RAM over USB, touching no flash
#   flash.sh ram --from-card same, but only the SPL runs from RAM: it then
#                            loads U-Boot proper the way a real boot would,
#                            from the NAND if it can and otherwise the card
#
# For the USB modes, put the board in maskrom mode first: hold BOOT while
# applying power, or leave the flash blank. It enumerates as 2207:110c.

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
	size_gb=$(( $(blockdev --getsize64 "$dev") / 1000000000 ))
	echo "About to overwrite $dev ($(lsblk -dno MODEL,SIZE "$dev" | xargs), ${size_gb}GB)"
	printf 'Type the device name again to confirm: '
	read -r confirm
	[ "$confirm" = "$dev" ] || die "aborted"

	log "writing $(basename "$img") to $dev"
	dd if="$img" of="$dev" bs=4M conv=fsync status=progress
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

ram)
	# The BootROM's maskrom mode takes two blobs: 471 goes into SRAM and is
	# the rkbin DDR blob, 472 goes into the DRAM it just brought up and is
	# our SPL with u-boot.img appended as a payload. The SPL prefers that
	# payload (BOOT_DEVICE_RAM is prepended to the boot order whenever the
	# BootROM reports a USB boot source), so the whole bootloader runs from
	# RAM and no flash is touched or even read.
	i471="$OUT/u-boot-rockchip-usb471.bin"
	i472="$OUT/u-boot-rockchip-usb472.bin"
	for f in "$i471" "$i472"; do
		[ -f "$f" ] || die "no $f (make uboot)"
	done

	if [ "${1:-}" = "--from-card" ]; then
		# Cut the payload off, and the RAM loader finds no image to boot.
		# The SPL then falls through to u-boot,spl-boot-order and fetches
		# u-boot.img from the SPI NAND or, failing that, from sector
		# CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR of the card -- the one
		# step a plain RAM boot cannot exercise. A stock board's vendor
		# image in NAND is a Rockchip FIT, which this SPL rejects, so it
		# ends up on the card either way.
		[ -f "$OUT/u-boot.img" ] || die "no $OUT/u-boot.img (make uboot)"
		off=$(( $(stat -c %s "$i472") - $(stat -c %s "$OUT/u-boot.img") ))
		magic="$(dd if="$i472" bs=1 skip="$off" count=4 status=none | od -An -tx1 | tr -d ' \n')"
		[ "$magic" = "27051956" ] \
			|| die "no uImage header at offset $off of $(basename "$i472"); refusing to guess where the payload starts"
		head -c "$off" "$i472" > "$OUT/u-boot-rockchip-usb472-spl.bin"
		i472="$OUT/u-boot-rockchip-usb472-spl.bin"
		log "sending the SPL alone; it will load U-Boot proper from flash"
	fi

	log "booting U-Boot from RAM; nothing is written to the flash"
	if command -v rkusbboot >/dev/null 2>&1; then
		rkusbboot "$i471" "$i472"
	elif command -v rkflashtool >/dev/null 2>&1; then
		rkflashtool l < "$i471"
		rkflashtool L < "$i472"
	elif command -v rkdeveloptool >/dev/null 2>&1 && [ -x "$SRC/rkbin/tools/boot_merger" ]; then
		# rkdeveloptool only speaks the merged loader format, so build one
		# out of the same two blobs. boot_merger resolves paths relative to
		# the rkbin checkout, hence the copies.
		rkbin="$SRC/rkbin"
		cp -f "$i471" "$rkbin/ramboot471.bin"
		cp -f "$i472" "$rkbin/ramboot472.bin"
		cat > "$rkbin/RKBOOT/RV1106RAMBOOT.ini" <<-EOF
			[CHIP_NAME]
			NAME=RV1106
			[VERSION]
			MAJOR=1
			MINOR=1
			[CODE471_OPTION]
			NUM=1
			Path1=ramboot471.bin
			Sleep=1
			[CODE472_OPTION]
			NUM=1
			Path1=ramboot472.bin
			[LOADER_OPTION]
			NUM=2
			LOADER1=FlashData
			LOADER2=FlashBoot
			FlashData=ramboot471.bin
			FlashBoot=ramboot472.bin
			[OUTPUT]
			PATH=rv1106_ramboot.bin
			[SYSTEM]
			NEWIDB=true
			[FLAG]
			471_RC4_OFF=true
			RC4_OFF=true
		EOF
		( cd "$rkbin" && ./tools/boot_merger RKBOOT/RV1106RAMBOOT.ini >/dev/null )
		rkdeveloptool db "$rkbin/rv1106_ramboot.bin"
	else
		die "need rkusbboot, rkflashtool, or rkdeveloptool with an rkbin checkout (make uboot)"
	fi
	log "U-Boot should be on the console now (UART2, 115200 8N1)."
	;;

*)
	# The comment block at the top of this file is the usage text.
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
	exit 1
	;;
esac
