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
| `distro_target` | `8` (trixie) | Debian target: `7` bookworm, `8` trixie, `9` forky/Debian 14 (**testing**, moving target) |

The converted image is published as a workflow artifact and attached to a
GitHub release named after the base SmartPi-armbian tag.

## First boot

Fully unattended (`AUTO_SETUP_AUTOMATED=1`): one boot cycle and the system
is ready. Network is needed once for `dietpi-update` to complete the setup.

- **Logins**: `root` / `yumi` and `pi` / `yumi` (sudo + hardware groups:
  gpio, i2c, spi, dialout…).
- **Ethernet**: DHCP, works out of the box.
- **WiFi**: enabled by default, the full stack (`iw`, `wpasupplicant`,
  `wireless-regdb`) ships in the image so a USB dongle works **offline**.
  Put your network in `dietpi-wifi.txt` on the FAT partition (readable from
  any OS) before first boot, or run `dietpi-config` later. Set your country
  in `dietpi.txt` (`AUTO_SETUP_NET_WIFI_COUNTRY_CODE`, DietPi upstream
  default: `GB`). The DietPi firstboot script is patched during conversion
  so enabling WiFi does *not* disable Ethernet — both interfaces stay
  active.
- **USB OTG**: the port exposes a CDC-NCM network gadget (native on macOS
  and Windows 11), SSH via `172.22.1.1`.
