#!/usr/bin/env bash
# Install everything needed to build on a Debian or Ubuntu host.
set -euo pipefail

pkgs=(
	# toolchain and kbuild
	gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross
	build-essential bc bison flex libssl-dev libgnutls28-dev
	device-tree-compiler python3 python3-dev python3-setuptools
	python3-pyelftools swig libpython3-dev
	# u-boot binman/tooling
	uuid-dev liblz4-tool lz4 zstd
	# rootfs. eatmydata is for mmdebstrap's hook of the same name, which drops
	# dpkg's fsyncs while the base rootfs is being built.
	mmdebstrap qemu-user-static arch-test debian-archive-keyring eatmydata
	# images
	gdisk e2fsprogs dosfstools mtd-utils util-linux fdisk
	# misc
	git curl ca-certificates cpio rsync kmod file openssl
)

echo "installing: ${pkgs[*]}"
sudo apt-get update
sudo apt-get install -y --no-install-recommends "${pkgs[@]}"

# The maskrom USB tools are not packaged anywhere; point at them rather than
# silently building a half-working flash path. `make images` needs none of them.
command -v rkdeveloptool >/dev/null 2>&1 || cat <<'EOF'

note: rkdeveloptool is not installed. flash.sh needs it to write the SPI NAND
      over USB, and it can also run flash.sh ram:
        https://github.com/rockchip-linux/rkdeveloptool
EOF

command -v rkusbboot >/dev/null 2>&1 || command -v rkflashtool >/dev/null 2>&1 || cat <<'EOF'

note: neither rkusbboot nor rkflashtool is installed. flash.sh ram works
      without them, via rkdeveloptool and a merged loader, but either one
      sends the two maskrom images directly and is less fuss:
        https://github.com/RadxaNaoki/rkusbboot
EOF
