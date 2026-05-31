# Tier 1 remote runner — quick start

Drives reflow triggers + screenshots over SSH; you still draw the strokes
by hand (~8 strokes in the whole playbook).

## What's in `bin/`

| Script | Purpose |
|---|---|
| `detect-device.sh <kobo-ip> [port]` | One-shot probe. Writes `../device.env` with arch / screen size / SSH config. |
| `mt-tap-events.py`                  | Pure helper. Emits MT-B touch-event bytes to stdout. Called by `kobo-tap`. |
| `kobo-tap <corner>`                 | Injects one corner-tap. Corners: `tl tr bl br ttl ttr tbl tbr` (`tt*` = two-finger). |
| `snap <out-path>`                   | `kobo-tap tl` (bound to Screenshot) → scp the new PNG → rename. |
| `run-playbook.sh [N]`               | The full T01–T08 playbook. Photos land in `../run-<N>/`. |

## First-run checklist

### 1. SSH access to the Kobo

On the Kobo, in KOReader: `Tools → Network → SSH server → Start`.
Default port `2222`. Same port the `justfile` already uses.

```bash
ssh -p 2222 root@<KOBO-IP> true && echo OK
```

If you use a password, set up key auth first (huge speed-up — every tap is
an SSH round-trip):

```bash
ssh-copy-id -p 2222 root@<KOBO-IP>
```

### 2. Bind the eight gestures (one-time)

On the Kobo, open `Tools (wrench) → Gesture Manager` and bind:

| Gesture | Action |
|---|---|
| Tap → Top-left corner       | Screenshot           |
| Tap → Top-right corner      | Toggle orientation   |
| Tap → Bottom-right corner   | Increase font size   |
| Tap → Bottom-left corner    | Decrease font size   |
| Two-finger tap → TL         | Increase line spacing |
| Two-finger tap → TR         | Decrease line spacing |
| Two-finger tap → BL         | Next chapter         |
| Two-finger tap → BR         | Previous chapter     |

These bindings are reused by every test run — set them once.

### 3. Probe the device

```bash
cd manual-test
./bin/detect-device.sh <KOBO-IP>
```

This writes `device.env` next to the scripts. It prints
`/proc/bus/input/devices` so you can sanity-check `KOBO_TOUCH_DEV` (default
`/dev/input/event1`). Edit `device.env` if the touchscreen handler differs.

### 4. Smoke test

```bash
./bin/kobo-tap tl   # should trigger a screenshot on the device
./bin/snap /tmp/smoke.png && file /tmp/smoke.png   # should be a real PNG
```

If `snap` reports "no screenshot found" but the device shows a flash, your
`KOBO_SCREENSHOT_DIR` is wrong — check `Tools → Screenshot folder`.

### 5. Run the playbook

```bash
./bin/run-playbook.sh 1
```

Photos arrive in `run-1/T00-preflight.png .. T08-after-reopen.png`. The
script prompts you (ENTER to continue) for the ~8 stroke-drawing moments
and for the two manual reflow steps (font family, margins — neither has a
single-tap Dispatcher action).

To send the run to me: paste the path or zip `run-1/` and attach.

## How it works under the hood

- `kobo-tap` builds a Linux evdev byte-stream locally (MT-B protocol B
  with `ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`, `BTN_TOUCH`, `SYN_REPORT`),
  pipes it to `ssh ... "cat > /dev/input/event1"`, sleeps 80 ms, then
  pipes the release frame. KOReader sees the events alongside any real
  fingers (no `EVIOCGRAB`, verified in
  `koreader/frontend/device/kobo/device.lua:864-898`).
- `snap` reuses `kobo-tap tl`, then `scp`'s the newest
  `Screenshot_*.png` from `KOBO_SCREENSHOT_DIR`.
- Persistent SSH via `ControlMaster=auto` + `ControlPersist=60s` keeps the
  whole run on one socket, so each `kobo-tap` costs ~10-20 ms not
  ~300 ms.

## Tweaks

- **Wrong corner activates instead of expected one:** your screen is
  rotated relative to what the script expects. The script's W/H are
  portrait; in landscape the corners swap. Easiest fix: always rotate
  back to portrait between tests (the playbook does this) or set
  `KOBO_SCREEN_W`/`H` to the actual current orientation.
- **Touchpoint outside the gesture zone:** increase `KOBO_TAP_MARGIN` in
  `device.env` (default 80 px). KOReader's corner zones are usually
  20-25 % of screen, so 80 px is well inside.
- **Two-finger tap not detected:** the two synthetic fingers are 40 px
  apart; some gesture detectors want them farther. Edit
  `bin/mt-tap-events.py` and bump `x + 40`/`y + 40` to e.g. `+150`.
- **Slow:** confirm ControlMaster is working —
  `ls /tmp/koboctl-root*` should show the live socket after the first
  `kobo-tap`.

## If Tier 1 isn't enough

`REMOTE-AUTOMATION.md` covers Tier 2 (stylus injection for the strokes
themselves). Adds ~50 LOC + per-marker (x, y) calibration. The Tier 1
runner is structured so Tier 2 just slots in: replace the `ask "Draw
squiggle on …"` prompts with `./bin/draw-stroke MK04` calls.
