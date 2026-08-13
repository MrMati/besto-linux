#!/usr/bin/env bash
#
# Build the upstream OP-TEE example TAs and their host applications, so the
# secure world can be exercised end to end from userspace on the board:
#
#   optee_example_hello_world     open a session, invoke a command
#   optee_example_random          entropy from the secure world
#   optee_example_aes             AES encrypt/decrypt in a TA
#   optee_example_acipher         RSA keygen + encrypt in a TA
#   optee_example_hotp            RFC 4226 one-time passwords
#   optee_example_secure_storage  TEE-backed storage; this one round-trips
#                                 through tee-supplicant's REE FS RPC, i.e.
#                                 kernel, supplicant and /var/lib/tee too
#
# Outputs into $OUT/optee-examples-staging, laid out as a rootfs overlay:
#
#   usr/bin/optee_example_*       host apps (CAs)
#   usr/lib/optee_armtz/*.ta      the TAs. Debian's tee-supplicant loads TAs
#                                 from /lib/optee_armtz (upstream default,
#                                 Debian does not change it), and /lib is
#                                 usr/lib on a merged-usr system.
#
# The TAs build against the dev kit that build-optee.sh exports, so they are
# signed with that tree's default key and match the core's configuration.
# The host apps link against a libteec built here from the pinned
# optee_client -- build-time only: on the board they resolve the same
# libteec.so.2 soname to Debian's libteec2 package.

. "$(dirname "$0")/lib.sh"

need git make "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}readelf" python3

# The TA dev kit signs TAs with sign_encrypt.py, which needs both of these.
python3 -c 'import elftools, cryptography' 2>/dev/null \
	|| die "python3-pyelftools/python3-cryptography is missing (run scripts/install-deps.sh)"

devkit="$OUT/optee/export-ta_arm32"
[ -f "$devkit/mk/ta_dev_kit.mk" ] || die "no TA dev kit at $devkit (make optee)"

client="$(fetch optee_client "$OPTEE_CLIENT_URL" "$OPTEE_CLIENT_REF")"
examples="$(fetch optee_examples "$OPTEE_EXAMPLES_URL" "$OPTEE_EXAMPLES_REF")"

# --- libteec, for the host apps to link against ------------------------------

bc="$OUT/optee-client"
rm -rf "$bc"; mkdir -p "$bc"

log "building libteec ($OPTEE_CLIENT_REF, link-time only)"
make -C "$client" O="$bc" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	build-libteec >/dev/null

# What a host app's Makefile expects under TEEC_EXPORT: include/ and lib/.
texp="$bc/export"
mkdir -p "$texp/include" "$texp/lib"
cp -f "$client/libteec/include"/*.h "$texp/include/"
cp -d "$bc/libteec"/libteec.so* "$texp/lib/"

# --- the examples -------------------------------------------------------------

# A curated list rather than the whole tree: plugins couples to a supplicant
# plugin path baked into Debian's build, and the remaining crypto examples
# (sha, ecdh, ecdsa, sign_verify) add nothing these six do not already show.
want="hello_world random aes acipher hotp secure_storage"

for ex in $want; do
	log "building example $ex"
	make -C "$examples/$ex/host" --no-builtin-variables \
		CROSS_COMPILE="$CROSS_COMPILE" \
		TEEC_EXPORT="$texp" >/dev/null
	make -C "$examples/$ex/ta" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		TA_DEV_KIT_DIR="$devkit" >/dev/null
done

# --- staging ------------------------------------------------------------------

stage="$OUT/optee-examples-staging"
rm -rf "$stage"
mkdir -p "$stage/usr/bin" "$stage/usr/lib/optee_armtz"

for ex in $want; do
	ca="$examples/$ex/host/optee_example_$ex"
	[ -f "$ca" ] || die "example $ex built no host binary"

	# The board resolves libteec through Debian's libteec2, so the link must
	# ask for the soname that package provides -- catch a mismatch here, not
	# as a loader error on the device.
	"${CROSS_COMPILE}readelf" -d "$ca" | grep -q 'NEEDED.*\[libteec\.so\.2\]' \
		|| die "optee_example_$ex does not link libteec.so.2"

	install -m 0755 "$ca" "$stage/usr/bin/"

	tas=("$examples/$ex/ta/"*.ta)
	[ -f "${tas[0]}" ] || die "example $ex built no TA"
	install -m 0444 "${tas[@]}" "$stage/usr/lib/optee_armtz/"
done

log "optee examples staging tree:"
find "$stage" -type f | sed "s|$stage||" | sort
