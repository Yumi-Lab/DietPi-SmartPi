#!/bin/bash
# Convert a Yumi SmartPi One Armbian rootfs (trixie server) into DietPi.
#
# This script runs INSIDE an armhf chroot of the mounted image — see
# .github/workflows/convert.yml for the orchestration. It drives the official
# DietPi installer (MichaIng/DietPi) in fully non-interactive mode.
#
# Key choices, learned the hard way:
# - HW_MODEL=25 ("Generic Allwinner H3") is NOT in the installer's
#   armbian_packages lists, so the installer keeps the existing kernel,
#   device tree, U-Boot and boot.scr/armbianEnv.txt instead of replacing
#   them with generic apt.armbian.com builds. Our custom stack (DRAM
#   576 MHz U-Boot, 1368 MHz OC kernel, sun8i-h3-smartpi-one.dtb,
#   SmartPad rotation service) must survive the conversion.
# - Every env var below must be set BEFORE the installer starts, otherwise
#   it falls back to interactive whiptail menus and dies in the chroot.

set -e

export DEBIAN_FRONTEND=noninteractive
export GITOWNER="${GITOWNER:-MichaIng}"
export GITBRANCH="${GITBRANCH:-master}"
export HW_MODEL="${HW_MODEL:-25}"           # 25 = Generic Allwinner H3
export DISTRO_TARGET="${DISTRO_TARGET:-8}"  # 8 = Debian trixie
# The board has no onboard WiFi, but USB adapters are common: ship the WiFi
# stack (iw, wpasupplicant, wireless-regdb) so a dongle works offline. With
# WIFI_REQUIRED=0 the installer purges those packages, and dietpi-config then
# needs an internet connection to enable WiFi — impossible on a board that has
# only WiFi to get online.
export WIFI_REQUIRED="${WIFI_REQUIRED:-1}"
export IMAGE_CREATOR="${IMAGE_CREATOR:-Yumi Lab}"
export PREIMAGE_INFO="${PREIMAGE_INFO:-Yumi SmartPi-armbian (Armbian trixie server)}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-yumi}"

echo "=== DietPi conversion: HW_MODEL=${HW_MODEL} DISTRO_TARGET=${DISTRO_TARGET} (${GITOWNER}/${GITBRANCH}) ==="

# Belt and braces: never let apt swap our custom kernel/DTB/U-Boot for the
# generic apt.armbian.com builds — the SmartPi One would not boot with them
# (custom DRAM timings + sun8i-h3-smartpi-one.dtb).
dpkg-query -Wf '${db:Status-Status} ${Package}\n' 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' 'linux-headers-*' 2>/dev/null \
    | awk '$1 == "installed" { print $2 }' | xargs -r apt-mark hold || true
echo "Held packages:"
apt-mark showhold

# systemd is not running inside the chroot, and trixie's systemctl hard-fails
# on '--now' in that situation (older versions silently ignored it). Divert
# systemctl behind a shim that drops '--now' and turns runtime-only verbs
# into no-ops, while persistent enable/disable/mask still manage symlinks.
if [[ ! -d /run/systemd/system ]]; then
    dpkg-divert --local --rename --add /usr/bin/systemctl > /dev/null
    cat > /usr/bin/systemctl << 'SHIM'
#!/bin/bash
args=()
for a in "$@"; do [[ ${a} == '--now' ]] || args+=("${a}"); done
verb=''
for a in "${args[@]}"; do case ${a} in -*) ;; *) verb=${a}; break ;; esac; done
case ${verb} in
    start|stop|restart|try-restart|reload|reload-or-restart|kill|is-active|isolate) exit 0 ;;
esac
exec /usr/bin/systemctl.distrib "${args[@]}"
SHIM
    chmod 755 /usr/bin/systemctl
    SYSTEMCTL_DIVERTED=1
fi

# The installer deletes /boot/boot.bmp to strip Armbian branding, which also
# removes our boot logo — keep a copy and put it back afterwards.
[[ -f /boot/boot.bmp ]] && cp /boot/boot.bmp /tmp/boot.bmp.keep

# Fetch and run the official DietPi installer
curl -sSfL "https://raw.githubusercontent.com/${GITOWNER}/DietPi/${GITBRANCH}/.build/images/dietpi-installer" -o /tmp/dietpi-installer
bash /tmp/dietpi-installer

if [[ -f /tmp/boot.bmp.keep ]]; then
    cp /tmp/boot.bmp.keep /boot/boot.bmp
    rm -f /tmp/boot.bmp.keep
    echo "Boot logo restored after the installer removed it"
fi

echo "=== DietPi installer finished ==="

# Restore the real systemctl
if [[ ${SYSTEMCTL_DIVERTED:-0} == 1 ]]; then
    rm -f /usr/bin/systemctl
    dpkg-divert --local --rename --remove /usr/bin/systemctl > /dev/null
fi

# Preseed the first run so a flashed image configures itself with ZERO
# interaction on the device: one unattended boot cycle and it is ready.
# Default login: root / yumi (change with passwd or dietpi-config).
preseed() {
    local key="$1" value="$2"
    sed -i "s|^#\?${key}=.*|${key}=${value}|" /boot/dietpi.txt
    grep -q "^${key}=" /boot/dietpi.txt || echo "${key}=${value}" >> /boot/dietpi.txt
}
preseed AUTO_SETUP_AUTOMATED 1
preseed AUTO_SETUP_GLOBAL_PASSWORD "${DEFAULT_PASSWORD}"
preseed SURVEY_OPTED_IN 0
# WiFi on by default: firstboot then loads the modules, drops the cfg80211
# blacklist and applies /boot/dietpi-wifi.txt — all offline, since the
# packages ship in the image (WIFI_REQUIRED=1). Users put their SSID/key in
# dietpi-wifi.txt on the FAT partition before first boot, or use
# dietpi-config later. The regulatory country code keeps DietPi's upstream
# default (GB): the image is distributed worldwide, so no country of ours
# is right — users set AUTO_SETUP_NET_WIFI_COUNTRY_CODE in dietpi.txt.
preseed AUTO_SETUP_NET_WIFI_ENABLED 1
echo "First-run preseed applied:"
grep -E "^(AUTO_SETUP_AUTOMATED|SURVEY_OPTED_IN|AUTO_SETUP_NET_WIFI_ENABLED)=" /boot/dietpi.txt

# DietPi's firstboot enables either WiFi OR Ethernet and comments out the
# other in /etc/network/interfaces. With WiFi on by default, an
# Ethernet-only user would boot a card whose eth0 is disabled — offline,
# and the automated first-run setup needs network to finish. Patch the
# one-shot firstboot script so neither branch disables the other
# interface: both stay allow-hotplug and ifupdown brings up whichever is
# connected. The script runs once, at first boot, before any dietpi-update
# could restore the upstream version.
FIRSTBOOT=/var/lib/dietpi/services/dietpi-firstboot.bash
if ! grep -q 'c\\#allow-hotplug' "${FIRSTBOOT}"; then
    echo "ERROR: interface-disable pattern not found in ${FIRSTBOOT} — DietPi changed the firstboot script, review the WiFi+Ethernet patch"
    exit 1
fi
sed -i 's|c\\#allow-hotplug|c\\allow-hotplug|g' "${FIRSTBOOT}"
if grep -q 'c\\#allow-hotplug' "${FIRSTBOOT}"; then
    echo "ERROR: firstboot WiFi+Ethernet patch did not apply"
    exit 1
fi
echo "Firstboot patched: WiFi and Ethernet both stay enabled"

# Familiar 'pi' account next to root, following the Raspberry Pi convention:
# sudo rights plus the hardware groups needed for GPIO/I2C/SPI/serial work.
if id -u pi > /dev/null 2>&1; then
    echo "User 'pi' already exists"
else
    useradd -m -s /bin/bash -c "SmartPi user" pi
    echo "pi:${DEFAULT_PASSWORD}" | chpasswd
    for g in sudo users adm dialout audio video plugdev netdev input i2c spi gpio dietpi; do
        getent group "${g}" > /dev/null 2>&1 && usermod -aG "${g}" pi
    done
    echo "User 'pi' created — groups: $(id -nG pi)"
fi

# The base image loads the g_ether (RNDIS) gadget for the OTG port, which
# macOS cannot use — switch to g_ncm (CDC NCM), natively supported by both
# macOS (AppleUSBNCM) and Windows 11. Verified on hardware.
sed -i 's/^g_ether/g_ncm/' /etc/modules 2>/dev/null || true
sed -i 's/^g_ether/g_ncm/' /etc/modules-load.d/*.conf 2>/dev/null || true
grep -rn "^g_ncm" /etc/modules /etc/modules-load.d/ 2>/dev/null || echo "NOTE: no gadget module configured (base image may predate OTG support)"

# The installer clears apt holds — re-apply them so a future dietpi-update
# can never swap our custom kernel/DTB/U-Boot for the generic
# apt.armbian.com builds (which lack the SmartPi One device tree).
dpkg-query -Wf '${db:Status-Status} ${Package}\n' 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' 'linux-headers-*' 2>/dev/null \
    | awk '$1 == "installed" { print $2 }' | xargs -r apt-mark hold || true
echo "Held packages after install:"
apt-mark showhold

# Sanity checks. Only a missing dietpi.txt is fatal — everything else is
# informational so a debug run still produces an inspectable image.
echo "=== Post-conversion sanity checks ==="
for f in /boot/boot.scr /boot/armbianEnv.txt /boot/boot.bmp; do
    if [[ -f "${f}" ]]; then
        echo "OK: ${f} present"
    else
        echo "WARNING: ${f} is missing — check the boot stack before flashing"
    fi
done
if compgen -G "/boot/dtb*/sun8i-h3-smartpi-one.dtb" > /dev/null || compgen -G "/boot/dtb*/allwinner/sun8i-h3-smartpi-one.dtb" > /dev/null; then
    echo "OK: sun8i-h3-smartpi-one.dtb present"
else
    echo "NOTE: sun8i-h3-smartpi-one.dtb absent (base image may predate the custom DTS)"
fi
if [[ -x /usr/local/bin/smartpad-detect.sh ]]; then
    echo "OK: SmartPad rotation scripts survived"
else
    echo "NOTE: smartpad rotation scripts absent (base image may predate them)"
fi
if [[ -L /etc/systemd/system/multi-user.target.wants/smartpad-console-rotate.service ]]; then
    echo "OK: smartpad-console-rotate.service still enabled"
elif [[ -f /etc/systemd/system/smartpad-console-rotate.service ]]; then
    echo "NOTE: smartpad-console-rotate.service present but not enabled"
fi
if [[ -f /boot/dietpi.txt ]]; then
    echo "OK: /boot/dietpi.txt present"
else
    echo "ERROR: /boot/dietpi.txt missing — DietPi install did not complete"
    exit 1
fi
# WiFi stack: must be installed AND marked manual (an auto mark means the
# first dietpi-update autoremove on the device purges it), with the
# credentials file on the FAT partition. This is what makes a USB dongle
# usable offline — a regression here once shipped silently, so it is fatal.
for p in wpasupplicant iw wireless-regdb; do
    if ! dpkg-query -s "${p}" > /dev/null 2>&1; then
        echo "ERROR: ${p} not installed — WiFi stack missing (check WIFI_REQUIRED)"
        exit 1
    fi
    if ! apt-mark showmanual | grep -qx "${p}"; then
        echo "ERROR: ${p} not marked manual — it would be autoremoved on first boot"
        exit 1
    fi
done
if [[ ! -f /boot/dietpi-wifi.txt ]]; then
    echo "ERROR: /boot/dietpi-wifi.txt missing — WiFi credentials preseed not generated"
    exit 1
fi
echo "OK: WiFi stack installed, marked manual, dietpi-wifi.txt on the FAT partition"
echo "=== Conversion complete ==="
