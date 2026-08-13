#!/usr/bin/env bash
#
# Build OP-TEE OS for the board. The RV1106 port is upstream (plat-rockchip,
# flavor rv1106), so this is a plain source build -- no Rockchip blob, no
# fork, no patches.
#
# Outputs, all in $OUT:
#   tee-raw.bin   the OP-TEE core without the OPTE image header. binman packs
#                 it into u-boot.itb as the FIT's op-tee node, and the SPL
#                 jumps straight to its load address -- with the header in
#                 front, the header would execute as code and hang.
#   tee.elf       the same core with symbols, for a debugger.
#
# Also exports the TA development kit to $OUT/optee/export-ta_arm32, which
# build-optee-examples.sh consumes to build the example TAs.
#
# The memory layout is the platform default and matches the vendor firmware's
# (rkbin RV1106TOS.ini): TZDRAM at 0x03d00000 (16 MB) with 1 MB of static
# shared memory right above it, i.e. [0x03d00000, 0x04e00000). Three other
# places depend on that window and check.sh holds them all together:
#
#   - the op-tee load address in rv1106-luckfox-pico-max-u-boot.dtsi
#   - the reserved-memory carve-out in rv1106g3-luckfox-pico-max.dts
#   - the U-Boot staging addresses in pico-max.env, which must stay outside it

. "$(dirname "$0")/lib.sh"

need git make "${CROSS_COMPILE}gcc" python3

# gen_tee_bin.py, which produces tee-raw.bin from tee.elf, needs pyelftools.
python3 -c 'import elftools' 2>/dev/null \
	|| die "python3-pyelftools is missing (run scripts/install-deps.sh)"

optee="$(fetch optee_os "$OPTEE_URL" "$OPTEE_REF")"

b="$OUT/optee"
mkdir -p "$b"

# Build the core targets plus the TA dev kit; build-optee-examples.sh builds
# the example TAs and host apps against the exported dev kit, and the in-tree
# sample TAs stay out of the build.
#
# CFG_DT_ADDR=n drops the platform's forced DTB address (0x08000000). That
# default exists for the vendor SPL, which passes garbage in r2; mainline SPL
# passes the FIT's control DTB address in r2 (common/spl/spl_optee.S), and
# with CFG_DT_ADDR unset OP-TEE believes it. The same handoff puts the
# non-secure entry point in lr = CONFIG_TEXT_BASE = 0x00200000, which is
# exactly the platform's CFG_NS_ENTRY_ADDR default.
#
# This is a debug build: CFG_TEE_CORE_DEBUG keeps assertions and lock checks
# in (it is also the upstream default, forced here so a default change cannot
# silently drop them), and the trace levels are turned up so the secure
# console on ttyS2 actually narrates what the core and the TAs do. Level 3 is
# error+info+debug -- level 4 would add flow tracing on every SMC, which
# drowns a 115200 console. Turn both back down to 1 for a release build.
log "building op-tee (PLATFORM=rockchip-rv1106, debug, core log level 3)"
make -C "$optee" O="$b" \
	PLATFORM=rockchip-rv1106 \
	CFG_ARM32_core=y \
	CROSS_COMPILE="$CROSS_COMPILE" \
	CROSS_COMPILE_core="$CROSS_COMPILE" \
	CROSS_COMPILE_ta_arm32="$CROSS_COMPILE" \
	CFG_DT_ADDR=n \
	CFG_TEE_CORE_DEBUG=y \
	CFG_TEE_CORE_LOG_LEVEL=3 \
	CFG_TEE_TA_LOG_LEVEL=3 \
	NOWERROR=1 \
	-j"$JOBS" \
	"$b/core/tee-raw.bin" "$b/core/tee.elf" ta_dev_kit

cp -f "$b/core/tee-raw.bin" "$OUT/tee-raw.bin"
cp -f "$b/core/tee.elf" "$OUT/tee.elf"

[ -f "$b/export-ta_arm32/mk/ta_dev_kit.mk" ] \
	|| die "ta_dev_kit did not export $b/export-ta_arm32"

log "op-tee artifacts in $OUT (TA dev kit in $b/export-ta_arm32):"
ls -la "$OUT/tee-raw.bin" "$OUT/tee.elf"
