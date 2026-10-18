#!/bin/bash
# Sets up ipod-gadget on Raspberry Pi OS (Bookworm / Trixie); written for the Pi 5,
# also fine on the Zero / Zero 2 / 4:
#   - installs the kernel headers and DKMS, builds and installs the modules
#     (DKMS rebuilds them on every kernel update)
#   - puts the USB controller in device mode: dtoverlay=dwc2,dr_mode=peripheral
#     (on the Pi 5 that is the USB-C port)
#   - loads the gadget at boot
#   - optionally installs the iAP client (https://github.com/VadosKebaba/ipod, branch
#     pi5-support, or oandrew/ipod) as a service that starts at boot: pass a linux/arm64
#     binary, or a checkout of the client to build it here (needs Go: apt install golang-go)
# Usage: sudo ./install-rpi.sh [path/to/ipod | path/to/client-checkout]   then reboot.
set -euo pipefail

client=
if [ $# -gt 0 ]; then
	[ -e "$1" ] || { echo "no such file or directory: $1" >&2; exit 1; }
	client=$(readlink -f "$1")
fi
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
# HID descriptor: default, legacy (a real iPod's) or bigout (default + a 255-byte output report);
# needs the matching IPOD_GLOBAL_ARGS="--hid=..." in /etc/default/ipod-client:
#options g_ipod_hid hid_desc=bigout
# High speed like a real iPod (default: full speed only):
#options g_ipod_gadget high_speed=1
EOF
fi

echo "== iAP client"
built=
if [ -n "$client" ] && [ -d "$client" ]; then
	# a checkout of the client: build it as the user who ran sudo (their Go caches,
	# nothing root-owned left behind), into a temporary directory
	command -v go > /dev/null || { echo "building $client needs Go: sudo apt install golang-go" >&2; exit 1; }
	builder=${SUDO_USER:-root}
	built=$(sudo -u "$builder" mktemp -d)
	echo "building the client in $client as $builder"
	(cd "$client" && sudo -H -u "$builder" env CGO_ENABLED=0 go build -o "$built/ipod" ./cmd/ipod)
	client="$built/ipod"
fi
if [ -n "$client" ]; then
	# also catches a binary built for the wrong architecture
	if ! "$client" lingos > /dev/null 2>&1; then
		echo "$client doesn't run here: build it with GOOS=linux GOARCH=arm64" >&2
		exit 1
	fi
	# given the installed binary itself, keep it (install refuses to copy a file onto itself)
	if [ "$client" != /usr/local/bin/ipod ]; then
		install -m 755 "$client" /usr/local/bin/ipod
	fi
	[ -z "$built" ] || rm -rf "$built"
	install -m 644 ipod-client.service /etc/systemd/system/ipod-client.service
	if [ ! -f /etc/default/ipod-client ]; then
		cat > /etc/default/ipod-client <<'EOF'
# Global options for the ipod client (ipod-client.service), placed before "serve".
# --hid has to match the HID descriptor the kernel offers, or the client sends report ids
# the head unit doesn't expect (kernel side: /etc/modprobe.d/ipod-gadget.conf):
#   IPOD_GLOBAL_ARGS="--hid=bigout"   with   options g_ipod_hid hid_desc=bigout
#   IPOD_GLOBAL_ARGS="--hid=legacy"   with   options g_ipod_hid hid_desc=legacy
# (--hid needs the VadosKebaba/ipod client; --legacy is the older spelling of --hid=legacy)
# --lenient-auth accepts damaged certificate/signature packets from the head unit (any descriptor)
# Level 3 (the phone over Bluetooth on the car's screen and buttons), defaults shown:
#   --player=auto      the phone while one has a media player, else the stub; --player=stub: Level 2
#   --text=asis        or --text=translit (Cyrillic in Latin letters); --text-max=200 (bytes)
#   --toggle-guard     a toggle while the car takes no audio never starts the phone; =false: off
IPOD_GLOBAL_ARGS=""
EOF
	fi
	systemctl daemon-reload
	systemctl enable ipod-client.service
	systemctl try-restart ipod-client.service
	echo "installed /usr/local/bin/ipod, ipod-client.service starts at boot"
else
	echo "skipped: pass the client binary or a checkout of it, e.g. sudo ./install-rpi.sh ~/ipod"
fi

cat <<EOF

Done. Reboot, then check:
  lsmod | grep g_ipod                   # modules loaded
  ls /sys/class/udc                     # the dwc2 controller is in device mode
  ls /dev/iap0 && aplay -l | grep iPod  # iAP device and the iPodUSB sound card
  systemctl status ipod-client          # the client, which keeps /dev/iap0 open
  journalctl -u ipod-client -f          # iAP traffic with the head unit
The head unit only sees the iPod while the client has /dev/iap0 open.
EOF
