#!/bin/bash
# Sets up ipod-gadget on Raspberry Pi OS (Bookworm / Trixie); written for the Pi 5,
# also fine on the Zero / Zero 2 / 4:
#   - installs the kernel headers and DKMS, builds and installs the modules
#     (DKMS rebuilds them on every kernel update)
#   - puts the USB controller in device mode: dtoverlay=dwc2,dr_mode=peripheral
#     (on the Pi 5 that is the USB-C port)
#   - loads the gadget at boot
# Usage: sudo ./install-rpi.sh   then reboot.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root: sudo $0" >&2
	exit 1
fi

model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
case "$model" in
	"Raspberry Pi"*) echo "== $model" ;;
	*) echo "not a Raspberry Pi: '$model'" >&2; exit 1 ;;
esac

PKG=ipod-gadget
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' gadget/dkms.conf)
KVER=$(uname -r)

echo "== kernel headers + dkms for $KVER"
headers=("linux-headers-$KVER")
# 6.18.50+rpt-rpi-2712 -> linux-headers-rpi-2712: the metapackage keeps headers coming
# with every new kernel, which DKMS needs to rebuild the modules after an upgrade
case "$KVER" in
	*+rpt-rpi-*) headers+=("linux-headers-${KVER##*+rpt-}") ;;
esac
apt-get update
# no recommends: they can pull in Debian's (not the Pi's) kernel headers
apt-get install -y --no-install-recommends dkms "${headers[@]}"

echo "== dkms $PKG/$VER"
if [ -n "$(dkms status -m "$PKG" -v "$VER")" ]; then
	dkms remove -m "$PKG" -v "$VER" --all
fi
rm -rf "/usr/src/$PKG-$VER"
mkdir -p "/usr/src/$PKG-$VER"
cp gadget/Makefile gadget/dkms.conf gadget/*.c gadget/*.h "/usr/src/$PKG-$VER/"
dkms add -m "$PKG" -v "$VER"
dkms install -m "$PKG" -v "$VER" -k "$KVER"

echo "== boot config"
config=/boot/firmware/config.txt
[ -f "$config" ] || config=/boot/config.txt
# match the exact line: stock config.txt already has dtoverlay=dwc2,dr_mode=host under [cm5]
if grep -q '^dtoverlay=dwc2,dr_mode=peripheral' "$config"; then
	echo "$config already enables USB device mode"
else
	cp "$config" "$config.ipod-gadget.bak"
	printf '\n[all]\n# ipod-gadget: USB device (gadget) mode, on the Pi 5 this is the USB-C port\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$config"
	echo "added dtoverlay=dwc2,dr_mode=peripheral to $config (backup: $config.ipod-gadget.bak)"
fi

echo "== load at boot"
cat > /etc/modules-load.d/ipod-gadget.conf <<'EOF'
# ipod-gadget (written by install-rpi.sh)
libcomposite
g_ipod_audio
g_ipod_hid
g_ipod_gadget
EOF
if [ ! -f /etc/modprobe.d/ipod-gadget.conf ]; then
	cat > /etc/modprobe.d/ipod-gadget.conf <<'EOF'
# Options for the iPod gadget (see README), e.g. when the head unit only sees a mass storage device:
#options g_ipod_gadget swap_configs=1
#options g_ipod_gadget only_ipod=1
#options g_ipod_gadget product_id=0x1297
EOF
fi

cat <<EOF

Done. Reboot, then check:
  lsmod | grep g_ipod                   # modules loaded
  ls /sys/class/udc                     # the dwc2 controller is in device mode
  ls /dev/iap0 && aplay -l | grep iPod  # iAP device and the iPodUSB sound card
The head unit only sees the iPod while the client app has /dev/iap0 open:
  https://github.com/oandrew/ipod
EOF
