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

# The installer replaces the whole extraargs line of armbianEnv.txt to add
# net.ifnames=0, dropping what the base image puts there for this board (the
# 1280x720 display mode, the simpledrm blacklist that keeps the HDMI console).
# Keep the base arguments and add them back to the installer's afterwards.
BASE_EXTRAARGS=$(sed -n 's/^extraargs=//p' /boot/armbianEnv.txt 2> /dev/null)

# The base image configures its first boot through cloud-init (user-data and
# network-config on the boot partition). DietPi has its own (dietpi.txt,
# dietpi-wifi.txt): left in place, cloud-init would also run on the first boot
# and set its own hostname, accounts and network over DietPi's. Remove it and
# its files so the boot partition only shows DietPi's.
if dpkg-query -W -f='${Status}' cloud-init 2> /dev/null | grep -q 'install ok installed'; then
    apt-get purge -y cloud-init
fi
rm -rf /etc/cloud /var/lib/cloud
rm -f /boot/user-data /boot/network-config /boot/meta-data /boot/*.template

# Fetch and run the official DietPi installer
curl -sSfL "https://raw.githubusercontent.com/${GITOWNER}/DietPi/${GITBRANCH}/.build/images/dietpi-installer" -o /tmp/dietpi-installer
bash /tmp/dietpi-installer

if [[ -f /tmp/boot.bmp.keep ]]; then
    cp /tmp/boot.bmp.keep /boot/boot.bmp
    rm -f /tmp/boot.bmp.keep
    echo "Boot logo restored after the installer removed it"
fi

if [[ -n ${BASE_EXTRAARGS} ]]; then
    # Word splitting is the point here: one argument per line, duplicates dropped.
    # shellcheck disable=SC2046,SC2086
    MERGED_EXTRAARGS=$(printf '%s\n' $(sed -n 's/^extraargs=//p' /boot/armbianEnv.txt) ${BASE_EXTRAARGS} | awk '!seen[$0]++' | xargs)
    sed -i "s|^extraargs=.*|extraargs=${MERGED_EXTRAARGS}|" /boot/armbianEnv.txt
    echo "Kernel arguments after the installer: $(grep '^extraargs=' /boot/armbianEnv.txt)"
    # Fatal: losing these went unnoticed for two releases.
    FINAL_EXTRAARGS=" $(sed -n 's/^extraargs=//p' /boot/armbianEnv.txt) "
    for arg in ${BASE_EXTRAARGS}; do
        [[ ${FINAL_EXTRAARGS} == *" ${arg} "* ]] || { echo "ERROR: extraargs lost ${arg} from the base image"; exit 1; }
    done
fi

# The installer regenerates /etc/fstab from DietPi's own template
# (dietpi-drive_manager 4), which never puts nofail on /boot: a FAT partition
# that fsck.fat cannot repair would drop systemd into emergency mode even though
# the kernel and initramfs it needed are already loaded. Put it back. Only the
# installer calls that regeneration, nothing on the device does, so the option
# survives until someone runs dietpi-drive_manager by hand. The proper fix
# belongs in DietPi's Get_Fstab_Entry.
# nofail alone also drops the mount's ordering before local-fs.target (systemd.mount),
# so DietPi's boot services, which read /boot, could start before it is mounted
# (seen on hardware: local-fs.target at 7.3 s, /boot at 9.5 s).
# x-systemd.before=local-fs.target restores the order without making the boot
# depend on the mount succeeding.
sed -i '/[[:space:]]\/boot[[:space:]]/{/nofail/!s/\(vfat[[:space:]][[:space:]]*\)\([^[:space:]][^[:space:]]*\)/\1\2,nofail,x-systemd.before=local-fs.target/;}' /etc/fstab
grep -q '[[:space:]]/boot[[:space:]].*nofail,x-systemd.before=local-fs.target' /etc/fstab || { echo "ERROR: nofail / ordering missing on /boot in fstab"; exit 1; }
echo "fstab /boot after the installer: $(awk '$2=="/boot"' /etc/fstab)"

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
# Pin explicitly rather than trust the upstream template default: current
# DietPi firstboot (dietpi-network apply, called with --force) sets up
# WiFi first and only falls back to Ethernet if no WiFi interface comes up —
# it no longer disables the other interface's config the way older DietPi
# versions did (the allow-hotplug sed this script used to patch here was
# removed upstream along with that behaviour; see MichaIng/DietPi
# dietpi/dietpi-network and rootfs/var/lib/dietpi/services/dietpi-firstboot.bash).
# This board has no onboard WiFi, so the common case — no USB dongle plugged
# in yet — always falls through to Ethernet. Only a dongle already plugged
# in and working at first boot leaves Ethernet unconfigured until
# 'dietpi-config' or 'dietpi-network' is run by hand afterwards.
preseed AUTO_SETUP_NET_ETHERNET_ENABLED 1
# Swap in compressed RAM (zram, auto-sized to half the RAM) instead of the
# ~1 GiB /var/swap file DietPi otherwise allocates on the SD card at first
# boot: the biggest writer on the card, and a file open for writing at every
# power cut. The installer already sets AUTO_SETUP_SWAPFILE_SIZE=1 (auto).
preseed AUTO_SETUP_SWAPFILE_LOCATION zram
# One serial console, not 32. The installer runs in a chroot that sees the build
# host's /dev, where /dev/ttyS0 to ttyS31 exist, and enables a serial getty for
# each. The SmartPi has one UART console, ttyS0: at boot systemd waited 90 s
# for the 31 others ("A start job is running for dev-ttyS..."), then gave up.
for unit in /etc/systemd/system/getty.target.wants/serial-getty@ttyS*.service; do
    [[ -e $unit || -L $unit ]] || continue
    [[ $unit == */serial-getty@ttyS0.service ]] || rm -f "$unit"
done
extra=$(find /etc/systemd/system/getty.target.wants -name 'serial-getty@ttyS*.service' ! -name 'serial-getty@ttyS0.service' | wc -l)
(( extra == 0 )) || { echo "ERROR: ${extra} extra serial consoles still enabled"; exit 1; }
echo "OK: serial console on ttyS0 only"

# First run that never needs the network.
# DietPi's first run starts by checking raw.githubusercontent.com for a newer
# DietPi, which the Great Firewall resets ("Connection reset by peer"): the
# setup failed and looped on every board booted in China. Without any network
# it failed too, on its connectivity check, its time sync and APT. Everything
# the first run would download is already in this image, fetched at conversion
# time, so the first run is made fully local, with no wait at boot:
# - yumi-firstrun.service, right after dietpi-firstboot, skips the DietPi code
#   update (install stage 0 -> 1) and marks the APT lists as fresh;
# - dietpi.txt points the connectivity test at the board itself and pauses the
#   time sync mode for the first run only, and the distro upgrade is skipped;
# - /boot/Automation_Custom_Script.sh, which DietPi runs at the end of the
#   first run, puts the real settings back and re-applies the time sync mode
#   (yumi-firstrun.service does it on the next boot if that hook was replaced).
# If AUTO_SETUP_INSTALL_SOFTWARE_ID asks for software, APT is refreshed as usual.
mkdir -p /usr/local/sbin /var/lib/yumi
cat > /usr/local/sbin/yumi-firstrun <<'FIRSTRUN'
#!/bin/bash
# Keeps DietPi's first run local; "restore" puts the real settings back.
set -u
STAGE_FILE=/boot/dietpi/.install_stage
CFG=/boot/dietpi.txt
STATE=/var/lib/yumi/firstrun.env
HOOK=/boot/Automation_Custom_Script.sh
HOOK_MARK='# yumi-firstrun restore hook'

restore() {
    if [[ -f $STATE ]]; then
        # shellcheck disable=SC1090
        . "$STATE"
        sed -i "s|^CONFIG_CHECK_CONNECTION_IP=.*|CONFIG_CHECK_CONNECTION_IP=${CONNECTION_IP}|; s|^CONFIG_CHECK_DNS_DOMAIN=.*|CONFIG_CHECK_DNS_DOMAIN=${DNS_DOMAIN}|; s|^CONFIG_NTP_MODE=.*|CONFIG_NTP_MODE=${NTP_MODE}|" "$CFG"
        /boot/dietpi/func/dietpi-set_software ntpd-mode "${NTP_MODE}" > /dev/null 2>&1 || true
        # The first run ran with time sync paused: sync now rather than at the next boot.
        [[ $NTP_MODE == [1-4] ]] && systemctl --no-block start systemd-timesyncd
        rm -f "$STATE"
        echo "yumi-firstrun: settings restored (${CONNECTION_IP}, ${DNS_DOMAIN}, time sync mode ${NTP_MODE})"
    fi
    if grep -qF "$HOOK_MARK" "$HOOK" 2> /dev/null; then rm -f "$HOOK"; fi
}

[[ ${1:-} == 'restore' ]] && { restore; exit 0; }
stage=$(cat "$STAGE_FILE" 2> /dev/null || echo -1)
[[ $stage == 2 ]] && { restore; exit 0; }
[[ $stage == 0 ]] && { echo 1 > "$STAGE_FILE"; echo "yumi-firstrun: DietPi code update skipped, the image carries it"; }
if ! grep -qE '^[[:blank:]]*AUTO_SETUP_INSTALL_SOFTWARE_ID=[0-9]' "$CFG"; then
    mkdir -p /var/lib/apt/lists/partial && touch /var/lib/apt/lists/partial
fi
FIRSTRUN
chmod 755 /usr/local/sbin/yumi-firstrun
cat > /etc/systemd/system/yumi-firstrun.service <<'UNIT'
[Unit]
Description=Keep DietPi's first run local (no GitHub, no network needed)
After=dietpi-firstboot.service
RequiresMountsFor=/boot
Before=getty@tty1.service serial-getty@ttyS0.service getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/yumi-firstrun

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/yumi-firstrun.service /etc/systemd/system/multi-user.target.wants/yumi-firstrun.service
printf 'CONNECTION_IP=%s\nDNS_DOMAIN=%s\nNTP_MODE=%s\n' \
    "$(sed -n 's/^CONFIG_CHECK_CONNECTION_IP=//p' /boot/dietpi.txt)" \
    "$(sed -n 's/^CONFIG_CHECK_DNS_DOMAIN=//p' /boot/dietpi.txt)" \
    "$(sed -n 's/^CONFIG_NTP_MODE=//p' /boot/dietpi.txt)" > /var/lib/yumi/firstrun.env
grep -qE '^CONNECTION_IP=.+' /var/lib/yumi/firstrun.env && grep -qE '^DNS_DOMAIN=.+' /var/lib/yumi/firstrun.env && grep -qE '^NTP_MODE=[0-9]' /var/lib/yumi/firstrun.env || { echo "ERROR: could not read the connectivity and time sync settings from dietpi.txt"; cat /var/lib/yumi/firstrun.env; exit 1; }
preseed CONFIG_CHECK_CONNECTION_IP 127.0.0.1
preseed CONFIG_CHECK_DNS_DOMAIN localhost
preseed CONFIG_NTP_MODE 0
: > /boot/dietpi/.skip_distro_upgrade
[[ -e /boot/Automation_Custom_Script.sh ]] || printf '#!/bin/bash\n# yumi-firstrun restore hook\n/usr/local/sbin/yumi-firstrun restore\n' > /boot/Automation_Custom_Script.sh
[[ -x /usr/local/sbin/yumi-firstrun && -L /etc/systemd/system/multi-user.target.wants/yumi-firstrun.service && -f /boot/Automation_Custom_Script.sh ]] || { echo "ERROR: yumi-firstrun not installed"; exit 1; }
echo "OK: first run made local (saved: $(tr '\n' ' ' < /var/lib/yumi/firstrun.env))"

echo "First-run preseed applied:"
grep -E "^(AUTO_SETUP_AUTOMATED|SURVEY_OPTED_IN|AUTO_SETUP_NET_WIFI_ENABLED|AUTO_SETUP_NET_ETHERNET_ENABLED|AUTO_SETUP_SWAPFILE_SIZE|AUTO_SETUP_SWAPFILE_LOCATION)=" /boot/dietpi.txt

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
# Informational only: confirms the WiFi-first/Ethernet-fallback mechanism
# this script's AUTO_SETUP_NET_* preseed relies on is still the one DietPi
# ships. Not fatal, since we no longer patch this script — just a tripwire
# if upstream reworks firstboot networking again.
FIRSTBOOT=/var/lib/dietpi/services/dietpi-firstboot.bash
if [[ -f "${FIRSTBOOT}" ]] && ! grep -q 'AUTO_SETUP_NET_WIFI_ENABLED' "${FIRSTBOOT}"; then
    echo "NOTE: ${FIRSTBOOT} no longer mentions AUTO_SETUP_NET_WIFI_ENABLED — DietPi may have reworked firstboot networking again, review the WiFi+Ethernet preseed"
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
