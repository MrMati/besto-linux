#!/usr/bin/env bash
# Install everything needed to build on a Debian or Ubuntu host.
set -euo pipefail

pkgs=(
	# toolchain and kbuild
	gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross
	build-essential bc bison flex libssl-dev libgnutls28-dev
	device-tree-compiler python3 python3-dev python3-setuptools
	python3-pyelftools python3-cryptography swig libpython3-dev
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

command -v rkdeveloptool >/dev/null 2>&1 || cat <<'EOF'

note: rkdeveloptool is not installed. flash.sh needs it to write the SPI NAND
      over USB:  https://github.com/rockchip-linux/rkdeveloptool
EOF
