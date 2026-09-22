# luckfox-linux -- a glibc Linux system for Luckfox Pico boards
#
#   make            build everything and produce flashable images
#   make uboot      U-Boot (mainline + the in-review RV110x series)
#   make kernel     Rockchip 6.6 kernel
#   make rootfs     Debian armhf root filesystem
#   make images     SD card image and SPI NAND UBI image
#   make shell      inspect the built rootfs
#   make clean      drop build outputs, keep the source checkouts
#   make distclean  drop everything

SHELL := /bin/bash
BOARD ?= luckfox-pico-max
export BOARD

S := scripts

.PHONY: all uboot kernel rootfs images clean distclean deps shell info check

all: images

deps:
	@$(S)/install-deps.sh

uboot:
	@$(S)/build-uboot.sh

kernel:
	@$(S)/build-kernel.sh

rootfs: kernel
	@$(S)/build-rootfs.sh

images: uboot rootfs
	@$(S)/mk-image.sh

check:
	@$(S)/check.sh

info:
	@$(S)/info.sh

shell:
	@test -d out/rootfs || { echo "no rootfs; run make rootfs" >&2; exit 1; }
	@echo "entering out/rootfs (needs qemu-user binfmt)"
	@sudo chroot out/rootfs /bin/bash

clean:
	rm -rf out

distclean: clean
	rm -rf src dl
