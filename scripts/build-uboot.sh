#!/usr/bin/env bash
#
# Build U-Boot (SPL + proper) for the board, including the RV1106 series that
# has not reached u-boot/u-boot yet and our own Pico Max board support.
#
# Outputs, all in $OUT:
#   idbloader.img              TPL(rkbin DDR init) + SPL, written at the offset
#                              the BootROM reads (LBA 64 on SD, 0x40000 in NAND)
#   u-boot.img                 U-Boot proper, as a legacy uImage: binman only
#                              wraps it in a FIT for arm64 or with OP-TEE
#   u-boot-rockchip-usb47*.bin maskrom RAM-boot images, for `rockusb`

. "$(dirname "$0")/lib.sh"

need git make "${CROSS_COMPILE}gcc" bison flex python3 swig

rkbin="$(fetch rkbin "$RKBIN_URL" "$RKBIN_REF")"
ub="$(fetch u-boot "$UBOOT_URL" "$UBOOT_REF")"

ddr="$rkbin/$RKBIN_DDR_BIN"
[ -f "$ddr" ] || die "DDR blob missing: $ddr"

# --- board support ----------------------------------------------------------
#
# The U-Boot Concept ships board/luckfox/pico with the Pico Mini B
# (RV1103) only. Everything the Max needs is new files, except two: the SoC
# Kconfig needs a target symbol, and MAINTAINERS wants the new defconfig
# listed. Both are handled below so the overlay stays a pure file copy.

shopt -s nullglob
for p in "$BOARD_DIR"/uboot/patches/*.patch; do
	log "applying $(basename "$p")"
	git -C "$ub" apply --whitespace=nowarn "$p" \
		|| die "$(basename "$p") does not apply to u-boot @ $UBOOT_REF"
done
shopt -u nullglob

apply_overlay "$BOARD_DIR/uboot/tree" "$ub"

if ! grep -q TARGET_LUCKFOX_PICO_RV1106 "$ub/arch/arm/mach-rockchip/rv1106/Kconfig"; then
	log "registering TARGET_LUCKFOX_PICO_RV1106"
	python3 - "$ub/arch/arm/mach-rockchip/rv1106/Kconfig" <<-'PY'
	import sys
	path = sys.argv[1]
	anchor = 'config ROCKCHIP_BOOT_MODE_REG'
	entry = '''config TARGET_LUCKFOX_PICO_RV1106
	bool "LUCKFOX_PICO_RV1106"
	help
	  Support Luckfox's Pico series of RV1106 boards, such as the Pico Pro
	  and the Pico Max. These add a second CPU-side DRAM tier (128MB or
	  256MB), a 100M Ethernet PHY and a larger SPI NAND to the RV1103
	  boards, and carry the full 0.5 TOPS NPU.

'''
	text = open(path).read()
	if anchor not in text:
	    sys.exit(f'anchor {anchor!r} not found in {path}')
	open(path, 'w').write(text.replace(anchor, entry + anchor, 1))
	PY
fi

grep -q luckfox-pico-max "$ub/board/luckfox/pico/MAINTAINERS" 2>/dev/null || \
	echo "F:	configs/luckfox-pico-max-rv1106_defconfig" >> "$ub/board/luckfox/pico/MAINTAINERS"

# --- build ------------------------------------------------------------------

log "configuring u-boot ($UBOOT_DEFCONFIG)"
make -C "$ub" O="$OUT/u-boot" CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG"

log "verifying the defconfig took effect"
python3 - "$ub/configs/$UBOOT_DEFCONFIG" "$OUT/u-boot/.config" <<-'PY'
	import sys

	want_file, config_file = sys.argv[1], sys.argv[2]

	have = {}
	for line in open(config_file):
	    line = line.strip()
	    if line.startswith('CONFIG_'):
	        sym, _, val = line.partition('=')
	        have[sym] = val
	    elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
	        have[line.split()[1]] = 'n'

	bad = []
	for line in open(want_file):
	    line = line.strip()
	    if not line or (line.startswith('#') and not line.endswith(' is not set')):
	        continue
	    if line.startswith('#'):
	        sym, want = line.split()[1], 'n'
	    else:
	        sym, _, want = line.partition('=')
	    got = have.get(sym)
	    if got is None:
	        bad.append(f'{sym}: absent from .config -- unknown symbol, or unmet dependencies')
	    elif got != want:
	        bad.append(f'{sym}: asked for {want}, got {got}')

	if bad:
	    print('\n'.join('  ' + b for b in bad), file=sys.stderr)
	    sys.exit(f'{len(bad)} defconfig symbol(s) did not take effect')
	PY

log "building u-boot"
make -C "$ub" O="$OUT/u-boot" CROSS_COMPILE="$CROSS_COMPILE" \
	ROCKCHIP_TPL="$ddr" -j"$JOBS"

for f in idbloader.img u-boot.img u-boot-rockchip-usb471.bin u-boot-rockchip-usb472.bin; do
	if [ -f "$OUT/u-boot/$f" ]; then
		cp -f "$OUT/u-boot/$f" "$OUT/$f"
	else
		warn "u-boot did not produce $f"
	fi
done

# The Rockchip usbplug loader, needed to write the flash over USB. It is a
# prebuilt from rkbin, not something we compile, but it belongs next to the
# images it flashes.
if [ -x "$rkbin/tools/boot_merger" ]; then
	log "building the maskrom download loader"
	( cd "$rkbin" && ./tools/boot_merger RKBOOT/RV1106MINIALL.ini >/dev/null )
	loader="$(ls -1 "$rkbin"/rv1106_download_*.bin 2>/dev/null | head -1 || true)"
	[ -n "$loader" ] && cp -f "$loader" "$OUT/rv1106_download.bin"
fi

log "u-boot artifacts in $OUT:"
ls -la "$OUT"/idbloader.img "$OUT"/u-boot.img 2>/dev/null || true
