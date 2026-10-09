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

```
git clone https://github.com/oandrew/ipod-gadget.git
cd ipod-gadget
sudo bash install-rpi.sh
sudo reboot
```

`install-rpi.sh` installs the kernel headers and DKMS (so the modules get rebuilt after every kernel update),
enables USB device mode (`dtoverlay=dwc2,dr_mode=peripheral` in `/boot/firmware/config.txt`)
and loads the modules at boot. Module options (`swap_configs`, `only_ipod`, `product_id`) go in `/etc/modprobe.d/ipod-gadget.conf`.

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






