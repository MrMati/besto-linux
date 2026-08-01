#!/usr/bin/env bash
# Shared setup for every build stage. Sourced, never executed.

set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="${BOARD:-luckfox-pico-max}"
BOARD_DIR="$TOP/board/$BOARD"

[ -f "$BOARD_DIR/board.env" ] || { echo "unknown board '$BOARD'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$BOARD_DIR/board.env"

SRC="${SRC:-$TOP/src}"
OUT="${OUT:-$TOP/out}"
DL="${DL:-$TOP/dl}"
mkdir -p "$SRC" "$OUT" "$DL"

# ---------------------------------------------------------------- sources ---
#
# Every upstream is pinned to an exact commit.

# Concept U-Boot received initial RV1106 + LuckFox support in July 2026
# https://concept.u-boot.org/u-boot/u-boot/-/merge_requests/1147.
#
# When the series reaches u-boot/u-boot, repoint UBOOT_URL at
# https://github.com/u-boot/u-boot.git and drop UBOOT_REF to a release tag.
UBOOT_URL="${UBOOT_URL:-https://concept.u-boot.org/u-boot/u-boot.git}"
UBOOT_REF="${UBOOT_REF:-63746e0a413b868c2ff0fc5d921b0c8648a9603d}"

# Rockchip's 6.6 vendor kernel. This is the newest tree that has both RV1106
# SoC support and drivers/rknpu with a rockchip,rv1106-rknpu match. Mainline
# Linux has no RV1106 support at all
KERNEL_URL="${KERNEL_URL:-https://github.com/rockchip-linux/kernel.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-develop-6.6}"
KERNEL_REF="${KERNEL_REF:-1ba51b059f25533c5529b7f68186190b47d6a7b3}"

# Closed-source DDR init blob. Nothing boots without it.
RKBIN_URL="${RKBIN_URL:-https://github.com/rockchip-linux/rkbin.git}"
RKBIN_REF="${RKBIN_REF:-ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4}"

# RKNPU2 userspace runtime and headers.
RKNPU2_URL="${RKNPU2_URL:-https://github.com/airockchip/rknn-toolkit2.git}"
RKNPU2_REF="${RKNPU2_REF:-v2.3.2}"

CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# ---------------------------------------------------------------- helpers ---

# All progress output goes to stderr: fetch() returns a path on stdout, and
# several callers capture it.
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

need() {
	local missing=()
	for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
	[ ${#missing[@]} -eq 0 ] || die "missing host tools: ${missing[*]} (run scripts/install-deps.sh)"
}

# fetch <name> <url> <ref> [branch]
#
# Clones once into $SRC/<name> and afterwards only fetches the pinned ref. Keeps
# the tree at exactly <ref> with any local build droppings removed, so repeated
# builds are reproducible without re-downloading a gigabyte of history.
fetch() {
	local name="$1" url="$2" ref="$3" branch="${4:-}" dir="$SRC/$1"
	local pin="refs/luckfox/$name" sha=""

	if [ ! -d "$dir/.git" ]; then
		log "cloning $name"
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	else
		git -C "$dir" remote set-url origin "$url"
	fi

	if ! git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 &&
	   ! git -C "$dir" rev-parse -q --verify "$pin^{commit}" >/dev/null 2>&1; then
		log "fetching $name @ $ref"
		# A bare SHA works on GitHub; a tag name always works; some hosts
		# allow neither, so fall back to the branch and then to the lot.
		git -C "$dir" fetch -q --depth 1 origin "$ref" 2>/dev/null \
			|| { [ -n "$branch" ] && git -C "$dir" fetch -q --depth 500 origin "$branch"; } \
			|| git -C "$dir" fetch -q --tags --depth 500 origin \
			|| die "cannot fetch $ref from $url"
		# Fetching a tag or a SHA only sets FETCH_HEAD, so pin it down
		# before anything else can clobber it.
		git -C "$dir" update-ref "$pin" FETCH_HEAD
	fi

	sha="$(git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
	[ -n "$sha" ] || sha="$(git -C "$dir" rev-parse -q --verify "$pin^{commit}" 2>/dev/null || true)"
	[ -n "$sha" ] || die "$name: cannot resolve '$ref' after fetching"

	git -C "$dir" -c advice.detachedHead=false checkout -q --force "$sha"
	git -C "$dir" clean -qfdx
	printf '%s\n' "$dir"
}

# fetch_file <url> <dest>
#
# Cached download. Used where a git clone would drag in gigabytes for a handful
# of files, which is exactly the case for rknn-toolkit2's example models.
fetch_file() {
	local url="$1" dest="$2" cache
	# All the argument expansions in a single `local` happen before any of the
	# assignments take effect, so $url is not usable until the next statement.
	cache="$DL/$(printf '%s' "$url" | sha256sum | cut -c1-16)-$(basename "$url")"

	if [ ! -s "$cache" ]; then
		log "downloading $(basename "$url")"
		curl -fsSL --retry 3 --retry-delay 2 -o "$cache.part" "$url" \
			|| die "download failed: $url"
		mv "$cache.part" "$cache"
	fi
	mkdir -p "$(dirname "$dest")"
	cp -f "$cache" "$dest"
}

# apply_overlay <src-tree-dir> <dest-dir>
#
# Copies a directory tree over a source checkout. Used instead of patch files
# because every file we add is a whole new file; the two places we have to edit
# an existing file are handled explicitly by the caller.
apply_overlay() {
	local from="$1" to="$2"
	[ -d "$from" ] || return 0
	log "overlaying $(basename "$from") onto $(basename "$to")"
	tar -C "$from" -cf - . | tar -C "$to" -xf -
}

hostarch_deb() { dpkg --print-architecture 2>/dev/null || echo unknown; }

# Re-execute this script as root, then hand the results back afterwards.
#
# Building a root filesystem means creating device nodes and files owned by
# uids that are not ours. mmdebstrap's unshare mode can fake that with a user
# namespace, but only where the subuid map and the ownership of the output
# directory cooperate -- GitHub's runner workspace is one place they do not.
# Real root is boring and works everywhere, so take it when it is free.
elevate() {
	[ "$(id -u)" = 0 ] && return 0
	command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
		|| die "$(basename "$0") needs root, or sudo without a password prompt"
	log "re-running under sudo"
	exec sudo -E "$0" "$@"
}

# give_back <path>... -- return files to whoever invoked us through sudo, so
# the rest of the build (and the human) can still touch them.
give_back() {
	[ -n "${SUDO_UID:-}" ] || return 0
	chown -h "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$@" 2>/dev/null || true
}
