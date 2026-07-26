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
export WIFI_REQUIRED="${WIFI_REQUIRED:-0}"  # SmartPi One has no onboard WiFi
export IMAGE_CREATOR="${IMAGE_CREATOR:-Yumi Lab}"
export PREIMAGE_INFO="${PREIMAGE_INFO:-Yumi SmartPi-armbian (Armbian trixie server)}"

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

# Fetch and run the official DietPi installer
curl -sSfL "https://raw.githubusercontent.com/${GITOWNER}/DietPi/${GITBRANCH}/.build/images/dietpi-installer" -o /tmp/dietpi-installer
bash /tmp/dietpi-installer

echo "=== DietPi installer finished ==="

# Restore the real systemctl
if [[ ${SYSTEMCTL_DIVERTED:-0} == 1 ]]; then
    rm -f /usr/bin/systemctl
    dpkg-divert --local --rename --remove /usr/bin/systemctl > /dev/null
fi

# Sanity checks. Only a missing dietpi.txt is fatal — everything else is
# informational so a debug run still produces an inspectable image.
echo "=== Post-conversion sanity checks ==="
for f in /boot/boot.scr /boot/armbianEnv.txt; do
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
# The SmartPad auto-rotation (800x480 + touchscreen detection) must stay
# active on the converted image: re-enable its service in case the
# installer's service cleanup disabled it, and fail if that is impossible.
if [[ -f /etc/systemd/system/smartpad-console-rotate.service ]]; then
    systemctl enable smartpad-console-rotate.service
    if [[ -L /etc/systemd/system/multi-user.target.wants/smartpad-console-rotate.service ]]; then
        echo "OK: smartpad-console-rotate.service enabled"
    else
        echo "ERROR: smartpad-console-rotate.service could not be re-enabled"
        exit 1
    fi
fi
if [[ -f /boot/dietpi.txt ]]; then
    echo "OK: /boot/dietpi.txt present"
else
    echo "ERROR: /boot/dietpi.txt missing — DietPi install did not complete"
    exit 1
fi
echo "=== Conversion complete ==="
