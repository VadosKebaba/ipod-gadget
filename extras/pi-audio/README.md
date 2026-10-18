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
| 44.1 kHz graph, 512-sample cycle | `/etc/pipewire/pipewire.conf.d/50-aucd-ipod.conf` |
| iPod output: default, always on, the graph's driver, 44.1 kHz S16 stereo, 512 samples headroom | `/etc/wireplumber/wireplumber.conf.d/50-aucd-ipod.conf` |
| Bluetooth: speaker only (A2DP sink), no hands-free, works with no login | `/etc/wireplumber/wireplumber.conf.d/51-aucd-bluetooth.conf` |
| `aucd-bt` (pairing window, reconnect daemon), `aucd-audio-check`, `aucd-audio-diag` (delay, hiccups), `ipod-desk-mode` | `/usr/local/bin` |
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
- `graph rate 44100`, `graph cycle at least 512 samples`, `the iPod output drives the graph`
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

## Latency and start-up hiccups

Reported after several drives (2026-10-18): one or a few breaks right after the start, then
fine; and a constant delay of about 0.5 s. What follows comes from reading the source of
the PipeWire on the Pi (1.4.2) and g_ipod_audio; **the numbers are to verify on the Pi**
with the commands below.

### Where the delay comes from

| Stage | How much | What sets it | Measure |
|---|---|---|---|
| iPhone: encoder and send buffer | not visible from the Pi (iOS over A2DP: typically 100-200 ms, an estimate) | iOS | end to end, below |
| Bluetooth jitter buffer (PipeWire's bluez5 decode buffer) | 20 ms on a quiet radio, more with a busy one (ceiling ~370 ms) | adaptive: 1.5 x the worst gap between the phone's packets in the last 2 minutes, at least one cycle, in 20 ms steps | `aucd-audio-diag latency` |
| SBC decoding, resampling to the car's clock | 1-3 ms | | |
| iPod output (ALSA) | one to two graph cycles of 11.6 ms + headroom: 23-35 ms now, 35-46 ms before | `default.clock.quantum` (512; the phone's stream asks for 512 anyway), `api.alsa.headroom` | `delay:` in `/proc/asound/iPodUSB/pcm0p/sub0/status`; `pw-top` QUANT |
| g_ipod_audio's USB queue | 4 ms | 4 requests of 1 ms | |
| head unit | unknown, the same as with a real iPod | the Clarion | *Lip sync*, below |

So the Pi's share is about 55 ms with a quiet radio, more with a busy one (a packet 60 ms
late makes the jitter buffer 100 ms, for the next 2 minutes); the rest of the 0.5 s is the
iPhone and the head unit. The ALSA buffer in `hw_params`
(`buffer_size 16384`, 371 ms) is only the ceiling: PipeWire keeps about one cycle plus the
headroom in it. The resampling is not a buffer: the phone's stream follows the car's clock
by adjusting its rate, it adds a few samples.

### What changed (2026-10-18)

| Setting | Was | Now | Effect |
|---|---|---|---|
| `api.alsa.headroom` (wireplumber `50-aucd-ipod.conf`) | 1024 (23 ms) | 512 (11.6 ms) | 11.6 ms less delay; 1024 came from xruns in a QEMU VM, far slower than a Pi 5 (PipeWire's default on a Pi is 0) |
| `default.clock.quantum`, `min-quantum`, `max-quantum` (pipewire `50-aucd-ipod.conf`) | PipeWire's 1024 / 32 / 2048 | 512 / 512 / 512 | nothing while the phone plays (its stream asks for 512 anyway); the cycle no longer switches (from 1024 when idle, up to 2048 with a player on the Pi) when the phone starts or stops, and the Pi's own sounds get 512 too |
| `latency.internal.ns` (wireplumber `50-aucd-ipod.conf`) | 0 | 4 ms | no change in sound; the delay reported to the phone includes the USB queue |

About 12 ms less in all, which you won't hear: the Pi's settings are not where the 0.5 s
is. The one Pi-side lever that matters is the radio (the jitter buffer): a hotspot on 5 GHz
(*Wi-Fi and Bluetooth*, above) keeps it near its 20 ms minimum, and is also the first fix
for the hiccups.

Back to the old values: in `~/ipod-gadget/extras/pi-audio/wireplumber/50-aucd-ipod.conf` set
`api.alsa.headroom = 1024` (and/or delete the `latency.internal.ns` line), in
`.../pipewire/50-aucd-ipod.conf` delete the three `default.clock.*quantum` lines, then `sudo
bash ~/ipod-gadget/extras/pi-audio/install.sh` (it restarts PipeWire). Any time `pw-top`
shows ERR going up on the iPod output while driving, go back to 1024 and send me the
`aucd-audio-diag hiccup` file.

### Measure on the Pi

While the phone plays, as your user (with `sudo`, `aucd-audio-diag` finds the user itself):

```bash
aucd-audio-diag latency          # the Pi's share: jitter buffer, ALSA (sampled), USB queue, total
aucd-bt status                   # codec, and "delay reported N ms" (A2DP delay reporting, below)
pw-top                           # iPod output: QUANT 512, RATE 44100; ERR = xruns since PipeWire started
pactl list sinks | grep -E 'Name:|Latency:'
cat /proc/asound/iPodUSB/pcm0p/sub0/hw_params                    # the ALSA ceiling, not the delay
grep -E 'state|delay|avail' /proc/asound/iPodUSB/pcm0p/sub0/status # delay: frames queued right now
pw-dump > ~/pw-dump.json         # everything PipeWire knows, to send
```

End to end, in the car, with a second phone filming in slow motion (240 fps, 4.2 ms a frame):
GarageBand's drums on the iPhone, film the finger hitting a pad and listen for the drum.
(a) Bluetooth off, the iPhone's own speaker: its touch-to-sound time. (b) Through AUCD and the
car. (b) - (a) is the iPhone's A2DP sending + the Pi + the head unit. Optionally (c), the
phone on the car's own Bluetooth: if (c) is about (b), the Pi adds nothing a car's own
Bluetooth wouldn't.

### A2DP delay reporting and lip sync

Already on, nothing to switch on: PipeWire 1.4.2 registers its A2DP endpoints with
`DelayReporting` and, as the A2DP sink, sets BlueZ's `MediaTransport1.Delay` to the jitter
buffer's target plus everything after it in PipeWire (cycle, iPod output headroom,
`latency.internal.ns`) whenever that changes; BlueZ sends it to the phone as an AVDTP Delay
Report, if the phone asked for delay reporting (iPhones do; **to verify**). The report doesn't
make the sound earlier: the phone delays its video by it, for lip sync. Check:

```bash
aucd-bt status                                              # ... audio: SBC active, delay reported 85.3 ms
sudo btmon | grep -i -A3 'delay report'                     # while the phone starts playing; ctrl-c
```

What the Pi can't know is the head unit's own delay. To measure it and put it in the report:

1. On the iPhone, a lip-sync test video (YouTube, "audio video sync test": a flash and a
   beep), sound through AUCD to the car.
2. Film the iPhone's screen with the second phone in slow motion, the car's speakers audible.
   Count the frames from the flash to the beep: a beep after the flash is what the phone
   wasn't told about, i.e. mostly the head unit.
3. Add it to `latency.internal.ns` in `~/ipod-gadget/extras/pi-audio/wireplumber/50-aucd-ipod.conf`
   (beep 120 ms late: `4000000 + 120000000 = 124000000`), `sudo bash
   ~/ipod-gadget/extras/pi-audio/install.sh`, reconnect the phone, film again. `aucd-bt
   status` shows the larger delay. Tell me the number, so it goes into the repository too
   (install.sh copies the repository's file over `/etc`).

### Start-up hiccups: likely causes, most likely first

1. **The Bluetooth jitter buffer learning.** PipeWire starts it at one cycle rounded up to
   20 ms and only grows it after it runs dry: every packet later than the buffer covers is a
   break, after which the buffer is 1.5 x that gap, kept for 2 minutes. A few breaks, then
   fine, is exactly that. It starts from scratch whenever the stream (re)starts: after a
   connect, and after a pause long enough for the iPhone to suspend the stream (`aucd-bt
   status` then shows the transport `idle`; how long the iPhone waits is to verify).
   **Test:** pause the phone for 30 s in the middle of a drive and play again; breaks again
   means this. PipeWire 1.4 has no setting for it with A2DP (a fixed target exists only for
   LE Audio), so the fix is fewer late packets (2).
2. **Wi-Fi at start-up on the shared 2.4 GHz radio:** the hotspot coming up, clients joining,
   scans, the dash's traffic, all right when the jitter buffer is still small. **Test:** one
   drive with the hotspot on 5 GHz, or off (`sudo nmcli radio wifi off`).
3. **The car switching its audio interface (alt setting 0/1)** while it starts its iPod mode:
   g_ipod_audio carries on without stalling anything (tested in QEMU), but each switch is a
   gap in what the car plays. The kernel logs each: `ipod-gadget-audio: audio start` /
   `audio stop`.
4. **The Pi missing graph cycles at boot** (the browser and the dash starting, PipeWire
   itself): xruns on the iPod output, `pw-top` ERR going up, `XRun!` in PipeWire's log with
   logs on. Less likely on a Pi 5 with 11.6 ms cycles. PipeWire or WirePlumber starting
   late shows as no sound at first rather than breaks: the phone can't connect before
   WirePlumber offers the speaker.
5. **A2DP connect and codec negotiation** happen before any sound, so they delay the first
   sound rather than break it; a codec change in the middle (`phone: codec ...` in the iAP
   client's log) would restart the stream, and with it (1).

### Right after a hiccup

```bash
sudo aucd-audio-diag logs on     # once, at home: PipeWire at info (every xrun), the jitter buffer
                                 # once a second; restarts PipeWire, the phone reconnects by itself
# drive; right after a break (parked, or a passenger):
sudo aucd-audio-diag hiccup      # the last 3 minutes (hiccup 10: the last 10), saved to ~/aucd-hiccup-<time>.log
sudo aucd-audio-diag logs off    # when done (aucd-audio-check warns while it's on)
```

It collects the xrun counters (`pw-top` ERR of the iPod output and the phone's stream),
the iPodUSB PCM state, `get_throttled`, the load, `aucd-bt status`, and from the journal: the
kernel (`audio start` / `audio stop`, USB, the radio), PipeWire and WirePlumber, bluetoothd,
the iAP client's audio and codec lines, NetworkManager. By hand, the same:

```bash
sudo journalctl -k --since -3min -o short-precise | grep -iE 'ipod|dwc2|brcmf|bluetooth'
sudo journalctl _UID=$(id -u "$USER") _SYSTEMD_USER_UNIT=pipewire.service _SYSTEMD_USER_UNIT=wireplumber.service --since -3min -o short-precise
sudo journalctl -u bluetooth -u ipod-client -u NetworkManager --since -3min -o short-precise
pw-top -b -n 2 | grep -E 'snd_usb_ipod|bluez'
```

At the time of the break: `audio stop` / `audio start` is the car (3); ERR up or `XRun!`
is the Pi (4); WirePlumber's `target:` / `spike:` jumping with no xrun is late Bluetooth
packets (1, 2); Wi-Fi events in the same second point at the radio (2).

### To verify on the Pi

- `sudo aucd-audio-check`: all `OK` as before, plus `graph cycle at least 512 samples`;
  `pw-top` shows QUANT 512 on the iPod output with and without the phone playing.
- `aucd-audio-diag latency` while the phone plays: the jitter buffer's target, ALSA queued
  about 23-35 ms, and `aucd-bt status` showing `delay reported`.
- A drive of 30 minutes or more: ERR of the iPod output in `pw-top` stays 0 with headroom 512.
- `sudo btmon` shows the Delay Report; with logs on, WirePlumber's journal has a `target:`
  line once a second while the phone plays.
- The car-absent case is untouched (g_ipod_audio didn't change; the cycle and headroom don't
  matter while it keeps time itself), but the QEMU test wasn't rerun.

Tested in a cloud session (no Pi, car, phone or sound card): the configs load without errors
in PipeWire 1.4.7 / WirePlumber 0.5.10 (Ubuntu 25.10 chroot), `pw-metadata -n settings` shows
quantum 512 / min 512 / max 512 and a stand-in sink named like the iPod output runs at 512;
`aucd-audio-diag latency`, `hiccup` and `logs on|off` run against the real `pw-dump` /
`pw-top` output; a `log.level` pattern in a WirePlumber conf.d file turns on debug for a SPA
plugin loaded later (the bluez5 topic itself is to verify on the Pi).

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

## Level 3: the phone on the car's screen and buttons (AVRCP bridge)

Branch `level3-wip` of both repos. The iAP client (VadosKebaba/ipod) reads the phone's
player from BlueZ (`org.bluez.MediaPlayer1`, AVRCP) and tells the car about it instead of
its Level 2 stub:

- the car's iPod screen shows the phone's **title, artist and album** (`--text=asis`, the
  default, or `--text=translit` for Cyrillic in Latin letters; at most `--text-max` bytes,
  default 200);
- **playing / paused** and the **time** come from the phone (stopped is told as paused);
- the car's **next / previous** (steering wheel, head unit) skip on the phone, **play /
  pause** (the only one the X9U6 sends is toggle) play and pause the phone;
- with **no phone** (none connected, or no media player on it) the Level 2 stub answers,
  playing, as before; the switch either way is logged (`player: ...`).

The car's requests are always answered from a cache, never by waiting for BlueZ. Every
PlayControl from the car is logged with the car's streaming state and the phone's status
before and after, then again 300 ms and 1.5 s later:

```
phone: PlayControl toggle (1): car streaming N, phone playing -> paused, action Pause (toggle, the phone plays)
phone: after PlayControl toggle (1) +300ms: phone paused, car streaming N
```

**The source-leave rule** (`--toggle-guard`, on by default): the car sends a toggle when it
leaves the iPod source (FM, audio off) and when it comes back. A toggle while the car takes
no audio (`streaming N`) may pause the phone but never starts it, so leaving the source with
the phone paused doesn't start it under the FM. Explicit play (10) is never blocked.
**Watch for this in the car:** since the car stops taking audio while it's told *paused*, a
resume from the car's own play/pause button may also arrive with `streaming N` and be
refused (`action none (toggle while the car takes no audio never starts the phone)`). If
that happens, `--toggle-guard=false` (below) makes every toggle follow the phone.

Without track numbers from the phone the car sees a list of 4 with the current track at 2 or
3, alternating on every track change (never at an end, so next and previous always work,
and a car that keeps titles by index asks again). With the phone's numbers (`TrackNumber` of
`NumberOfTracks`, at least 2) it sees those.

### Install (needs internet once: the client now uses github.com/godbus/dbus/v5)

```bash
cd ~/ipod && git fetch origin && git checkout level3-wip && git pull --ff-only && go mod download
cd ~/ipod-gadget && git fetch origin && git checkout level3-wip && git pull --ff-only
cd ~/ipod && CGO_ENABLED=0 go build -o /tmp/ipod ./cmd/ipod && /tmp/ipod lingos > /dev/null && \
  sudo install -m 755 /tmp/ipod /usr/local/bin/ipod
sudo install -m 755 ~/ipod-gadget/extras/pi-audio/bin/aucd-bt /usr/local/bin/aucd-bt
sudo systemctl restart ipod-client
journalctl -u ipod-client -b | grep -E 'player:|phone:' | tail
```

(`sudo bash ~/ipod-gadget/install-rpi.sh ~/ipod && sudo bash
~/ipod-gadget/extras/pi-audio/install.sh` does the same and more: it also rebuilds the
kernel modules, which haven't changed.) `/etc/default/ipod-client` stays as it is:
`IPOD_GLOBAL_ARGS="--lenient-auth"`; the new flags default to `--player=auto --text=asis
--text-max=200 --toggle-guard`.

### Desk test (phone connected over Bluetooth, no car needed)

```bash
aucd-bt status       # the phone Connected, audio: SBC active
aucd-bt now          # phone, codec, playing, title/artist/album, "head unit: phone, ..."
aucd-bt next         # the phone skips; "after:" shows the new title and track 3 of 4 (or n+1 of m)
aucd-bt prev
aucd-bt pause        # the phone pauses; "head unit: phone, paused"
aucd-bt play         # it plays again
aucd-bt toggle       # pauses (the phone plays)
aucd-bt toggle       # without the car: "streaming N", so the guard refuses to start it:
                     #   action none (toggle while the car takes no audio never starts the phone)
aucd-bt watch        # change songs on the phone: a line each time, within a second; ctrl-c
```

Cyrillic on the car's font, without a phone (in the car, the stub answers with these names;
systemd doesn't keep quotes in `IPOD_GLOBAL_ARGS`, so run it by hand):

```bash
sudo systemctl stop ipod-client
sudo /usr/local/bin/ipod -d --lenient-auth --player=stub \
  --demo-track "Группа крови — очень длинное название для проверки экрана|Кино|Группа крови" serve /dev/iap0
# ctrl-c, then the same with --text=translit to compare; sudo systemctl start ipod-client after
```

### Car checklist

Before the drive: `aucd-bt now` shows the phone, `journalctl -u ipod-client -f` in an SSH
session if possible (or read it afterwards with `journalctl -u ipod-client -b`).

1. iPod source: the car's screen shows the phone's title / artist / album, and the time
   runs. Long or Cyrillic names: what does the screen show (font, cut)?
2. Next / previous on the steering wheel and the head unit: the phone skips, the screen
   follows within a second or two.
3. Play/pause from the iPod screen and the joystick: the phone pauses, **and resumes**. If
   resume does nothing, look for `action none (toggle while the car takes no audio ...)` in
   the journal: then the guard is in the way (try `--toggle-guard=false`).
4. Leave the source (FM), with the phone playing: the phone pauses. Come back: it resumes.
   Leave with the phone **paused**: it must stay paused under FM. Note the streaming state
   in each PlayControl line.
5. Pause and change tracks from the phone itself: the car's screen follows.
6. Turn the phone's Bluetooth off: the car keeps playing the Pi's audio from the stub
   (`player: no phone player, the stub answers`), and back to the phone when it reconnects.
7. Afterwards, send `journalctl -u ipod-client -b > level3-car.log` (and
   `/var/lib/ipod/ipod-*.trace`): it answers the open questions: whether the car enables
   PlayStatusChangeNotifications (`SetPlayStatusChangeNotification`), which track indexes it
   asks for, whether it sends GetArtworkFormats / GetTrackArtwork*.

### Rollback

No code change needed, either:

```bash
# the stub again (Level 2 answers), keeping the new client
sudoedit /etc/default/ipod-client      # IPOD_GLOBAL_ARGS="--lenient-auth --player=stub"
sudo systemctl restart ipod-client
# or keep the phone and only make toggles follow it: --toggle-guard=false
```

or back to exactly what ran in the car on 2026-10-18 (tag `q60-level2-good`, both repos):

```bash
cd ~/ipod && git fetch --tags && git checkout q60-level2-good && cd ~/ipod-gadget && git fetch --tags && git checkout q60-level2-good && sudo bash install-rpi.sh ~/ipod && sudo bash extras/pi-audio/install.sh && sudo reboot
```

### Tested (in a cloud VM, no Pi, car or iPhone)

- Unit tests with a fake BlueZ: the switch between stub and phone and its notifications,
  toggle decided from a fresh read (stale cache), the guard, the command mapping, the track
  index rules, the position from a fake clock, the stale cache, the text modes and cap.
- End to end through the client's frame loop: the car's PlayControl next reaches
  `MediaPlayer1.Next`, GetIndexedPlayingTrackTitle / ArtistName answer the phone's names,
  the track index moves.
- `ipod bt now/next/prev/play/pause/toggle/watch` (linux/amd64) against python-dbusmock's
  BlueZ with a hand-made iPhone player (`cmd/ipod/scripts/bt-dbusmock-test.py` in the
  client): 16 checks; `watch` sees a track change 0.02 s after BlueZ's signal; no phone, the
  phone disconnecting and bluetoothd gone all fall back to the stub.
- Built for linux/arm64 (`CGO_ENABLED=0`); `go vet` and `go test -race` pass.

**To verify on the Pi:** the real BlueZ and iPhone (the property types, AVRCP's track numbers,
how fast the iPhone reports changes), and a long Cyrillic title through the real gadget (a
multi-report iPod→car frame; the QEMU fakecar test of the previous sessions wasn't rerun).

## Level 4, step 1: album art (a test picture)

The X9U6 asks for artwork formats on every connect. The client can now offer album art: for
now **one picture for every track** (the phone doesn't send covers over Bluetooth here yet:
BlueZ shows no `ImgHandle`), to find out whether and how the car shows it. Off unless
`--artwork` is given.

```bash
cd ~/ipod && git pull --ff-only && CGO_ENABLED=0 go build -o /tmp/ipod ./cmd/ipod && \
  sudo install -m 755 /tmp/ipod /usr/local/bin/ipod
sudoedit /etc/default/ipod-client   # add --artwork=test, e.g.
                                    # IPOD_GLOBAL_ARGS="--lenient-auth --toggle-guard=false --artwork=test"
sudo systemctl restart ipod-client
journalctl -u ipod-client -b | grep -E 'player:' | tail -1   # ... artwork test 565le, format 1 128x128, format 2 240x240
```

First car test (2026-10-18): the car shows the art, colours and orientation right, but it
keeps only the first USB report of each picture packet, so the first client build drew thin
diagonal stripes on junk. The client now sends one report per packet (`--artwork-chunk` to
override); update the client if the square comes out striped.

In the car, on the iPod screen, look for a square: **red top left, green top right, blue
bottom left, white bottom right**, in a thin black frame.

- **Right colours:** the car side works. A real picture instead:
  `--artwork=/var/lib/ipod/cover.jpg` (a PNG or JPEG, full path; cropped to a square,
  scaled down). A wrong path or a file that isn't a picture only costs the picture: the
  client logs `--artwork: ...: no artwork` and runs on as before.
- **Wrong colours** (e.g. red and blue swapped, or noise): `--artwork-pixel=565be`.
- **Mirrored or rotated:** tell me which way.
- **Nothing:** send the log; it shows what the car asked for (`GetTrackArtworkData`,
  `GetTrackArtworkTimes`, `GetIndexedPlayingTrackInfo`) and `artwork: sent ... in ... ms`.

A picture takes about 0.6 s (128×128) or 2 s (240×240) to send, logged each time; the car
picks the size. Off again: take `--artwork=...` out and restart.

```bash
journalctl -u ipod-client -b --no-pager | grep -E 'Artwork|artwork|TrackInfo' > ~/level4.log; wc -l ~/level4.log
```

Step 2, the phone's own covers, needs AVRCP cover art from BlueZ (or a lookup online).
