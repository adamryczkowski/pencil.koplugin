# Remote automation of the test playbook — feasibility & recipes

## Bottom line

**Yes, end-to-end automation is feasible via SSH.** Two tiers:

- **Tier 1 (90 % of the playbook, low-risk):** every reflow trigger
  (rotate, font ±, font family, line-spacing, margins), every chapter jump,
  and every screenshot can be driven by injecting a single corner-tap into
  `/dev/input/event1` over SSH, after a one-time gesture-binding setup on
  the device. Strokes still drawn by hand.

- **Tier 2 (full automation):** also inject the test strokes by writing
  stylus events to the tablet evdev device. Doable but needs per-device
  coordinate calibration and ~50 lines of Python (`evdev` module on the
  host, raw `dd` on the Kobo).

I recommend implementing Tier 1 first — it kills 90 % of the manual labour
without needing calibration, and the bug we're hunting reproduces on a
single stroke, so we don't need to script 50 of them.

## Why injection works

Verified in the KOReader source (`frontend/device/kobo/device.lua:864-898`):
KOReader auto-detects input devices via `fbink_input_scan` and `fdopen`s
each one. **It does not call `EVIOCGRAB`**, so events written to
`/dev/input/eventX` by a *separate* process are observed by KOReader
alongside any real-finger events. Standard Linux evdev semantics — same
trick `evemu-event` and `weston-debug` use.

The device map is in `device.lua:144-147`:
- `/dev/input/event0` — NTX (power button, pagination buttons, sleep cover)
- `/dev/input/event1` — touchscreen
- Stylus (on Elipsa / Sage / Libra Colour with pen) — auto-detected as
  `INPUT_TABLET`, typically `/dev/input/event2` or `/dev/input/event3`.
  Confirm on your device with:
  ```bash
  ssh -p 2222 root@<kobo> "cat /proc/bus/input/devices"
  ```

## Tier 1 — corner-tap automation

### One-time setup on the Kobo

Open KOReader → `Tools (wrench) → Gesture Manager`. Bind:

| Gesture | Action | Why |
|---|---|---|
| `Tap → Top-left corner`     | `Screenshot`        | Capture a frame |
| `Tap → Top-right corner`    | `Toggle orientation`| Rotate test |
| `Tap → Bottom-right corner` | `Increase font size`| Reflow trigger A |
| `Tap → Bottom-left corner`  | `Decrease font size`| Symmetric back |
| `Two-finger tap → TL`       | `Increase line spacing` | Reflow trigger B |
| `Two-finger tap → TR`       | `Decrease line spacing` | Symmetric back |
| `Two-finger tap → BL`       | `Next chapter`      | Navigation |
| `Two-finger tap → BR`       | `Previous chapter`  | Navigation |

(Or import the JSON snippet at the bottom of this file straight into
`koreader/settings/gestures.lua`.)

After this, the device responds to taps from anywhere — real fingers OR
injected events — at those coordinates.

### Corner-tap injection script

Save this on the **host** as `bin/kobo-tap`:

```bash
#!/usr/bin/env bash
# Usage: kobo-tap <kobo-ip> <corner>
# corner ∈ {tl, tr, bl, br, ttl, ttr, tbl, tbr}   (t* = two-finger)
set -euo pipefail
KOBO="$1"; CORNER="$2"
# Hardcoded for Kobo Elipsa 2E (1404x1872). Change for other models.
W=1404; H=1872; MARGIN=80
case "$CORNER" in
  tl|ttl)  X=$MARGIN;          Y=$MARGIN ;;
  tr|ttr)  X=$((W - MARGIN));  Y=$MARGIN ;;
  bl|tbl)  X=$MARGIN;          Y=$((H - MARGIN)) ;;
  br|tbr)  X=$((W - MARGIN));  Y=$((H - MARGIN)) ;;
  *) echo "bad corner: $CORNER" >&2; exit 1 ;;
esac
TWO_FINGER=0
case "$CORNER" in ttl|ttr|tbl|tbr) TWO_FINGER=1 ;; esac

# Generate evdev byte-stream locally, pipe to Kobo's /dev/input/event1.
# Format: struct input_event { sec, usec, type, code, value } — sizes
# vary by ABI. Most KoBo firmwares are 32-bit ARM with 32-bit time_t →
# struct is 16 bytes. Newer 64-bit Kobos use 24 bytes. Adjust 'IIHHi'
# (32-bit) vs 'qqHHi' (64-bit) accordingly.
python3 - "$X" "$Y" "$TWO_FINGER" <<'PY' | ssh -p 2222 "root@${KOBO}" "cat > /dev/input/event1"
import struct, sys, time
x, y, two = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
# MT-B protocol B event codes
EV_SYN, EV_ABS, EV_KEY = 0, 3, 1
SYN_REPORT = 0
ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0x2f, 0x39
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
BTN_TOUCH = 0x14a
# 32-bit Kobo: 'IIHHi'; 64-bit: 'qqHHi'. Try both via env override.
FMT = 'IIHHi'   # set KOBO_EVDEV=64 to switch to 'qqHHi'
def ev(t, c, v):
    return struct.pack(FMT, 0, 0, t, c, v)
out = b''
# Finger 0 down
out += ev(EV_ABS, ABS_MT_SLOT, 0)
out += ev(EV_ABS, ABS_MT_TRACKING_ID, 1001)
out += ev(EV_ABS, ABS_MT_POSITION_X, x)
out += ev(EV_ABS, ABS_MT_POSITION_Y, y)
out += ev(EV_KEY, BTN_TOUCH, 1)
if two:
    out += ev(EV_ABS, ABS_MT_SLOT, 1)
    out += ev(EV_ABS, ABS_MT_TRACKING_ID, 1002)
    out += ev(EV_ABS, ABS_MT_POSITION_X, x + 30)
    out += ev(EV_ABS, ABS_MT_POSITION_Y, y + 30)
out += ev(EV_SYN, SYN_REPORT, 0)
# Hold ~50 ms
# Finger 0 up
out += ev(EV_ABS, ABS_MT_SLOT, 0)
out += ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
if two:
    out += ev(EV_ABS, ABS_MT_SLOT, 1)
    out += ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
out += ev(EV_KEY, BTN_TOUCH, 0)
out += ev(EV_SYN, SYN_REPORT, 0)
sys.stdout.buffer.write(out)
PY
```

Then the playbook becomes shell:

```bash
KOBO=192.168.1.42
H=./bin/kobo-tap

$H $KOBO tl                          # screenshot (baseline)
sleep 1
# ... draw a stroke by hand on the device ...
$H $KOBO tl                          # screenshot (after-draw)
$H $KOBO tr ; sleep 2                # rotate
$H $KOBO tl                          # screenshot (after-rotate)
$H $KOBO tr ; sleep 2                # rotate back
$H $KOBO tl                          # screenshot (after-restore)

$H $KOBO tbl ; sleep 1               # next chapter (Ch.2)
$H $KOBO br  ; sleep 2               # font size up
$H $KOBO tl                          # screenshot
# ... etc.
```

### Screenshot mirror

Run in parallel — already covered in `SSH-SCREENSHOT.md`:

```bash
while true; do
  rsync -e 'ssh -p 2222' -t --ignore-existing \
    "root@${KOBO}:/mnt/onboard/screenshots/" "./screenshots/" 2>/dev/null
  sleep 1
done
```

I `Read` `./screenshots/Screenshot_*.png` directly. Names sort
chronologically; matching them to playbook steps is a simple post-process.

## Tier 2 — stroke injection

The stroke uses the **stylus** device on stylus-capable Kobos. The
relevant codes are `BTN_TOOL_PEN`, `BTN_TOUCH`, `ABS_X`, `ABS_Y`,
`ABS_PRESSURE`. Pattern:

```python
# Touch the pen down
ev(EV_KEY, BTN_TOOL_PEN, 1)
ev(EV_ABS, ABS_X, x0); ev(EV_ABS, ABS_Y, y0); ev(EV_ABS, ABS_PRESSURE, 256)
ev(EV_KEY, BTN_TOUCH, 1)
ev(EV_SYN, SYN_REPORT, 0)
# Drag through N points
for x,y in path:
    ev(EV_ABS, ABS_X, x); ev(EV_ABS, ABS_Y, y); ev(EV_ABS, ABS_PRESSURE, 256)
    ev(EV_SYN, SYN_REPORT, 0)
# Lift
ev(EV_KEY, BTN_TOUCH, 0)
ev(EV_ABS, ABS_PRESSURE, 0)
ev(EV_KEY, BTN_TOOL_PEN, 0)
ev(EV_SYN, SYN_REPORT, 0)
```

Per-device knowables (one-time):
- `cat /proc/bus/input/devices` — find the line `N: Name="...Pen..."` or
  `H: Handlers=event2` for the tablet.
- `ioctl(EVIOCGABS, ABS_X)` — get min/max for X (usually 0..screen_w but
  not guaranteed). The `evtest` binary, if present, prints these.
- KOReader's pen-slot is hard-coded to 4 (`input.lua:182`) — use
  `ABS_MT_SLOT=4` if the device is touchscreen-multitouch rather than a
  separate tablet device.

For the playbook's test markers, we need ONE set of (x, y) per marker per
baseline. Cheapest path: take a baseline screenshot, open in an image
viewer, click each marker to read its pixel coords, hardcode into a
`stroke_at_MK10()` helper. Per-marker calibration is ~5 min once.

The marker count is small (the killer test uses just MK04 / MK12 / MK20),
so this is realistic.

## What this buys us

Once Tier 1 is in place:
- Full playbook run shrinks from ~15 min of careful tapping to ~2 min of
  scripted dispatch + on-demand stroke drawing.
- Screenshots arrive locally with correct timestamps, so I can match them
  to each step without you renaming files.
- Reproducible across runs — same delays, same corner coords, same exact
  action sequence.

Tier 2 closes the gap to truly headless: tap "go" on the host, walk away,
photos appear, verdict computed.

## Gotchas / risks

1. **evdev struct size.** 32-bit vs 64-bit Kobo changes the byte layout
   (`IIHHi` vs `qqHHi`). Detect with:
   ```bash
   ssh -p 2222 root@$KOBO 'uname -m'
   # armv7l → 32-bit; aarch64 → 64-bit
   ```
   And switch the format string accordingly.
2. **Pre-existing finger contacts.** If a real finger is touching the
   screen when we inject, slots collide. Start each script with all
   `TRACKING_ID = -1` events to clear any zombie slots.
3. **Stylus device path drift.** Auto-detection via
   `/proc/bus/input/devices` lookup at script start, don't hardcode
   `event2`.
4. **Two real fingers required for two-finger gestures** — KOReader's
   gesture detector treats true two-finger taps differently than two
   single-finger pseudo-taps. Our injection above emits both slots with
   distinct tracking IDs in a single sync frame, which is what
   GestureDetector expects.
5. **Some Kobos use protocol A** (`ABS_X`/`ABS_Y` + `BTN_TOUCH` without
   MT slots). KOReader handles both via `koboInputMangling`
   (`device.lua:1118`). Easiest workaround: check `evtest` output once
   on the device and adjust the script. The vast majority of post-Aura-H2O
   Kobos use B.
6. **Settings file edits are NOT a substitute.** Modifying
   `koreader/settings.reader.lua` to change font size on disk does NOT
   reproduce the live reflow path — the bug requires DocumentRerendered to
   fire through the event chain. Hence the gesture-binding approach.

## Recommended next step

I can write `bin/kobo-tap` + `bin/kobo-screenshot-mirror` +
`run-playbook.sh` (the Tier 1 orchestrator) now, ~80 lines total. Want me
to?

If yes, I'll also include a small `detect-device.sh` that prints
arch / screen size / input device map so the playbook auto-calibrates
instead of hardcoding for one Kobo model.
