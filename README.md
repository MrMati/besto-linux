# luckfox-linux

A small, reproducible Debian `armhf` system for Luckfox Pico boards. It uses
Rockchip's 6.6 kernel and the in-review RV110x U-Boot support, with no OP-TEE
and no NPU runtime or driver.

Supported boards:

| Board | SoC / RAM | NAND |
|---|---|---|
| `luckfox-pico-max` (default) | RV1106G3 / 256 MiB | 256 MiB SPI NAND |
| `luckfox-pico-mini` | RV1103 / 64 MiB | 128 MiB W25N01KVZEIR SPI NAND |

## Build

Use the Mini's default minimal profile unless its NAND budget has been
reviewed for a larger profile.

```sh
make deps
make check
make                                      # Pico Max
BOARD=luckfox-pico-mini make              # Pico Mini
```

Each build produces two installation paths:

- `out/<board>-sdcard.img`: development image. It boots Linux from ext4 on
  microSD and expands the root filesystem on first boot.
- `out/<board>-rootfs.ubi`, `idbloader.img`, and `u-boot.img`: release image.
  Flash these to SPI NAND and the whole system, including `/boot`, runs from
  UBIFS in NAND.

The Mini uses the official W25N01KV layout: 256 KiB environment, 1 MiB
idblock, 1 MiB U-Boot, 8 MiB boot partition, and the remainder as UBI. The
W25N01xx-aware Rockchip USB loader is selected for flashing it.

## Flash

For development, write the SD image to a card. A board with bootable NAND is
preferred by the BootROM, so erase/leave NAND blank while iterating on the SD
boot path.

```sh
scripts/flash.sh sd /dev/sdX
```

For a release, put the board in maskrom mode and write its boot chain and UBI
root filesystem:

```sh
scripts/flash.sh nand --with-rootfs
```

After booting the NAND release, prepare any user microSD card as one FAT32
filesystem labelled `LUCKFOX-DATA`. It is mounted automatically at
`/mnt/sdcard`; the development SD-root image does not carry that label, so it
is not mounted over its own root filesystem.

```sh
mkfs.fat -F 32 -n LUCKFOX-DATA /dev/sdX1
```

## Access over USB

The USB-C peripheral port presents an RNDIS Ethernet device plus an ACM serial
console. The board assigns `172.32.0.93/24` to `usb0`; configure the host end
as (for example) `172.32.0.1/24`, then connect with:

```sh
ssh root@172.32.0.93
```

OpenSSH is enabled by default and host keys are generated on first boot. RNDIS
is advertised with Microsoft OS descriptors so Windows binds its inbox driver;
Linux can use the same USB Ethernet link.

## CI and cache

The workflow separates checks, U-Boot, kernel, and rootfs/image construction.
It caches source trees per component and the expensive mmdebstrap base rootfs;
cache keys include the pinned source references and rootfs package lists. Run
it locally with `act` rather than compiling directly on the workstation.
