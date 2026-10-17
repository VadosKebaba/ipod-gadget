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

## What is being tried

**Legacy HID mode** (README → *Legacy HID mode*): the gadget offers a real iPod's
descriptor, whose largest output report (`0x15`) holds 254 bytes, so the 251-byte
frame fits in one report and the head unit has nothing to split. A real iPod offers
that descriptor at high speed; the gadget stays at full speed, so whether the X9U6
takes it there is part of what the test answers.

Not done (would belong in the client): treating `0x02` on a middle report as a
continuation. It would not bring back the dropped bytes.

## Status

- 2026-10-17: legacy mode added (`legacy_hid=1` + client `--legacy`); not yet tried
  in the car.
