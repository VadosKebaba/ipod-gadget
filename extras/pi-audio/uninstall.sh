#!/bin/bash
# ipod-gadget extras/pi-audio: undo install.sh. Paired phones and the group memberships stay.
#   sudo bash extras/pi-audio/uninstall.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
STATE=/var/lib/aucd-audio
U=$(cat "$STATE/user" 2>/dev/null || echo "${SUDO_USER:-}")

systemctl disable --now aucd-bt.service 2> /dev/null
rm -f /etc/systemd/system/aucd-bt.service
systemctl daemon-reload

[ -e /etc/modprobe.d/ipod-gadget-desk.conf ] && /usr/local/bin/ipod-desk-mode off
rm -f /usr/local/bin/aucd-bt /usr/local/bin/aucd-audio-check /usr/local/bin/ipod-desk-mode
rm -f /etc/pipewire/pipewire.conf.d/50-aucd-ipod.conf \
	/etc/wireplumber/wireplumber.conf.d/50-aucd-ipod.conf \
	/etc/wireplumber/wireplumber.conf.d/51-aucd-bluetooth.conf
rm -f /etc/default/aucd-audio

if [ -n "$U" ] && id "$U" > /dev/null 2>&1; then
	systemctl --user -M "$U@" restart pipewire.service pipewire-pulse.service wireplumber.service 2> /dev/null
	if [ "$(cat "$STATE/linger-before" 2>/dev/null)" = no ]; then
		loginctl disable-linger "$U"
		echo "linger off again for $U"
	fi
fi
rm -rf "$STATE"
echo "removed; PipeWire is back to its defaults (reboot to be sure)"
