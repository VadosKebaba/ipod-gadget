# Raspberry Pi 5: full (re)install

For a Pi 5 running Raspberry Pi OS 64-bit (Bookworm or Trixie), on a fresh install or over
an old one. Run everything on the Pi as your normal user (not root), with internet access.

The Pi 5's USB-C port is the only one that can act as a USB device, so that is the port
that goes to the head unit, and the Pi's power has to come from somewhere else (step 7).

## 1. Update the OS

So the running kernel matches the headers DKMS will fetch:

```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
```

## 2. Remove an old install (skip on a fresh Pi)

Saved traces in `/var/lib/ipod` are left alone. "not found" messages here are fine.

```bash
sudo systemctl disable --now ipod-client
sudo dkms remove ipod-gadget/1.0 --all
sudo rm -rf /usr/src/ipod-gadget-1.0 /usr/local/bin/ipod /etc/systemd/system/ipod-client.service /etc/default/ipod-client /etc/modprobe.d/ipod-gadget.conf /etc/modules-load.d/ipod-gadget.conf
sudo systemctl daemon-reload
```

Module copies from an old manual `make install` would shadow the DKMS ones. This should
print nothing; if it lists files, delete them and run `sudo depmod -a`:

```bash
find /lib/modules -name 'g_ipod_*.ko*' -not -path '*/dkms/*'
```

Keep the old checkouts aside:

```bash
cd ~ && mv ipod-gadget ipod-gadget.old; mv ipod ipod.old
```

## 3. Get the code and Go

```bash
sudo apt install -y git golang-go
cd ~ && git clone -b pi5-support https://github.com/VadosKebaba/ipod-gadget.git && git clone -b pi5-support https://github.com/VadosKebaba/ipod.git
```

The client is the fork of oandrew/ipod with `--hid=` (needed for the descriptor options
below). Optional check, every line should say `ok` (it replays a real car trace too):

```bash
cd ~/ipod && go test ./...
```

## 4. Install

Installs DKMS and the kernel headers, builds the modules (rebuilt on every kernel update),
turns on USB device mode (`dtoverlay=dwc2,dr_mode=peripheral` in
`/boot/firmware/config.txt`), loads the modules at boot, builds the client from `~/ipod`,
installs it with the `ipod-client` service, and writes fresh
`/etc/modprobe.d/ipod-gadget.conf` and `/etc/default/ipod-client`:

```bash
cd ~/ipod-gadget && sudo bash install-rpi.sh ~/ipod
sudo reboot
```

It ends with `installed /usr/local/bin/ipod, ipod-client.service starts at boot`.

## 5. Only if the head unit fails: client and descriptor options

The defaults need nothing. If authentication stops because the head unit's certificate
or signature packets arrive damaged (the trace shows them failing their checksum), let
the client accept them. A 2014 Infiniti Q60 needs exactly this and nothing else
([q60-notes.md](q60-notes.md)):

```bash
sudo sed -i 's/^IPOD_GLOBAL_ARGS=.*/IPOD_GLOBAL_ARGS="--lenient-auth"/' /etc/default/ipod-client
sudo systemctl restart ipod-client
```

The other options change the HID descriptor (*HID descriptor and speed* in the
[README](../README.md)); there the kernel option and the client flag always change
together. For example `bigout` (not tried on a car yet):

```bash
echo 'options g_ipod_hid hid_desc=bigout' | sudo tee -a /etc/modprobe.d/ipod-gadget.conf
sudo sed -i 's/^IPOD_GLOBAL_ARGS=.*/IPOD_GLOBAL_ARGS="--hid=bigout"/' /etc/default/ipod-client
sudo reboot
```

Several client options go in the same line, e.g. `IPOD_GLOBAL_ARGS="--hid=bigout --lenient-auth"`.

## 6. Check at the desk

| Command | Expected |
|---|---|
| `dkms status ipod-gadget` | `ipod-gadget/1.0, <kernel>, aarch64: installed` |
| `lsmod \| grep g_ipod` | `g_ipod_gadget`, `g_ipod_hid`, `g_ipod_audio` |
| `dmesg \| grep -e "HID descriptor" -e "max speed"` | `using default HID descriptor` (or the one you chose), `max speed full` |
| `cat /sys/module/g_ipod_hid/parameters/hid_desc` | `default` (or the one you chose) |
| `ls -l /dev/iap0` | exists |
| `aplay -l \| grep -i ipod` | the `iPodUSB` card |
| `ps -o args= -C ipod` | `/usr/local/bin/ipod -d serve -w /var/lib/ipod/ipod.trace /dev/iap0`, with `--hid=...` before `serve` if you set one |
| `/usr/local/bin/ipod --help \| grep -- --hid` | lists `--hid` (the forked client is installed) |

## 7. In the car

Power the Pi from a separate 5 V source through a VBUS-cut injector cable; car USB alone can't power a Pi 5.

Plug the Pi's USB-C into the car's USB port and select the iPod source, then:

```bash
cat /sys/class/udc/1000480000.usb/current_speed
journalctl -u ipod-client -f
```

`current_speed` says `full-speed` (or `high-speed` with `g_ipod_gadget high_speed=1`); the
journal shows the iAP traffic live. Traces are in `/var/lib/ipod`: `ipod.trace` is the
current run, older runs are kept as `ipod-<date>.trace` (`ls -lt /var/lib/ipod`). In a
trace, `<` lines come from the head unit, and their first byte is the report id. No `<`
lines at all after the head unit read the descriptor means it rejected the descriptor (or
the gadget's replies to it: `tools/hid-desc-check.c` checks them from a Linux PC).
Copy one to a PC with:

```bash
scp <user>@<pi-address>:/var/lib/ipod/ipod.trace .
```

## 8. Optional: the car as the Pi's speaker

So that everything the Pi plays goes to the car (Bluetooth from the phone, the browser,
AUCD's sounds), always on and with nobody logged in, plus the Pi as a Bluetooth speaker for
the phone: [extras/pi-audio](../extras/pi-audio/README.md).

```bash
cd ~/ipod-gadget && sudo bash extras/pi-audio/install.sh && sudo reboot
```

## Back to the default descriptor

```bash
sudo sed -i '/^options g_ipod_hid /d' /etc/modprobe.d/ipod-gadget.conf && sudo sed -i 's/^IPOD_GLOBAL_ARGS=.*/IPOD_GLOBAL_ARGS=""/' /etc/default/ipod-client && sudo reboot
```

## Updating

Rebuilds the modules and the client and keeps your config files:

```bash
cd ~/ipod && git pull && cd ~/ipod-gadget && git pull && sudo bash install-rpi.sh ~/ipod
```

## If something's wrong

- **No `/dev/iap0`, or `ls /sys/class/udc` is empty:** device mode isn't on. Check that
  `grep dwc2 /boot/firmware/config.txt` shows `dtoverlay=dwc2,dr_mode=peripheral`, then
  reboot. `dmesg | grep -i -e ipod -e dwc2` shows what the modules did.
- **`modprobe` says "Invalid argument":** a typo in `hid_desc=`; only `default`, `legacy`
  and `bigout` are accepted.
- **DKMS didn't build for the running kernel:**
  `sudo apt install linux-headers-$(uname -r) && sudo dkms autoinstall`, then reboot.
- **The client keeps restarting:** `journalctl -u ipod-client -b` says why.
