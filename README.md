# DietPi-SmartPi

**DietPi (unofficial) for the YUMi SmartPi One** — converts the
[SmartPi-armbian](https://github.com/Yumi-Lab/SmartPi-armbian) Debian trixie
server image into a [DietPi](https://github.com/MichaIng/DietPi) system:
minimal footprint, `dietpi-software` catalog, ramlog, and the full DietPi
tooling, on top of the SmartPi One custom stack.

> Status: **experimental**

## How it works

1. The GitHub Actions workflow downloads the
   `Yumi-smartpi1-trixie-debian13-server` image from the **latest
   SmartPi-armbian release**.
2. The image is grown by 2 GB, loop-mounted, and entered with an armhf
   chroot (qemu-user-static).
3. [`install.sh`](install.sh) runs the **official DietPi installer**
   non-interactively with `HW_MODEL=25` (Generic Allwinner H3) and
   `DISTRO_TARGET=8` (trixie).
4. The image is shrunk back to its minimal size (+200 MB margin — DietPi
   re-expands to the full SD card on first boot) and repacked following the
   OS builder naming convention:
   `Yumi-smartpi1-trixie-debian13-dietpi-{timestamp}.img.xz`.

## What survives the conversion

`HW_MODEL=25` keeps the existing kernel/bootloader stack (the installer only
replaces them for explicitly listed boards), and `install.sh` additionally
`apt-mark hold`s every `linux-*` package:

- U-Boot `smartpi1_defconfig` (DRAM 576 MHz, ZQ, ODT)
- Kernel 6.18 with the 1368 MHz overclock and `sun8i-h3-smartpi-one.dtb`
- SmartPad screen auto-detection and 180° rotation (console service)

## Usage

Run the **Convert to DietPi** workflow (Actions tab → Run workflow). Inputs:

| Input | Default | Description |
|-------|---------|-------------|
| `release_tag` | latest release | SmartPi-armbian release to convert |
| `artifact_filter` | `smartpi1-trixie-debian13-server` | Base image variant |
| `dietpi_owner` / `dietpi_branch` | `MichaIng` / `master` | DietPi source |
| `hw_model` | `25` | DietPi hardware model ID |

The converted image is published as a workflow artifact.

## First boot

Standard DietPi first-boot flow: login `root` / `dietpi`, the setup wizard
runs `dietpi-update` then `dietpi-software`. Network (Ethernet/DHCP) is
required on first boot.
