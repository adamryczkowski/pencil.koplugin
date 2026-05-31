# Manual test playbook — Goal-2 freehand stroke anchoring

## Status of the feature being tested

Goal-2 freehand-stroke anchoring shipped with all busted specs green (330/330),
but on-device testing shows strokes jump on font / rotation change.

**Suspected root cause (already located):** `main.lua:4325` hardcodes
`em_px=12, lh_px=20` at paint time, while capture (`stroke_capture.lua:63`)
derives them from the actual word height `word.pos.h`. On any layout whose
real line-height ≠ 20px (Kobo default is ~30-40px) the algebra mis-scales by
~1.5-2× — exactly the "strokes jump" symptom. Rotation makes it worse
because both sides become wrong differently.

This playbook is designed to **confirm or refute that diagnosis** with the
fewest possible test cycles, and to map the failure mode against each reflow
trigger.

## Files in this directory

| File | Purpose |
|---|---|
| `pencil-anchor-test.epub` | Side-load onto the Kobo. Contains four chapters tailored to specific reflow tests. |
| `epub-src/` | Source of the epub. Edit + re-run `build.sh` to regenerate. |
| `PLAYBOOK.md` | This document. |
| `SSH-SCREENSHOT.md` | How to pull screenshots from the device. |

## EPUB structure

| Chapter | Content | Use it to test |
|---|---|---|
| Ch.1 Line markers | 20 short paragraphs each starting with `[L01]`..`[L20]` | Single-line strokes. Easy to label "which marker did you draw on". |
| Ch.2 Inline markers | One long paragraph with `[MK01]`..`[MK24]` inline | Reflow drama — markers move horizontally + vertically. The killer test for the diagnosed bug. |
| Ch.3 Prose | Plain Moby-Dick excerpt with identifiable words ("WHALE", "AHAB") | Line-spacing + font-family tests. |
| Ch.4 Margin / fallback | Wide-gutter chapter | EARNED rotation-badge path (stroke drawn in gutter → `anchor=nil` → badge on reflow). |

## Photo naming convention

`Txx-<state>.jpg` where `xx` is the step number and `<state>` is one of:
`baseline`, `after-draw`, `after-rotate`, `after-fontup`, `after-margin`,
`after-linesp`, `after-reopen`. Examples: `T03-baseline.jpg`,
`T03-after-rotate.jpg`.

If using SSH-pulled screenshots (see `SSH-SCREENSHOT.md`), rename the pulled
PNG to this scheme before sending.

## Pre-flight (do this once)

1. **PF-1.** Pull current `main` and redeploy. From the repo root:
   ```bash
   git -C /home/Adama-docs/tmp/pencil.koplugin log --oneline -1
   # expect: 92f8e5c G2-M7: documentation closeout — ...
   KOBO_SSH_PORT=2222 just deploy-ssh <kobo-ip>     # OR: just deploy-usb
   ```
2. **PF-2.** Side-load `pencil-anchor-test.epub` to the Kobo's library.
3. **PF-3.** On Kobo: restart KOReader (long-press power, then start).
4. **PF-4.** Open the test EPUB. Note your current settings:
   - Font family: _________
   - Font size: _________
   - Line spacing: _________
   - Margins preset: _________
   - Orientation: _________
   These are the **baseline**. You return to them between tests.
5. **PF-5.** Open Pencil tool. Confirm pen colour is visible (any non-white).

---

## Test cycle

Each test is **draw → photo → reflow → photo → reflow back → photo**.
After each test, restore baseline and clear strokes (Pencil menu → clear page)
before the next test, unless the test explicitly chains.

### T01 — Single text-stroke on Ch.1, rotation

1. Go to Ch.1.
2. Photo: `T01-baseline.jpg` (whole screen, no strokes yet).
3. Draw one **horizontal squiggle** straight through the word `[L05]` (the
   bold marker only, do not cross into the prose).
4. Photo: `T01-after-draw.jpg`.
5. Rotate portrait → landscape (Tools menu or rotation gesture).
6. **Wait for repaint to settle** (~1 s).
7. Photo: `T01-after-rotate.jpg`.
8. Rotate back to portrait.
9. Photo: `T01-after-rotate-back.jpg`.

**PASS criterion:** in every photo, the squiggle covers `[L05]` and only
`[L05]`. ±1 character of horizontal drift is acceptable (CRengine rounds
positions). Vertical drift larger than ½ line-height = FAIL.

**Expected failure (if diagnosis is correct):** stroke appears shifted up
and to the left by ~30-50 % of its original offset.

### T02 — Font size up/down, Ch.1

1. Restore baseline. Clear page. Go to Ch.1.
2. Draw squiggle on `[L10]`. Photo: `T02-after-draw.jpg`.
3. Font size **+2 steps**. Photo: `T02-after-fontup.jpg`.
4. Font size **−4 steps** (now 2 below baseline). Photo: `T02-after-fontdown.jpg`.
5. Font size back to baseline. Photo: `T02-after-restore.jpg`.

**PASS criterion:** squiggle stays on `[L10]` in every photo.

### T03 — Font family change, Ch.3

1. Restore baseline. Clear page. Go to Ch.3.
2. Find the word `WHALE` in the third paragraph. Draw a squiggle through it.
   Photo: `T03-after-draw.jpg`.
3. Change font family (Tools → Font → pick a different one, e.g. serif↔sans).
   Photo: `T03-after-font.jpg`.
4. Restore font. Photo: `T03-after-restore.jpg`.

### T04 — Line spacing change, Ch.3

1. Restore baseline. Clear page. Go to Ch.3.
2. Draw a squiggle through `AHAB` in the last paragraph.
   Photo: `T04-after-draw.jpg`.
3. Increase line spacing (Tools → Line spacing) by 2 steps.
   Photo: `T04-after-linesp.jpg`.

**PASS criterion:** squiggle stays on `AHAB`. Vertical position of the
squiggle should track the word's new vertical position, not stay at the old
screen y.

### T05 — Margin change, Ch.1

1. Restore baseline. Clear page. Go to Ch.1.
2. Draw a squiggle on `[L08]`. Photo: `T05-after-draw.jpg`.
3. Change margins (Tools → Page margins) — wider preset.
   Photo: `T05-after-margin.jpg`.
4. Restore margins. Photo: `T05-after-restore.jpg`.

### T06 — The killer test: Ch.2 multiple strokes, rotation

1. Restore baseline. Clear page. Go to Ch.2.
2. Draw three squiggles, one each on `[MK04]`, `[MK12]`, `[MK20]`.
   Photo: `T06-after-draw.jpg`.
3. Rotate to landscape. Photo: `T06-after-rotate.jpg`.

**This test is the most diagnostic** — the markers reflow to very different
screen positions, so any scale-mismatch bug becomes obvious.

### T07 — Fallback path, Ch.4

1. Restore baseline. Clear page. Go to Ch.4.
2. Draw a squiggle **entirely in the left gutter** (no text touched).
   Photo: `T07-after-draw.jpg`.
3. Rotate to landscape. Photo: `T07-after-rotate.jpg`.

**PASS criterion:** the stroke is replaced by a **rotation badge** (small
icon) rather than translated. This is the EARNED fallback path — exercising
it confirms the `anchor=nil` branch still works.

### T08 — Persistence

1. Restore baseline. Go to Ch.1. Clear page.
2. Draw a squiggle on `[L03]`. Photo: `T08-after-draw.jpg`.
3. Close the book (back to library).
4. Reopen the book. Go to Ch.1.
5. Photo: `T08-after-reopen.jpg`.

**PASS criterion:** squiggle is still on `[L03]` after reopen.

---

## What to send back

For each test, send:
- The photos named per convention.
- One-line verdict per test (PASS / FAIL / WEIRD).
- For FAIL: estimate the drift in line-heights (e.g. "≈1.5 LH right and 0.5 LH down").

I will use the drift directions and magnitudes to confirm the
`em_px/lh_px=12/20` hypothesis. If the actual line-height on your device is,
say, ~36px, the drift magnitude should be ~(1 − 20/36) = ~44 % of the
stroke's offset from the line-start xpointer.

## After the bug is fixed

The same playbook re-runs verbatim against the fixed build; same photos in
the same order; the failure modes should disappear in PASS lines. No
playbook edits needed.
