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
	# rootfs
	mmdebstrap qemu-user-static arch-test debian-archive-keyring
	# images
	gdisk e2fsprogs dosfstools mtd-utils util-linux fdisk
	# misc
	git curl ca-certificates cpio rsync kmod file openssl
)

echo "installing: ${pkgs[*]}"
sudo apt-get update
sudo apt-get install -y --no-install-recommends "${pkgs[@]}"

# rkdeveloptool and rockusb are not packaged anywhere; point at them rather
# than silently building a half-working flash path.
command -v rkdeveloptool >/dev/null 2>&1 || cat <<'EOF'

note: rkdeveloptool is not installed. It is only needed to write the SPI NAND
      over USB (make images works without it):
        https://github.com/rockchip-linux/rkdeveloptool
EOF
