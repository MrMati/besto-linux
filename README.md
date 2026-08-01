# luckfox-linux

A modern **glibc** Linux system for the **Luckfox Pico Max** (Rockchip RV1106G3),
built from pinned upstreams by a handful of shell scripts. Debian userspace,
Rockchip 6.6 kernel, mainline U-Boot, and a working NPU. All multimedia functionality 
is explicitly omitted.

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
| **NPU**        | `rknpu` built into the kernel, plus a **glibc-adapted `librknnmrt.so.2`** |
| **memory**     | zram swap, tuned sysctls: a full systemd userspace idles around 45 MB of the 256 MB |
| **cpufreq**    | `ondemand` over 408 MHz - 1.2 GHz, throttling to a cooling device at 85 C |
| **storage**    | ext4 on microSD (grows to fill the card on first boot), or UBIFS in the 237 MB SPI NAND |
| **access**     | serial on UART2, DHCP on Ethernet, and USB-C gadget (NCM network + ACM console) |

Package management works. `apt install` works. `rustup` works. `pip install`
works. That is the whole point.

## Status

Kernel boots cleanly, userspace starts green, NPU inference works right away.

## Why these pieces

Getting a Pico Max to a good place means making three choices, and the obvious
answer is wrong for two of them.

**Kernel: Rockchip `develop-6.6`.** Mainline Linux has no RV1106 support
whatsoever, and the ongoing mainlining effort ([meta-rv110x] has 14 patches for
clk/pinctrl/OTP/GMAC/USB-PHY, [rockchip-rv1106-dev] boots 6.18 to a shell) does
not include the NPU and is not close to it.
Rockchip's own `develop-6.6` branch is the sweet spot nobody seems to use: it
has full RV1106 SoC support *and* `drivers/rknpu` with a `rockchip,rv1106-rknpu`
match.

**Bootloader: mainline U-Boot.** RV1106 support currently only resides in 
[Concept U-Boot](https://concept.deinde.dev/u-boot/u-boot). It is a normal 
modern U-Boot: binman, `ROCKCHIP_TPL` for the rkbin DDR blob, standard boot, 
builds with a current GCC. This repo pins that branch and adds the Pico Max on top:
a devicetree, a defconfig, a boot environment and a `LUCKFOX_PICO_DRAM_SIZE_MB`
Kconfig.

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
So this repo does it once, properly, and ships a real library.

`/dev/rknpu` is owned by the `render` group, so inference does not need root.
`rknpu-info` on the board prints the driver version, NPU clock, load, SoC
temperature and which runtime is installed.

The runtime's weights and feature maps come out of Rockchip's own dma-heap, and
the kernel parameter that sizes it is **`rk_dma_heap_cma=`**. 
`RK_DMA_HEAP_SIZE` in `board.env` sets it, and 32 MB is the default here
as well as the driver's. `rv1106_defconfig` also means the heap is
carved out of the 256 MB rather than lent to the page allocator, so raising it
is a straight trade against userspace memory: 32 MB leaves ~220 MB, 64 MB leaves
~188 MB.

The NPU runs at **594 MHz**, up from the 500 MHz the clock tree comes up on.
That lives in its own devicetree fragment, `kernel/dts/*-npu-594mhz.dtsi`;
comment its `#include` out of the board dts for 500 MHz. The rate does not
actually belong to the NPU node (its ACLK is a gate on a mux with no divider,
so the NPU is simply whatever `clk_500m_src` is, and 594 MHz is GPLL/2), which
is what the fragment is there to explain.

## CPU frequency, and why it stops at 1.2 GHz

The RV1106 is a 1.6 GHz part and `rv1106.dtsi` has the OPPs to prove it, but
those top bins need up to 1.0 V on VDD_ARM. Rockchip's reference design gets
that from a PWM-controlled buck. Luckfox left the buck off the Pico Max and
fitted a fixed 0.9 V rail, so **1.2 GHz is the fastest OPP this board can hold**:
it is the last one specified at 850 mV. The devicetree deletes the four above
it, because nothing else would: the fallback leg of
`regulator_set_voltage_triplet()` asks for the OPP's *minimum* voltage, which is
850 mV for every entry in the table, so a fixed 0.9 V rail "satisfies" 1.6 GHz
just as readily as it satisfies 408 MHz. The OPP table is the only thing
standing between the part and an undervolted 1.6 GHz.

Two more things follow from the fixed rail. PVTPLL calibration is deleted with
the OPPs: it exists to search for the lowest stable voltage per frequency, and
there is nothing here to search. And DVFS is frequency-only, so the power
savings are the dynamic ones and nothing else.

Getting this far mostly needed `CONFIG_ROCKCHIP_OPP`. `rockchip-cpufreq` calls
`rockchip_init_opp_info()` before it will register the `cpufreq-dt` device, and
without that symbol it is a stub returning `-EOPNOTSUPP`. Nothing selects it,
and `rv1106_defconfig` does not set it, so the driver failed at probe and the
board had no `cpufreq` directory at all.

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

## Flash

RV1106's Bootrom can boot from NAND and MMC.

### NAND U-Boot + SD card system

```bash
# 1. board into maskrom mode: hold BOOT while applying power (USB 2207:110c)
scripts/flash.sh nand            # write idbloader + u-boot into the NAND

# 2. the system itself
scripts/flash.sh sd /dev/sdX     # asks for confirmation
```

### SD card only

```bash
scripts/flash.sh sd /dev/sdX     # asks for confirmation
```

Once running our U-Boot. Maskrom mode can be entered with:
```bash
run maskrom
```

To run entirely out of the NAND instead, `scripts/flash.sh nand --with-rootfs`
writes the UBI image too; U-Boot falls back to it when no card has a bootflow.

First boot: console on **UART2, 115200 8N1**, root password `luckfox`, 
Ethernet via DHCP, and `172.32.0.93` over the USB-C gadget. The card is
handed over read-only so `systemd-fsck-root` gets to run, then remounted `rw`
from `/etc/fstab`; the partition and filesystem grow to fill the card.

The gadget is two functions on the one cable. `ssh root@172.32.0.93` over NCM,
and a second login prompt on the ACM port, which the host sees as `/dev/ttyACM0`:

```bash
tio /dev/ttyACM0        # or: screen /dev/ttyACM0, picocom /dev/ttyACM0
```

Board can be addressed by the serial
the gadget reports, which is the SoC's own and does not change:

```bash
tio /dev/serial/by-id/usb-Luckfox_Pico_Max_556abe2b7497589c-if02
```

Debian's desktop-sized housekeeping is masked, not deleted: `apt-daily`,
`apt-daily-upgrade`, `e2scrub`, `fstrim` and `dpkg-db-backup` do not run on
their own. `systemctl unmask` whichever you want back.

## Layout

```
board/luckfox-pico-max/
  board.env                    every board-specific number, in one file
  kernel/dts/                  rv1106g3-luckfox-pico-max.dts, plus the
                               optional fragments it #includes
  kernel/config/               the fragment merged over rv1106_defconfig
  kernel/patches/              the few fixes that touch files we do not own
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

## Credits

The RV1106 U-Boot work is Fabio Estevam's and Simon Glass's [!1147][uboot-mr]. 
The Pico Max devicetree started from Luckfox's SDK by way of [meta-luckfox-pico]. 
[meta-rv110x] is the reference for what mainlining this SoC actually takes.
