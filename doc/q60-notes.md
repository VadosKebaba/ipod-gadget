# 2014 Infiniti Q60 — Clarion X9U6 head unit

**It works.** Car test #6 (2026-10-17) played music through the car's speakers from
the Pi: default HID descriptor at full speed (no module options) and the client with
`--lenient-auth`. The head unit damages its authentication packets, the client
accepts them anyway, and from there on everything runs (sequence under test #6).

Raw HID trace of the session that failed before `--lenient-auth`:
[traces/q60-clarion-x9u6-auth-fail.trace](traces/q60-clarion-x9u6-auth-fail.trace)
(`<` head unit → gadget, `>` gadget → head unit; `ipod view <file>` decodes it).

## What the trace shows

The head unit sends its `RetDevAuthenticationInfo` (a 251-byte iAP frame) as four
SET_REPORTs with report id `0x09`, the largest output report of the default full
speed descriptor: 63 bytes, i.e. one link control byte and 62 bytes of the frame.
It splits the frame wrongly in two ways:

- the **middle reports carry link control `0x02`** (first report, more to follow)
  instead of `0x03` (continuation, more to follow);
- each **middle report is 2 bytes short**: the head unit advances 64 bytes through
  the frame per report, but only 62 fit, so 2 bytes are lost at each of those
  boundaries.

Putting the 4 missing bytes back makes the frame's iAP checksum come out right
(`0x09`), which is what shows the bytes were dropped by the head unit rather than
misread on our side. The frame carries the head unit's certificate (DER), which
shows exactly where they went: the boundary after the first report is intact
(`30 82 02 | 41 A0 03 02 01 02`), and `13 0A` is missing after the second report
(`06 03 55 04 0A | 13 0A | "Apple Inc."`) and `41 70` ("Ap") after the third
(`13 2E | 41 70 | "ple iPod Accessories ..."`). The frame is section 0 of 3
(`CertCurrentSection 0`, `CertMaxSection 3`), so a full authentication sends four.

Everything before it in the trace works: StartIDPS, GetiPodOptionsForLingo,
SetFIDTokenValues (99 bytes, correctly split over two reports, `0x02` then `0x01`;
it names the head unit `CarNavigationSystem`, Clarion, X9U6), EndIDPS and
GetDevAuthenticationInfo.

Either fault alone breaks the message. The first one is handled now: the client
(VadosKebaba/ipod, pi5-support) reads a `0x02` report that arrives mid-frame as a
continuation, so replaying this trace now yields the 248 bytes as one frame (before,
it kept only the last 124) — which then fails its checksum, as it must
(`hid/testdata` in the client repo, `TestQ60ClarionTrace`). The bytes the head unit
never sent can't be recovered. Two ways out: give it nothing to split (a descriptor
whose output report holds the whole frame, tests #3–#5, which never really ran), or
don't need those bytes (`--lenient-auth`, test #6, which works).

## The regression behind tests #3–#5: they are INVALID

Tests #3, #4 and #5 ran on builds from c1df104 (the `legacy_hid` commit) up to
a73924a, and c1df104 also changed how the HID interface answers GET_DESCRIPTOR. That
change, not the descriptors under test, is what the head unit rejected.

Upstream answers any GET_DESCRIPTOR on the interface, whatever type is asked for,
with the report descriptor, and always exactly wLength bytes: if wLength is larger
than the descriptor, the rest is whatever the ep0 buffer holds. c1df104 cut the reply
to the descriptor's own size (96 bytes for the default one), which is what the USB
spec asks for and what a Linux host never notices, because usbhid asks for exactly the
size the HID class descriptor gives. The X9U6 does this:

1. GET_DESCRIPTOR `0x21` (HID class descriptor), wLength 9. It gets the first 9 bytes
   of the report descriptor, `06 00 ff 09 01 a1 01 75 08`, and reads bytes 7–8 as the
   report descriptor's length: `0x0875` = 2165 bytes.
2. GET_DESCRIPTOR `0x22` (report descriptor), wLength 2165. Upstream and a110586:
   2165 bytes. c1df104 to a73924a: 96 bytes. The head unit suspends about 6 ms later
   and disconnects ("Check USB memory or iPod").

That reply length was the only difference a full speed host could see between
a110586 and a73924a with all defaults (device, configuration, `0x21` and `0x22`
replies compared in the QEMU rig with dummy_hcd), so every one of those builds was
rejected whatever the descriptor, and tests #3, #4 and #5 tested that bug. Car test #6
ran on a110586 (tag `q60-known-good`).

Fixed in 3d962f8: the reply is again exactly wLength bytes for every
request and every descriptor, and with the default descriptor all four replies are
byte for byte those of a110586, including the 2165-byte one.
[tools/hid-desc-check.c](../tools/hid-desc-check.c) checks the raw replies from a
Linux PC with the Pi plugged in (PASS / FAIL): it fails on a73924a and passes on the
fix.

What this leaves for the descriptors: the X9U6 has never really been shown `legacy`
or `bigout`, so whether it would take them is unknown. They are not needed any more,
since `--lenient-auth` gets past the damaged frames; keep `hid_desc=default`.

## Test #3: legacy descriptor at full speed — INVALID (broken build)

*Ran on a build with the GET_DESCRIPTOR regression above: the rejection says nothing
about the descriptor.*

`hid_desc=legacy` (then `legacy_hid=1`) offers a real iPod's descriptor, whose largest
output report (`0x15`) holds 254 bytes, so the 251-byte frame would fit in one report.
The X9U6 read the HID report descriptor (control request `81 06`, wValue `0x2200`),
suspended and disconnected about 6 ms later, retried once, then showed "Check USB
memory or iPod". No SET_REPORT at all, empty trace.

## Test #4: legacy descriptor at high speed — INVALID (broken build)

*Same regression, same rejection.*

A real iPod sends that descriptor at high speed, so the next test added
`high_speed=1`. The head unit did enumerate at high speed (`current_speed` =
`high-speed`, dmesg "new device is high-speed" twice), so the cable chain carries it,
and then disconnected exactly as in test #3. The only thing this test does show is
that the car and the cable chain do high speed.

Background on speed: upstream ran at high speed with the legacy descriptor until 2020,
moved to the full speed descriptor in 5986675 (fixing hangs after
`GetDevAuthenticationInfo` on some devices), and forced full speed in fda808e (2025)
because a Ford Sync 2 at high speed used the real iPod's report layout regardless of
the descriptor (oandrew/ipod-gadget#28). `high_speed=1` stays available, off by default.

## Hypothesis: 2-byte Report Count items — untested

The legacy descriptor declares its input reports `0x09`–`0x0C` (257 to 767 bytes) with
2-byte Report Count items (`0x96 xx xx`); the default one uses only 1-byte ones
(`0x95 xx`). The idea was that a minimal HID parser in the head unit might fail on the
2-byte form. Test #5 was meant to check it but ran on the broken build, so this was
never tested either way. The head unit does read the report sizes: with the default
descriptor it always picked the smallest output report that fits (`0x06` for short
frames, `0x09` for long ones).

## Test #5: default + one big output report (`bigout`) — INVALID (broken build)

*Same regression, same rejection.*

`hid_desc=bigout` is the default descriptor byte for byte plus one Output report
`0x0A` of 255 bytes, written with a 1-byte Report Count (`0x95 0xff`), with the client
on `--hid=bigout`. Rejected like #3 and #4: descriptor read, suspend about 6 ms later,
retry, "Check USB memory or iPod".

The conclusion drawn from #3–#5 at the time, "the X9U6 takes the default descriptor
and nothing else", is **retracted**: all three failures were the regression.

## Test #6: `--lenient-auth` — SUCCESS, music plays

We are the iPod, and the client never verifies the accessory's certificate or
signature: it collects the certificate sections, acknowledges them, and answers the
signature with "passed". What it acts on (lingo `0x00`, command `0x15` or `0x18`,
transaction, version, `CertCurrentSection`/`CertMaxSection`) is all in the first HID
report, which the head unit never damages; the 2-byte losses only hit certificate and
signature data.

`ipod --lenient-auth` (VadosKebaba/ipod, pi5-support) therefore accepts
`RetDevAuthenticationInfo` (`0x15`) and `RetDevAuthenticationSignature` (`0x18`)
packets that arrive short (padded with zeros to their declared length) or with a bad
checksum, and logs each one:
`lenient: accepted damaged frame cmd=0x15 got=248 want=251 chk=bad`. Every other
command stays strict, so it never acts on a damaged packet of any other kind.

Two packet-layer bugs were fixed along the way, flag or not: a truncated packet was
completed from stale bytes of the buffer behind it (and could crash the client), and
after a bad packet the reader searched inside it for the next start byte (`0x55`,
which a certificate contains), so it could act on bytes nobody sent as a command.

**What ran:** gadget a110586 (before the regression), default descriptor, full speed,
no module options; client d31ab0a with `--lenient-auth` and one hand edit,
GetPlayStatus answering *playing* instead of the stub's *paused* (both tagged
`q60-known-good`). The sequence:

1. **IDPS:** StartIDPS, GetiPodOptionsForLingo, SetFIDTokenValues, EndIDPS, as in the
   trace.
2. **Authentication, lenient:** the certificate in 4 sections, then the signature; the
   damaged frames accepted (`lenient: accepted damaged frame ...` in the journal). The
   one `ERRO` line about parsing the certificate (x509 / asn1) is harmless: the client
   only reads it for its log. AckDevAuthenticationStatus: passed.
3. **Extended Remote browsing:** the car shows Status > iPod, with the placeholder
   title, artist and album.
4. **Digital audio:** GetAccSampleRateCaps → TrackNewAudioAttributes 44100 Hz → AccAck.
5. **PlayControl** (play) from the car.
6. **set_alt(1,1):** the head unit opens the audio streaming interface, the gadget
   logs `audio start`, and there is sound.

The last blocker was step 5. The client's GetPlayStatus stub always said *paused at
0:20*; after PlayControl the car kept seeing paused, muted, and stopped reading the
isochronous endpoint (the player on the Pi blocked, PCM RUNNING with a full buffer).
Answering *playing* fixed it. The client now keeps a real play state (VadosKebaba/ipod
2998f7d): playing on connect, PlayControl play / pause / toggle / stop / next / prev,
the position follows the clock while playing (the car's timer runs), and
PlayStatusChangeNotifications when the head unit enables them.

**Power:** the Pi reported a brief undervoltage from its power bank during the test.
The Pi 5 runs from its own 5 V source here (the car's USB port can't power it, and the
injector cable cuts VBUS), so that source has to hold 5 V under load: if the iPod ever
drops off mid-drive, check `vcgencmd get_throttled` (`0x0` = never undervolted since
boot) and `dmesg | grep -i voltage` before suspecting the software.

Config, from now on:

```
# /etc/modprobe.d/ipod-gadget.conf: no "options g_ipod_hid" line, no high_speed

# /etc/default/ipod-client
IPOD_GLOBAL_ARGS="--lenient-auth"
```

## Status

- 2026-10-17: `legacy_hid=1` added. Test #3 (legacy, full speed): rejected — INVALID.
- 2026-10-17: `high_speed=1` added. Test #4 (legacy, high speed): rejected — INVALID.
- 2026-10-17: `hid_desc=bigout` + client `--hid=bigout`; the client tolerates `0x02`
  mid-frame. Test #5 (bigout, full speed): rejected — INVALID.
- 2026-10-17: client `--lenient-auth`, packet layer fixes. Test #6 on a110586 with
  the client answering *playing*: **success, music plays.**
- 2026-10-17: the GET_DESCRIPTOR regression (c1df104) found and fixed, which
  invalidates tests #3–#5; `tools/hid-desc-check.c`. Client play state and
  notifications (2998f7d). Next car run: current pi5-support heads of both repos with
  `--lenient-auth`.
- 2026-10-18: Level 2 in the car (tag `q60-level2-good`): iPhone → A2DP (SBC) → PipeWire →
  gadget → X9U6 → Bose, end to end. The power problem was the power bank browning out;
  fixed with a 12 V → 5 V 3 A supply.
- 2026-10-18: Level 3 (AVRCP bridge) on `level3-wip` of both repos, not yet in the car:
  see *The car's controls* below and [../extras/pi-audio/README.md](../extras/pi-audio/README.md).

## The car's controls (Level 2 logs, 2026-10-18)

What the X9U6 sends over the Extended Remote lingo, from the client's journal:

- **Next / previous:** PlayControl 3 / 4 (steering wheel up/down, head unit buttons).
- **Pause / resume:** only PlayControl 1 (toggle), never 10 (play) or 11 (pause): from the
  iPod screen's play/pause button, the steering-wheel joystick push while play/pause is
  highlighted, and **automatically when leaving or returning to the iPod source** (FM,
  audio off).
- While the client reports *paused*, the car stops taking audio (alt setting 0; the gadget
  drops samples cleanly since Level 2, `streaming` reads `N`).

Level 3 (VadosKebaba/ipod `level3-wip`) maps these onto the phone's AVRCP player through
BlueZ: 3 / 8 / 12 → Next, 4 / 9 / 13 → Previous, 10 and 7 → Play, 11 and 2 → Pause, 5 / 6 →
FastForward / Rewind, and toggle → Pause if the phone plays, else Play, decided from a fresh
read of the phone. **Source-leave rule** (`--toggle-guard`, default on): a toggle while the
car takes no audio may pause the phone but never starts it. Every PlayControl is logged with
the car's streaming state and the phone's status before and after.

Open questions for the first Level 3 car run (answers in the journal and the trace):

- Does a toggle on *returning* to the source, or from the play button while paused, arrive
  before or after the car takes audio again? If it arrives with `streaming N`, the guard
  refuses to resume the phone from the car: then `--toggle-guard=false`, or a better rule
  from the logged order.
- Does the X9U6 enable PlayStatusChangeNotifications (`SetPlayStatusChangeNotification` in
  the journal)? Without them it has to poll for track changes.
- Does it keep titles by track index? The client shows a 4-track list with the current
  track alternating between 2 and 3 when the phone gives no track numbers, so either way it
  asks again.
- What does its font do with Cyrillic and with long names (`--text`, `--text-max`)?
- Level 4 (album art): GetColorDisplayImageLimits is the accessory asking for the *iPod's*
  screen size (to upload a logo with SetDisplayImage); artwork to the car would be
  GetArtworkFormats / GetTrackArtworkTimes / GetTrackArtworkData. Check whether it sends
  those (the client answers GetArtworkFormats with an empty list today).
