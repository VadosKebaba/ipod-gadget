# ipod-gadget
[![Join the chat at https://gitter.im/ipod-gadget/Lobby](https://badges.gitter.im/ipod-gadget/Lobby.svg)](https://gitter.im/ipod-gadget/Lobby?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)


ipod-gadget simulates an iPod USB device to stream digital audio to iPod compatible devices/docks.
It speaks iAP(iPod Accessory Protocol) and starts an audio streaming session.

Tested on Raspberry Pi Zero, Beaglebone Black and Nexus 5(mainline linux kernel) with Onkyo HT-R391 receiver as the host device (more host devices need to be tested).
Should work on any device that runs Linux 4.x (compiled with usb gadget configfs) and has a USB port that supports peripheral mode.


# implementation
It consists of two parts - linux kernel module and  client app (golang).
## kernel module
 
The kernel module takes care of the USB device gadget side. 
An iPod, when plugged in a dock, presents a USB configuration with 2 interfaces:
1. UAC1(USB Audio Class 1) - standart usb audio streaming interface.
2. HID - bidirectional transport for iAP packets.

The kernel module creates a new ALSA audio card "iPodUSB" for audio playback and iap0 char device for iAP communications.

The gadget driver is activated when the character device iap0 is opened and deregistered when it's closed.

## client app

The client app speaks to the host device over iAP by reading/writing packets from/to /dev/iap0 character device.
It handles the authentication and activates the audio streaming so that ALSA device can be used for playback.

# build and run


## kernel modules

```
git clone https://github.com/oandrew/ipod-gadget.git
cd ipod-gadget/gadget

make
# or cross compiling
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- KERNEL_PATH=/home/andrew/pi-linux 

#load the module
modprobe libcomposite
insmod g_ipod_audio.ko
insmod g_ipod_hid.ko
insmod g_ipod_gadget.ko [swap_configs=0] [product_id=0x1297]

#optional params
swap_config: swap USB configurations. 
Might be useful when the dock sees only the Mass Storage configuation.

product_id: override the usb product id.
See doc/apple-usb.ids for the list of ids

```

Check the messages from `dmesg` and verify that the device `/dev/iap0` is available.

## Raspberry Pi (Pi 5, also Zero / Zero 2 / 4) with Raspberry Pi OS

Step by step for a Pi 5, including reinstalling over an old setup: [doc/pi5-install.md](doc/pi5-install.md).

The [client app](https://github.com/oandrew/ipod) talks iAP to the head unit. Use the fork at
https://github.com/VadosKebaba/ipod (branch `pi5-support`): it adds `--hid=default|legacy|bigout`, which the
HID descriptor options below need. Either build it for the Pi on any machine with Go (`GOARCH=arm64` for
64-bit Raspberry Pi OS, which is what a Pi 5 runs) and copy the `ipod` binary over:

```
git clone -b pi5-support https://github.com/VadosKebaba/ipod.git
cd ipod
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./cmd/ipod
```

or clone it on the Pi and let the install script build it there (needs Go: `sudo apt install golang-go`).
Then on the Pi:

```
git clone -b pi5-support https://github.com/VadosKebaba/ipod-gadget.git
cd ipod-gadget
sudo bash install-rpi.sh /path/to/ipod        # the binary, or the client checkout to build
sudo reboot
```

`install-rpi.sh` installs the kernel headers and DKMS (so the modules get rebuilt after every kernel update),
enables USB device mode (`dtoverlay=dwc2,dr_mode=peripheral` in `/boot/firmware/config.txt`)
and loads the modules at boot. Module options (`swap_configs`, `only_ipod`, `product_id`, `hid_desc`, `high_speed`)
go in `/etc/modprobe.d/ipod-gadget.conf`, client options in `IPOD_GLOBAL_ARGS` in `/etc/default/ipod-client`.
Given the client, it installs it as `/usr/local/bin/ipod` with the `ipod-client` service, which keeps
`/dev/iap0` open from boot on (`journalctl -u ipod-client -f` shows the iAP traffic). Run it again with a new
binary or an updated checkout to update the client.
Each run's trace is kept in `/var/lib/ipod` (`ipod.trace` is the current one; older ones are renamed by date
and never overwritten): attach the one from the failing run when reporting a head unit problem.

### HID descriptor and speed

By default the gadget runs at full speed with a full speed HID descriptor whose largest output report
(head unit to gadget) carries 62 bytes of iAP data, so a longer message is split over several reports.
Some head units get that splitting wrong (see [doc/q60-notes.md](doc/q60-notes.md)). `g_ipod_hid hid_desc=`
picks the descriptor, and the client's `--hid=` has to name the same one, or it sends report ids the head unit
doesn't expect:

| `hid_desc=` (`g_ipod_hid`) | client | descriptor |
|---|---|---|
| `default` | `--hid=default` (or nothing) | full speed iPod descriptor, output reports up to 63 bytes |
| `legacy` | `--hid=legacy` | a real iPod's at high speed: output up to 255 bytes, input up to 767 (2-byte Report Count items) |
| `bigout` | `--hid=bigout` | `default` plus one 255-byte output report `0x0A` (1-byte items only) |

`legacy_hid=1` and the client's `--legacy` are the older spellings of `legacy`. A value `g_ipod_hid` doesn't
know makes `modprobe` fail rather than fall back silently.

`g_ipod_gadget high_speed=1` lets the gadget enumerate at high speed (480M) like a real iPod, if the head unit
does; full speed stays the default. Upstream made full speed the only option (fda808e) because some head units
pick the report layout from the connection speed and ignore the descriptor, so at high speed you will
normally want `legacy`.

For example, `bigout`:

```
# /etc/modprobe.d/ipod-gadget.conf
options g_ipod_hid hid_desc=bigout

# /etc/default/ipod-client
IPOD_GLOBAL_ARGS="--hid=bigout"
```

then `sudo reboot` (or reload the modules and `sudo systemctl restart ipod-client`).
`dmesg | grep -e "HID descriptor" -e "max speed"` shows what the gadget offers;
`cat /sys/class/udc/*/current_speed` shows what the head unit actually connected at
(`high-speed` / `full-speed`; on a Pi 5 the controller is `1000480000.usb`).

Whichever descriptor you pick, the gadget answers a head unit's GET_DESCRIPTOR with exactly the number of
bytes asked for, as upstream does: the Q60's head unit (below) disconnects otherwise. `tools/hid-desc-check.c`
checks that from a Linux PC.

### Damaged authentication packets: `--lenient-auth`

Some head units damage their certificate (`RetDevAuthenticationInfo`) or signature
(`RetDevAuthenticationSignature`) packets when they split them over HID reports, so they fail their checksum
and authentication stops. The client never verifies the certificate or signature anyway, so
`IPOD_GLOBAL_ARGS="--lenient-auth"` in `/etc/default/ipod-client` makes it accept those two packets when they are
short or fail their checksum (logged as `lenient: accepted damaged frame ...`). Every other packet stays strict.
Needs the VadosKebaba/ipod client; works with any descriptor. See [doc/q60-notes.md](doc/q60-notes.md).

The modules build against the Pi 5 kernels of Raspberry Pi OS Bookworm (6.12) and Trixie (6.18),
including the default 16K-page `rpi-2712` kernel. To cross compile for a Pi 5 instead,
prepare a [Raspberry Pi kernel tree](https://github.com/raspberrypi/linux) with `bcm2712_defconfig`, then:

```
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KERNEL_PATH=/path/to/rpi-linux
```

**Pi 5 wiring:** the only port of a Pi 5 that can be a USB device is the **USB-C power port**
(the USB-A ports are host only). Connect that port to the dock / car, and power the Pi 5 some other way,
e.g. 5 V into the GPIO header or a power HAT that feeds it: a dock's USB port can't supply a Pi 5 anyway.
Both the car's port and the Pi's supply put 5 V on VBUS, so a data-only adapter (VBUS not connected)
between them avoids tying the two supplies together; check on the bench that the head unit still detects the Pi that way.
Powered through the header, the Pi 5 limits its USB-A ports to 600 mA unless `usb_max_current_enable=1` is set in `config.txt`
(only with a supply that can deliver 5 A).

### When the head unit isn't taking audio

The iPodUSB card runs on the head unit's clock while it plays the iPod source, and on the
system clock otherwise (unplugged, key off, another source), dropping the samples, so a player
never blocks on it. `cat /sys/module/g_ipod_audio/parameters/streaming` says `Y` while the head
unit takes audio.

### The car as the Pi's speaker, Bluetooth from the phone

[extras/pi-audio](extras/pi-audio/README.md) makes the iPod output the Pi's default speaker,
always on, and the Pi a Bluetooth speaker for the phone, with nobody logged in (PipeWire /
WirePlumber config, a pairing tool, a reconnect service).

### Known to work: 2014 Infiniti Q60 (Clarion X9U6)

Plays music from a Pi 5 with the defaults (full speed, `hid_desc=default`, no module options) and
`IPOD_GLOBAL_ARGS="--lenient-auth"`: the head unit damages its certificate packets, and the client needs to
report *playing* after the head unit's PlayControl, or the head unit mutes and stops taking audio (the
VadosKebaba/ipod client does both). The Pi needs its own 5 V supply through a VBUS-cut cable, and one that
holds 5 V: the test run logged an undervoltage blip from the power bank. Details and the full session:
[doc/q60-notes.md](doc/q60-notes.md).

## client app

Follow the instructions here: https://github.com/oandrew/ipod

```
./ipod -d serve -w /tmp/ipod.trace /dev/iap0
```

Now you can open a different terminal and test the playback!

```
speaker-test -D plughw:CARD=iPodUSB,DEV=0 -c 2 -r 44100
```

Let me know if you have any issues.

Attach the trace file (e.g. `/tmp/ipod.trace` above) to the issue.

NOTE: currently it works only if the host device doesn't authenticate the iPod (typically only iPod authenticates the host device which is fine).






