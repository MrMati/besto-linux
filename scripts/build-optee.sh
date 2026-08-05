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

# Build only the core targets: the in-tree sample TAs are not shipped, and
# skipping them keeps the TA toolchain and signing machinery out of the build.
#
# CFG_DT_ADDR=n drops the platform's forced DTB address (0x08000000). That
# default exists for the vendor SPL, which passes garbage in r2; mainline SPL
# passes the FIT's control DTB address in r2 (common/spl/spl_optee.S), and
# with CFG_DT_ADDR unset OP-TEE believes it. The same handoff puts the
# non-secure entry point in lr = CONFIG_TEXT_BASE = 0x00200000, which is
# exactly the platform's CFG_NS_ENTRY_ADDR default.
log "building op-tee (PLATFORM=rockchip-rv1106)"
make -C "$optee" O="$b" \
	PLATFORM=rockchip-rv1106 \
	CFG_ARM32_core=y \
	CROSS_COMPILE="$CROSS_COMPILE" \
	CROSS_COMPILE_core="$CROSS_COMPILE" \
	CFG_DT_ADDR=n \
	CFG_TEE_CORE_LOG_LEVEL=1 \
	NOWERROR=1 \
	-j"$JOBS" \
	"$b/core/tee-raw.bin" "$b/core/tee.elf"

cp -f "$b/core/tee-raw.bin" "$OUT/tee-raw.bin"
cp -f "$b/core/tee.elf" "$OUT/tee.elf"

log "op-tee artifacts in $OUT:"
ls -la "$OUT/tee-raw.bin" "$OUT/tee.elf"
