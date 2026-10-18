#!/bin/bash
# ipod-gadget extras/pi-audio: the iPod output becomes the Pi's default speaker, always on,
# and the Pi a Bluetooth speaker ("AUCD") for the phone, all without anyone logged in.
#
#   sudo bash extras/pi-audio/install.sh [user]     (default: the user running sudo)
#
# Safe to run again (an update). Undo: sudo bash extras/pi-audio/uninstall.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${1:-${SUDO_USER:-}}
if [ -z "$U" ] || [ "$U" = root ]; then
	echo "usage: sudo bash $0 [user]   (the user PipeWire runs as, not root)" >&2
	exit 1
fi
id "$U" > /dev/null
UIDN=$(id -u "$U")
HOMEDIR=$(getent passwd "$U" | cut -d: -f6)
HERE=$(cd "$(dirname "$0")" && pwd)
STATE=/var/lib/aucd-audio
mkdir -p "$STATE"

echo "== packages"
need=()
for p in pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth bluez pulseaudio-utils python3-dbus python3-gi; do
	dpkg -s "$p" > /dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
	apt-get install -y --no-install-recommends "${need[@]}"
else
	echo "all there"
fi

echo "== the gadget"
if [ -e /sys/module/g_ipod_audio/parameters/streaming ]; then
	echo "g_ipod_audio keeps time on its own when the car takes no audio: good"
else
	echo "WARNING: the loaded g_ipod_audio is older than this (no 'streaming' parameter). Update"
	echo "ipod-gadget (git pull; sudo bash install-rpi.sh ~/ipod) and reboot, or PipeWire stalls"
	echo "whenever the car is not taking audio."
fi

echo "== $U: groups, start at boot without a login"
# first install only: what to restore on uninstall
[ -e "$STATE/linger-before" ] || { [ -e "/var/lib/systemd/linger/$U" ] && echo yes || echo no; } > "$STATE/linger-before"
echo "$U" > "$STATE/user"
# no login session means no seat ACL on /dev/snd: the groups give the access
for g in audio bluetooth; do
	if getent group "$g" > /dev/null; then
		usermod -aG "$g" "$U"
	fi
done
loginctl enable-linger "$U"

echo "== PipeWire / WirePlumber config"
install -D -m 644 "$HERE/pipewire/50-aucd-ipod.conf" /etc/pipewire/pipewire.conf.d/50-aucd-ipod.conf
install -D -m 644 "$HERE/wireplumber/50-aucd-ipod.conf" /etc/wireplumber/wireplumber.conf.d/50-aucd-ipod.conf
install -D -m 644 "$HERE/wireplumber/51-aucd-bluetooth.conf" /etc/wireplumber/wireplumber.conf.d/51-aucd-bluetooth.conf
# a default speaker picked by hand earlier would beat the iPod output's priority
st="$HOMEDIR/.local/state/wireplumber/default-nodes"
[ -f "$st" ] && sed -i '/^default\.configured\.audio\.sink/d' "$st"

echo "== PipeWire services for $U"
for _ in $(seq 1 30); do
	[ -S "/run/user/$UIDN/systemd/private" ] && break
	sleep 1
done
systemctl --user -M "$U@" daemon-reload || true
systemctl --user -M "$U@" enable pipewire.service pipewire-pulse.service wireplumber.service || true
systemctl --user -M "$U@" restart pipewire.service pipewire-pulse.service wireplumber.service || true

# full scale, like a real iPod: the car's volume knob sets the loudness (a new output starts
# at WirePlumber's 40 %); WirePlumber remembers it from now on
asuser() { runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$UIDN" "$@"; }
for _ in $(seq 1 30); do
	asuser pactl get-default-sink 2> /dev/null | grep -q snd_usb_ipod && break
	sleep 1
done
if asuser pactl get-default-sink 2> /dev/null | grep -q snd_usb_ipod; then
	asuser wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0
	asuser wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
	echo "iPod output is the default speaker, volume 100 %"
else
	echo "WARNING: the iPod output is not there yet (gadget modules not loaded?); after it is:"
	echo "  wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0   (as $U)"
fi

echo "== Bluetooth"
install -m 755 "$HERE/bin/aucd-bt" /usr/local/bin/aucd-bt
install -m 755 "$HERE/bin/aucd-audio-check" /usr/local/bin/aucd-audio-check
install -m 755 "$HERE/bin/aucd-audio-diag" /usr/local/bin/aucd-audio-diag
install -m 755 "$HERE/bin/ipod-desk-mode" /usr/local/bin/ipod-desk-mode
[ -f /etc/default/aucd-audio ] || install -m 644 "$HERE/aucd-audio.default" /etc/default/aucd-audio
install -m 644 "$HERE/systemd/aucd-bt.service" /etc/systemd/system/aucd-bt.service
systemctl daemon-reload
rfkill unblock bluetooth 2> /dev/null || true
systemctl enable --now bluetooth.service || true
systemctl enable aucd-bt.service
systemctl restart aucd-bt.service

echo
echo "installed. Reboot once (sudo reboot), then check with:   sudo aucd-audio-check"
echo "pair the phone:                                          sudo aucd-bt pair"
