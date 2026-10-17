# 2014 Infiniti Q60 — Clarion X9U6 head unit

The factory head unit enumerates the gadget at full speed and starts iAP, then
fails at **authentication**. Raw HID trace of the failing session:
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
never sent can't be recovered, so the way out is to give it nothing to split: a
descriptor whose output report holds the whole frame.

## Test #3: legacy descriptor at full speed — rejected

`hid_desc=legacy` (then `legacy_hid=1`) offers a real iPod's descriptor, whose largest
output report (`0x15`) holds 254 bytes, so the 251-byte frame would fit in one report.
The X9U6 does not accept it: it reads the HID report descriptor (control request
`81 06`, wValue `0x2200`), suspends and disconnects about 6 ms later, retries once,
then shows "Check USB memory or iPod". No SET_REPORT at all, empty trace. With the
default descriptor it starts IDPS less than a second after the same read.

## Test #4: legacy descriptor at high speed — rejected the same way

A real iPod sends that descriptor at high speed, so the next test added
`high_speed=1`. The head unit did enumerate at high speed (`current_speed` =
`high-speed`, dmesg "new device is high-speed" twice), so the cable chain carries it,
and then rejected the descriptor exactly as in test #3.

So **speed is irrelevant: the X9U6 rejects the legacy descriptor itself.**

Background on speed: upstream ran at high speed with the legacy descriptor until 2020,
moved to the full speed descriptor in 5986675 (fixing hangs after
`GetDevAuthenticationInfo` on some devices), and forced full speed in fda808e (2025)
because a Ford Sync 2 at high speed used the real iPod's report layout regardless of
the descriptor (oandrew/ipod-gadget#28). `high_speed=1` stays available, off by default.

## Hypothesis: 2-byte Report Count items

The legacy descriptor declares its input reports `0x09`–`0x0C` (257 to 767 bytes) with
2-byte Report Count items (`0x96 xx xx`). The descriptor the X9U6 accepts uses only
1-byte ones (`0x95 xx`). A minimal HID parser in the head unit that knows only the
1-byte form would fail on the legacy descriptor right after reading it, which is what
both tests show. The head unit does read the report sizes: with the default
descriptor it always picked the smallest output report that fits (`0x06` for short
frames, `0x09` for long ones).

## Test #5: default + one big output report (`bigout`)

`hid_desc=bigout` is the default descriptor byte for byte plus one Output report
`0x0A` of 255 bytes, written with a 1-byte Report Count (`0x95 0xff`). No `0x96`
anywhere. If the hypothesis holds, the head unit accepts it and, choosing the smallest
report that fits, sends the 251-byte frame as one `0x0A` report. Full speed, so only
one thing changes from the working default:

```
# /etc/modprobe.d/ipod-gadget.conf   (no high_speed line)
options g_ipod_hid hid_desc=bigout

# /etc/default/ipod-client
IPOD_GLOBAL_ARGS="--hid=bigout"
```

**Result: rejected exactly like #3 and #4** — descriptor read, suspend about 6 ms
later, retry, "Check USB memory or iPod". So the 2-byte items were not the reason.

## Conclusion: the X9U6 takes the default descriptor and nothing else

Three different changes (the real iPod's descriptor at full speed, the same at high
speed, the default plus one report) were all rejected the same way, right after the
descriptor read, while the default always starts IDPS. The head unit evidently checks
for the exact default full speed descriptor. **The descriptor experiments are over:
keep `hid_desc=default`** (no `options g_ipod_hid` line, no `high_speed`).

## Test #6: tolerate the damage in the client (`--lenient-auth`)

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

Replaying the car's trace with it, the client acknowledges section 0 (`ACK` for
`0x15`, transaction `0x0001`), which is where the real session stopped. A synthetic
session damaged the same way (four sections, then a damaged three-report signature)
runs through to `AckDevAuthenticationStatus` passed. Expect one `ERRO` line when the
last section arrives: the client tries to read the (damaged) certificate for its log.

Two packet-layer bugs fixed along the way, flag or not: a truncated packet was
completed from stale bytes of the buffer behind it (and could crash the client), and
after a bad packet the reader searched inside it for the next start byte (`0x55`,
which a certificate contains), so it could act on bytes nobody sent as a command.

Config for car test #6:

```
# /etc/modprobe.d/ipod-gadget.conf: no "options g_ipod_hid" line, no high_speed

# /etc/default/ipod-client
IPOD_GLOBAL_ARGS="--lenient-auth"
```

What to look for: four `lenient: accepted damaged frame cmd=0x15` lines and one with
`cmd=0x18` in `journalctl -u ipod-client`, then the head unit going past
authentication (in the trace: `AckDevAuthenticationStatus` sent, then the audio and
remote lingo traffic).

## Status

- 2026-10-17: `legacy_hid=1` added. Test #3 (legacy, full speed): rejected.
- 2026-10-17: `high_speed=1` added. Test #4 (legacy, high speed): rejected.
- 2026-10-17: `hid_desc=bigout` + client `--hid=bigout`; the client tolerates `0x02`
  mid-frame. Test #5 (bigout, full speed): rejected. Descriptor stays default.
- 2026-10-17: client `--lenient-auth`, packet layer fixes. Test #6 not run yet.

