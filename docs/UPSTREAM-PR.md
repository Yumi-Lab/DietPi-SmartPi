# Path to official DietPi support (upstream PR)

Goal: native SmartPi One support in [MichaIng/DietPi](https://github.com/MichaIng/DietPi),
with a PR that is **purely additive** — zero behavior change for any existing
device — so it is easy to review and safe to merge.

## Prerequisites (in order)

1. **This repo's conversion must be proven** on real hardware first: flash a
   converted image, verify boot, `dietpi-update`, `dietpi-software` installs,
   and stability under load. Upstream will ask for that evidence.
2. **Open a device support request issue** upstream before any PR — MichaIng
   assigns hardware model IDs himself and asks for device details
   (SoC, RAM, storage, kernel/U-Boot provenance).

## What the PR would contain (additive only)

| File (upstream) | Change |
|-----------------|--------|
| `dietpi/func/dietpi-obtain_hw_model` | Detect `/proc/device-tree/model` = `YUMi SmartPi One` → new `G_HW_MODEL` ID (assigned by upstream), `G_HW_ARCH=2` (armv7l) |
| `.build/images/dietpi-installer` | Add the new ID to the hardware menu; do **not** add it to any `armbian_packages` list, so the existing kernel/U-Boot stack is kept (same class as Generic Allwinner H3) |
| `dietpi/dietpi-obtain_hw_model` docs / `README` | Device list entry |

Rules that keep the PR safe for them:

- New hardware ID only — never reuse or renumber an existing one.
- Detection keyed on the exact device-tree model string, which only our DTS
  (`sun8i-h3-smartpi-one.dts`, model `YUMi SmartPi One`) emits — no other
  device can match it.
- No change to any existing code path: the ID is added to menus/detection
  and inherits the existing "keep current kernel/bootloader" behavior.

## Longer term (optional)

To let DietPi *build* SmartPi One images themselves (not just convert), our
kernel/U-Boot `.deb`s would need to be apt-installable. Options:

- Host a small apt repo (e.g. `apt.yumi-lab.com`) publishing
  `linux-image-current-sunxi`, `linux-dtb-current-sunxi`,
  `linux-u-boot-smartpi1-current` from the SmartPi-armbian CI, or
- Upstream the board into `armbian/build` so apt.armbian.com carries the
  packages (also removes our BOOTPATCHDIR maintenance).

Until then, the conversion approach in this repo is the supported path.
