# Pi audio: the car is the Pi's speaker

Level 2 of the iPod side quest (2014 Infiniti Q60, Clarion X9U6, see
[../../doc/q60-notes.md](../../doc/q60-notes.md)). With this installed:

- the iPod output (g_ipod_audio's card `iPodUSB`) is the Pi's **default speaker, always
  on**: whatever plays on the Pi goes to the car (Bluetooth from the phone, Spotify,
  the browser, AUCD's own sounds), with no app configured for it;
- the Pi is a **Bluetooth speaker called "AUCD"** for the iPhone: paired once, on demand,
  and reconnected by itself after that;
- all of it **without anyone logged in** (the Pi in the car is headless);
- the car being **absent** (unplugged, key off, a different source selected, at home)
  never stalls anything, and the audio comes back by itself.

## Before: update ipod-gadget

The car-absent case needs the g_ipod_audio from the same commit as this directory (it keeps
time on its own when the car takes no audio, see *How it works*). On the Pi:

```bash
cd ~/ipod && git pull && cd ~/ipod-gadget && git pull && sudo bash install-rpi.sh ~/ipod && sudo reboot
```

Raspberry Pi OS **Trixie** (PipeWire + WirePlumber 0.5, the desktop image has them). On
Bookworm WirePlumber 0.4 ignores these config files.

## Install

```bash
cd ~/ipod-gadget && sudo bash extras/pi-audio/install.sh && sudo reboot
```

It installs (and keeps on update; running it again is the update):

| What | Where |
|---|---|
| 44.1 kHz graph | `/etc/pipewire/pipewire.conf.d/50-aucd-ipod.conf` |
| iPod output: default, always on, the graph's driver, 44.1 kHz S16 stereo | `/etc/wireplumber/wireplumber.conf.d/50-aucd-ipod.conf` |
| Bluetooth: speaker only (A2DP sink), no hands-free, works with no login | `/etc/wireplumber/wireplumber.conf.d/51-aucd-bluetooth.conf` |
| `aucd-bt` (pairing window, reconnect daemon), `aucd-audio-check`, `ipod-desk-mode` | `/usr/local/bin` |
| reconnect daemon | `aucd-bt.service` |
| name and pairing window length | `/etc/default/aucd-audio` |

plus, for your user: `loginctl enable-linger` (your services start at boot, logged in or
not), groups `audio` and `bluetooth` (no login, no seat permissions), PipeWire's user
services enabled, and the iPod output at 100 % volume (the car's knob sets the loudness, as
with a real iPod).

## Check

```bash
sudo aucd-audio-check
```

After a reboot, with nobody logged in, every line should be `OK`:

- `g_ipod_audio keeps time on its own ...` (otherwise: update ipod-gadget, above)
- `iPodUSB PCM running`, `opened at 44100 Hz`
- `linger on`, `pipewire / wireplumber / pipewire-pulse running`, `in group audio`
- `default speaker: alsa_output.platform-snd_usb_ipod...`, `state IDLE` or `RUNNING`
  (never `SUSPENDED`), `format s16le 2ch 44100Hz`, `volume 100 %`
- `graph rate 44100`, `the iPod output drives the graph`
- `bluetooth.service`, `aucd-bt.service running`, then the adapter: name `AUCD`,
  `visible False, pairable False`, `speaker (A2DP sink) offered: yes`
- hotspot band (see *Wi-Fi and Bluetooth*), `get_throttled 0x0`

`car taking audio right now: Y` only while the head unit plays the iPod source.

## Pair the iPhone

```bash
sudo aucd-bt pair
```

For 120 s the Pi is visible as **AUCD**: on the iPhone, Settings > Bluetooth > AUCD. No
code to type. The window closes as soon as the phone is paired and connected, and from then
on the Pi is invisible again and refuses new pairings; the phone is trusted and
`aucd-bt.service` connects to it whenever it is around (every 10 s for the first 3 minutes
after boot, then every minute). `aucd-bt status` shows the adapter, the phone and the codec.

If the phone was paired before and "forgot" the Pi: `sudo aucd-bt forget <address>` (from
`aucd-bt status`), then pair again.

If the iPhone also knows the car's own Bluetooth: pick AUCD in the iPhone's audio output
(AirPlay) menu once; the phone then keeps sending music to the Pi.

**Codec:** an iPhone sends SBC or AAC. AAC needs a PipeWire built with it; Debian's builds
and (so far) Raspberry Pi OS's are not, and `aucd-bt status` says which. SBC at the iPhone's
bitpool is fine through car speakers.

## Playing from the Pi itself

Anything run as your user plays to the car: `paplay`, `pw-play`, `mpv`, the browser,
`aplay -D default` (ALSA goes through PipeWire). For a systemd service: `User=` your user and
`Environment=XDG_RUNTIME_DIR=/run/user/<uid>`. Root's own processes don't reach your
PipeWire.

PipeWire now owns the card, so anything that opens `hw:` / `plughw:CARD=iPodUSB` directly
gets "Device or resource busy". That includes the earlier test command: use
`mpg123 -o pulse song.mp3` (or `-a default`) instead.

## Desk test with a Windows PC

The PC records the gadget's audio like a USB microphone, so you can hear the whole chain
(phone, Bluetooth, PipeWire, gadget) at the desk:

1. On the Pi: `sudo ipod-desk-mode on`. A PC always takes a USB device's first
   configuration, and the gadget's first one is a fake camera (PTP); desk mode offers only
   the iPod configuration. Power the Pi as in the car (its own supply through the VBUS-cut
   cable), USB-C to the PC.
2. Windows: Settings > System > Sound > More sound settings > **Recording** > the "iPod"
   microphone > Properties:
   - **Advanced**: default format **2 channel, 16 bit, 44100 Hz** (the gadget only sends
     44.1 kHz; at another rate it sounds wrong);
   - **Listen**: tick "Listen to this device", OK. Windows plays it through its speakers.
3. Play something on the Pi (`paplay /usr/share/sounds/alsa/Front_Center.wav`), or from the
   phone over Bluetooth.
4. **`sudo ipod-desk-mode off` before the car.** `aucd-audio-check` warns while it's on.

## Wi-Fi and Bluetooth

The Pi 5 has one 2.4 GHz radio for both. A hotspot on 2.4 GHz takes airtime from the phone's
audio stream, which can mean dropouts when the hotspot is busy. On 5 GHz they don't share
anything. `aucd-audio-check` shows the hotspot's band; to move it (the WLAN country must be
set, `sudo raspi-config` > Localisation; every iPhone does 5 GHz):

```bash
nmcli -t -f NAME,TYPE con show --active
sudo nmcli con modify "<hotspot connection>" 802-11-wireless.band a 802-11-wireless.channel 36
sudo nmcli con up "<hotspot connection>"
```

The second line drops every Wi-Fi client for a moment, an SSH session over the hotspot too.

## q60-pi-dash

With `data_source: obd` the dash's own Bluetooth service also names the adapter
(`bluetooth.name` in `config/config.yaml`, default "Q60 Pi Dash"): set it to `AUCD` so both
agree. It also keeps a pairing agent registered, but pairing still needs the adapter to be
pairable, which it only is during a window (`aucd-bt pair`, or the dash's "visible to
phones"). Merging this into the dash is the AUCD integration, later.

## Undo

```bash
sudo bash ~/ipod-gadget/extras/pi-audio/uninstall.sh && sudo reboot
```

Removes all of the above and turns linger off again if it was off before; paired phones and
group memberships stay. The g_ipod_audio change stays with ipod-gadget (it changes nothing
while the car takes audio).

## How it works

**The clock.** The car's isochronous requests are the iPod PCM's clock: each one takes 1 ms
of audio. When they stop (car absent, alt setting 0, bus suspended, or the car simply stops
polling for 20 ms), g_ipod_audio carries on with the system clock and drops the samples, like
a sound card with nothing plugged in. Before that, the PCM just stopped: ALSA writes failed
after about 0.4 s with "Input/output error", which is what mpg123's earlier
`wrote only 676 of 4608` was (the car had stopped taking audio, not clock drift), and
PipeWire would have stalled the whole graph with it. `cat
/sys/module/g_ipod_audio/parameters/streaming` says whether the car takes audio.

**The graph.** PipeWire runs at 44.1 kHz. The iPod output has the highest driver priority,
so the car's USB clock drives the graph and the phone's Bluetooth stream (which WirePlumber
gives 2010) follows it with adaptive resampling: nothing drifts against the car. The output
is never suspended or paused, so silence keeps flowing between songs.

**Headless Bluetooth.** WirePlumber normally starts Bluetooth only for a user logged in on a
seat; `monitor.bluez.seat-monitoring = disabled` drops that. Only the A2DP sink role is
offered: no hands-free (no microphone here, and the phone would route calls to the Pi
instead of the car's own Bluetooth). `aucd-bt` registers its pairing agent only for the
window.

## Tested

In a QEMU arm64 VM: the Raspberry Pi 6.18 kernel, Debian trixie with the same PipeWire
(1.4.2), WirePlumber (0.5.8) and BlueZ as Raspberry Pi OS Trixie, g_ipod_* on dummy_hcd
standing in for the car. install.sh, then a cold boot with nobody logged in:

- PipeWire up and the iPod output the default speaker about 18 s after power-on; it drove
  the graph at 44.1 kHz, and its PCM kept running when idle (silence flowing);
- car absent: a 6 s song took 6.4 s, nothing stalled; car streaming: 6001 of 6000 packets
  carried audio;
- a 15 s song through alt 1→0→1, the host not polling for 2 s and an unplug/replug took
  15.4 s, PipeWire never noticed, and streaming resumed after the replug;
- paplay, `aplay -D default` and two streams at once played; `plughw:CARD=iPodUSB` is busy;
- 0 PipeWire errors on the iPod output across three runs of all that;
- 10 minutes of continuous playback with one 5 s dropout: 600 s of audio, 0 errors with the
  23 ms of extra headroom in 50-aucd-ipod.conf (one run without it had 2 xruns, most likely
  the emulated CPU, which is far slower and jumpier than a Pi 5);
- without `51-aucd-bluetooth.conf` WirePlumber's Bluetooth monitors don't run at all with
  nobody logged in.

g_ipod_audio alone (busybox VM): every playback took its nominal time ±0.1 s with the host
absent, streaming, switching alt settings, not polling, and unplugged and replugged; the
previous driver failed each of those with "Input/output error" after 0.4 s. aucd-bt against a
mocked BlueZ (python-dbusmock): pairing window, timeout, reconnect, leaving others' windows
alone, the adapter coming back.

Not tested yet: a real phone over Bluetooth (pairing, A2DP, reconnect), the hotspot running
alongside, the Windows desk test, and 30 minutes in the car.

## Next: AVRCP bridge (design)

BlueZ exposes the phone's player as `org.bluez.MediaPlayer1` (`Track`: Title, Artist,
Album, Duration, TrackNumber, NumberOfTracks; `Status`, `Position`; `Play`, `Pause`,
`Next`, `Previous`). The iAP client takes its play state from a `Player` (VadosKebaba/ipod,
`cmd/ipod`); today that is `DevExtRemote`, a state of its own. A MediaPlayer1-backed
Player would:

- answer GetPlayStatus from Status / Position / Duration and GetCurrentPlayingTrackIndex /
  GetNumPlayingTracks from TrackNumber / NumberOfTracks;
- send the car's PlayControl (steering wheel, head unit buttons) to Play / Pause / Next /
  Previous on the phone;
- give the car screen the real song through `extremote.DeviceTrackInfo`;
- turn MediaPlayer1's property changes into PlayStatusChangeNotifications (track changed,
  playing / paused / stopped, position);
- fall back to `DevExtRemote` while no phone is connected.
