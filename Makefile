# luckfox-linux -- a glibc Linux system for the Luckfox Pico Max (RV1106G3)
#
#   make            build everything and produce flashable images
#   make optee      OP-TEE OS (upstream, plat-rockchip rv1106) + TA dev kit
#   make optee-examples  upstream example TAs and host apps, for exercising
#                   the secure world end to end from userspace
#   make uboot      U-Boot (mainline + the in-review RV1106 series), with
#                   OP-TEE packed into the boot FIT
#   make kernel     Rockchip 6.6 kernel, RKNPU built in
#   make npu        glibc librknnmrt.so.2 and headers
#   make rootfs     Debian armhf root filesystem
#   make images     SD card image and SPI NAND UBI image
#   make shell      inspect the built rootfs
#   make clean      drop build outputs, keep the source checkouts
#   make distclean  drop everything

SHELL := /bin/bash
BOARD ?= luckfox-pico-max
export BOARD

S := scripts

.PHONY: all optee optee-examples uboot kernel npu rootfs images clean distclean deps shell info check

all: images

deps:
	@$(S)/install-deps.sh

optee:
	@$(S)/build-optee.sh

# The example TAs build against the dev kit that make optee exports.
optee-examples: optee
	@$(S)/build-optee-examples.sh

# binman packs tee-raw.bin into u-boot.itb, so OP-TEE builds first.
uboot: optee
	@$(S)/build-uboot.sh

kernel:
	@$(S)/build-kernel.sh

npu:
	@$(S)/build-npu.sh

rootfs: kernel npu optee-examples
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
