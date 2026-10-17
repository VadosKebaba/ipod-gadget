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
misread on our side.

Either fault alone breaks the message: the client's decoder (`hid.Decoder` in
oandrew/ipod) starts a new frame on every `0x02` report, and even a decoder that
tolerated it could not recover bytes that were never sent.

## Test #3: legacy descriptor at full speed — rejected

`legacy_hid=1` offers a real iPod's descriptor, whose largest output report (`0x15`)
holds 254 bytes, so the 251-byte frame would fit in one report. At full speed the
X9U6 does not accept it: it reads the HID report descriptor (control request
`81 06`, wValue `0x2200`), suspends and disconnects about 6 ms later, retries once,
then shows "Check USB memory or iPod". No SET_REPORT at all, empty trace. With the
default full speed descriptor it starts IDPS less than a second after the same read.

So: **full speed + `legacy_hid=1` is rejected by the Clarion X9U6.**

## Next: high speed with the legacy descriptor

A real iPod sends that descriptor at **high speed**, and the X9U6 presumably expects
the two together. That was also upstream's setup until 2020 (`max_speed` HIGH with
the 208-byte descriptor). Upstream then moved to the full speed descriptor (5986675,
which fixed hangs after `GetDevAuthenticationInfo` on some devices) and in 2025 forced
full speed (fda808e), because a Ford Sync 2 enumerated the gadget at high speed and
used the real iPod's report layout regardless of the descriptor it was given
(oandrew/ipod-gadget#28; the client's `--legacy` made it work). Nothing upstream points
at audio or the USB controller failing at high speed.

The combination to test:

```
# /etc/modprobe.d/ipod-gadget.conf
options g_ipod_gadget high_speed=1
options g_ipod_hid legacy_hid=1

# /etc/default/ipod-client
IPOD_GLOBAL_ARGS="--legacy"
```

and confirm the head unit really connected at high speed:
`cat /sys/class/udc/1000480000.usb/current_speed` → `high-speed`.

Not done (would belong in the client): treating `0x02` on a middle report as a
continuation. It would not bring back the dropped bytes.

## Status

- 2026-10-17: legacy mode added (`legacy_hid=1` + client `--legacy`).
- Test #3 (`legacy_hid=1`, full speed): rejected, see above.
- 2026-10-17: `high_speed=1` added; high speed + legacy not yet tried in the car.
