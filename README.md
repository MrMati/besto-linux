# luckfox-linux

A modern **glibc** Linux system for the **Luckfox Pico Max** (Rockchip RV1106G3),
built from pinned upstreams by a handful of shell scripts. Debian userspace,
Rockchip 6.6 kernel, mainline U-Boot, and a working NPU.

```
make deps      # once, on a Debian/Ubuntu host
make           # -> out/luckfox-pico-max-sdcard.img
```

## What you get

|                | |
|----------------|---|
| **libc**       | glibc, via Debian trixie `armhf` |
| **init**       | systemd, with networkd/resolved/timesyncd wired up |
| **kernel**     | Rockchip `develop-6.6` + a devicetree and config written for this board |
| **bootloader** | Mainline U-Boot with standard boot (`extlinux.conf`), not the 2017.09 vendor fork |
| **NPU**        | `rknpu` built into the kernel, plus a **glibc-native `librknnmrt.so.2`** |
| **memory**     | zram swap, tuned sysctls: a full systemd userspace idles around 45 MB of the 256 MB |
| **storage**    | ext4 on microSD (grows to fill the card on first boot), or UBIFS in the 237 MB SPI NAND |
| **access**     | serial on UART2, DHCP on Ethernet, and USB-C gadget (NCM network + ACM console) |

Package management works. `apt install` works. `rustup` works. `pip install`
works. That is the whole point.

## Why these pieces

Getting a Pico Max to a good place means making three choices, and the obvious
answer is wrong for two of them.

**Kernel: Rockchip `develop-6.6`.** Mainline Linux has no RV1106 support
whatsoever, and the ongoing mainlining effort ([meta-rv110x] has 14 patches for
clk/pinctrl/OTP/GMAC/USB-PHY, [rockchip-rv1106-dev] boots 6.18 to a shell) does
not include the NPU and is not close to it. The Luckfox SDK ships 5.10, which
does have everything but predates most of what a 2026 glibc userspace assumes.
Rockchip's own `develop-6.6` branch is the sweet spot nobody seems to use: it
has full RV1106 SoC support *and* `drivers/rknpu` with a `rockchip,rv1106-rknpu`
match, and `rv1106_defconfig` already sets `CONFIG_ROCKCHIP_RKNPU`. Four LTS
releases newer than the SDK, with the NPU intact.

**Bootloader: mainline U-Boot.** RV1106 support comes from [!1147][uboot-mr]
(Fabio Estevam's RV1103B work plus RV1106, RV1103 and a `board/luckfox/pico`
target, tested on a Pico Mini B booting from both SPI NAND and microSD). That
MR is merged into the master branch of the GitLab instance it was filed on, but
*not* into `u-boot/u-boot`: there is still no `mach-rockchip/rv1106` and no
`board/luckfox` in any upstream release, so the pin stays on the GitLab tree
until it lands. It is a normal modern U-Boot: binman, `ROCKCHIP_TPL`
for the rkbin DDR blob, standard boot, builds with a current GCC. That is worth
far more than the vendor 2017.09 fork with its `-Wno-error` pile and Rockchip
FIT `boot.img` format. This repo pins that branch and adds the Pico Max on top:
a devicetree, a defconfig, a boot environment and a `LUCKFOX_PICO_DRAM_SIZE_MB`
Kconfig so the 64/128/256 MB variants stop needing separate `dram_init()` code.

**Rootfs: Debian, not Buildroot or Yocto.** [luckfox-yocto] and
[meta-luckfox-pico] are good work, and if you want a 30 MB read-only appliance
image you should use them. This repo is for the other case: you have 256 MB of
RAM and a 32 GB card, and you want a machine, not an appliance. Debian armhf
gives you that for a ~250 MB rootfs.

[meta-rv110x]: https://github.com/RamasyaR/meta-rv110x
[rockchip-rv1106-dev]: https://github.com/gflix/rockchip-rv1106-dev
[luckfox-yocto]: https://github.com/RamasyaR/luckfox-yocto
[meta-luckfox-pico]: https://github.com/Maobuff/meta-luckfox-pico
[uboot-mr]: https://concept.u-boot.org/u-boot/u-boot/-/merge_requests/1147

## The NPU

Rockchip publishes the RV1103/RV1106 runtime (`librknnmrt`) as a **uClibc build
only** — there is no glibc shared object anywhere in `rknn-toolkit2`. On a glibc
rootfs the vendor `.so` is unloadable, so every glibc project on this SoC ends up
statically linking `librknnmrt.a` and carrying its own compat shim.

It turns out that archive is almost libc-agnostic. Out of everything it imports,
exactly two symbols are uClibc-private: `__ctype_b` and `__ctype_tolower`.
uClibc-ng reuses glibc's bit layout for both, so they can be rebuilt at load
time from glibc's own locale tables ([`npu/uclibc-ctype-compat.c`]).

So this repo does it once, properly, and ships a real library:

```
/usr/lib/arm-linux-gnueabihf/librknnmrt.so.2   glibc-native, no text relocations
/usr/lib/arm-linux-gnueabihf/librknnmrt.a      the untouched vendor archive
/usr/include/rknn/                             vendor headers
/usr/lib/.../pkgconfig/librknnmrt.pc           pkg-config --libs rknnmrt
```

`scripts/build-npu.sh` refuses to ship it unless the result has no `TEXTREL`, no
remaining uClibc imports, and exports the RKNN entry points. Link against it
like any other library:

```c
// gcc app.c $(pkg-config --cflags --libs librknnmrt)
#include <rknn_api.h>
```

`/dev/rknpu` is owned by the `render` group, so inference does not need root.
`rknpu-info` on the board prints the driver version, NPU clock, load, SoC
temperature and which runtime is installed.

[`npu/uclibc-ctype-compat.c`]: npu/uclibc-ctype-compat.c

## Build

Any Debian or Ubuntu host. Roughly 25 GB of disk and 20 minutes on 16 cores.

```bash
make deps                        # apt-get the toolchain, mmdebstrap, image tools
make check                       # seconds; run this before you push
make                             # uboot + kernel + npu + rootfs + images
make info                        # what is pinned, what is built
```

Individual stages: `make uboot`, `make kernel`, `make npu`, `make rootfs`,
`make images`. Knobs, all overridable from the environment:

```bash
ROOTFS_PROFILE=dev make          # minimal | standard | dev (adds a native toolchain)
ROOTFS_SUITE=bookworm make       # if you want the older glibc
ROOTFS_ROOT_PASSWORD= make       # empty -> root stays locked, SSH keys only
JOBS=32 make
```

CI builds the whole thing on every push and uploads the images.

## Flash

The BootROM checks the SPI NAND before the microSD, so on a stock board the
vendor bootloader in NAND wins no matter what is on the card. Put this U-Boot in
NAND once and then iterate on the card freely.

Flashing NAND is not optional, and the vendor firmware's `u-boot,spl-boot-order
= &sdmmc, &spi_nor, &spi_nand, &emmc` does not get you out of it. Its SPL does
try the card first, but it looks for U-Boot in a GPT partition named `uboot` or
at raw LBA 16384, and it only accepts a FIT (`SPL_RAW_IMAGE_SUPPORT` and
`SPL_LEGACY_IMAGE_SUPPORT` are both off in `rv1106_defconfig`) — this image puts
a legacy uImage at 1 MiB, so the lookup fails and the SPL falls through to the
NAND. The vendor U-Boot proper cannot help either: its bootcmd is
`boot_fit; boot_android`, distro boot is compiled out, and the build has no ext4
at all, so it can reach neither the extlinux config nor the rootfs. The card is
harmless in a stock board — nothing is written, nothing is bricked — it simply
does not boot from it.

```bash
# 1. board into maskrom mode: hold BOOT while applying power (USB 2207:110c)
scripts/flash.sh ram             # optional: try U-Boot from RAM, writes nothing
scripts/flash.sh nand            # write idbloader + u-boot into the NAND

# 2. the system itself
scripts/flash.sh sd /dev/sdX     # asks you to confirm the device name
```

To run entirely out of the NAND instead, `scripts/flash.sh nand --with-rootfs`
writes the UBI image too; U-Boot falls back to it when no card has a bootflow.

First boot: console on **UART2, 115200 8N1**, root password `luckfox` (change
it), Ethernet via DHCP, and `172.32.0.93` over the USB-C gadget.

### Trying it without writing to the NAND

You do not have to commit to the NAND to see this thing boot. Maskrom mode
takes the whole bootloader over USB — 471 is the rkbin DDR blob, 472 is our SPL
with `u-boot.img` appended — and `board_boot_order()` puts `BOOT_DEVICE_RAM`
first whenever the BootROM reports a USB boot source, so the SPL runs the
payload it was handed and never looks at a flash device:

```bash
scripts/flash.sh sd /dev/sdX     # card first, the board is not involved yet
# hold BOOT while applying power
scripts/flash.sh ram             # DDR blob + SPL + U-Boot proper, all over USB
```

U-Boot then boots the card exactly as it would in production: bootstd, ext4,
`extlinux.conf`, kernel, DTB, rootfs, growroot. Everything is covered except
the one step that reads the bootloader off a flash device.

To cover that step too, `scripts/flash.sh ram --from-card` sends the SPL
without its payload. With nothing to boot from RAM the SPL walks
`u-boot,spl-boot-order` for real: SPI NAND first, where a stock board's vendor
image is a Rockchip FIT that this SPL rejects, and then sector 0x800 of the
card. Falling through like that only works because `SPL_RAW_IMAGE_SUPPORT` is
off: with it on, the RAM loader takes the empty payload for a headerless
U-Boot, "succeeds", and jumps into whatever DRAM happened to contain. From the
U-Boot prompt you can check the card byte-for-byte before trusting it, since a
bad offset here is silent:

```
=> mmc dev 1 && mmc read 0x800000 0x800 0x400 && iminfo 0x800000
```

Nothing in either mode writes to the board, and pulling the power puts a stock
board back exactly where it was.

## Layout

```
board/luckfox-pico-max/
  board.env                    every board-specific number, in one file
  kernel/dts/                  rv1106g3-luckfox-pico-max.dts
  kernel/config/               the fragment merged over rv1106_defconfig
  uboot/tree/                  files copied verbatim into the U-Boot checkout
  uboot/patches/               the few fixes that touch files we do not own
rootfs/
  packages/                    minimal / standard / dev
  overlay/                     everything shipped into /
  hooks/customize.sh           runs on the host against the rootfs, no chroot
npu/                           the glibc shim and rknpu-info
scripts/                       one script per stage; lib.sh holds the pins
```

Upstreams are pinned to exact commits in `scripts/lib.sh`. Nothing floats.

## Notes on the devicetree

`rv1106g3-luckfox-pico-max.dts` includes `rv1106.dtsi` and nothing else. It
deliberately does **not** pull in `rv1106-evb.dtsi` or `rv1106-ipc.dtsi`, which
is what every other Luckfox devicetree does and which turns on the entire
camera/ISP/encoder half of the SoC plus a fixed set of image sensors. This is a
Linux machine with an NPU, not an IP camera.

Two things in there matter more than they look:

- **`vdd_arm`**, the PWM regulator on PWM0. Without it the CPU is stuck at
  whatever voltage the bootloader left, cpufreq cannot leave the boot OPP, and
  the part cooks itself under load. This is the single most important node.
- **`&npu { status = "okay"; }`**. It is `disabled` in `rv1106.dtsi`, and a
  devicetree that forgets it builds and boots and silently has no `/dev/rknpu`.
  `make check` fails if it goes missing.

## Status

Verified in CI and locally: the devicetree compiles against Rockchip 6.6, the
config fragment survives `merge_config.sh` with all 18 load-bearing symbols
intact and the FIQ debugger off, and `librknnmrt.so.2` links clean with the full
RKNN API exported and no text relocations.

On hardware, `scripts/flash.sh ram` gets a Pico Max through the DDR blob, the
SPL and into U-Boot proper with the right 256 MB, so the maskrom path and the
DRAM handoff are real. Whether the SPL can then read U-Boot proper off a flash
device, and whether Linux comes up behind it, is still unverified.

The first attempt at that could not: nothing in `rv1106.dtsi` is marked
`bootph-*`, so fdtgrep handed the SPL a devicetree with no CRU in it and both
storage drivers failed with `-22` on a clock they could not resolve. The
`-u-boot.dtsi` here names the CRU, the GRF, the pinctrl node and the pin groups
the SPL uses, which is what `rk356x-u-boot.dtsi` does and what the upstream
Pico Mini B (RV1103, 64 MB, SPI NAND only) is missing.

## Credits

The RV1106 U-Boot work is Fabio Estevam's, Simon Glass's, and Rockchip's
(Elaine Zhang, Ye Zhang), via [!1147][uboot-mr]. The Pico Max devicetree started
from Luckfox's SDK by way of [meta-luckfox-pico]. [meta-rv110x] is the reference
for what mainlining this SoC actually takes. The NPU compat shim comes from
[MixyLabs/luckfox-npu](https://github.com/MixyLabs/luckfox-npu).
