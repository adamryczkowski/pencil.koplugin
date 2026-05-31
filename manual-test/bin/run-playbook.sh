#!/usr/bin/env bash
# Drive the full Goal-2 anchor-test playbook end-to-end.
# Stroke drawing is still manual (~8 strokes total). Everything else —
# reflow triggers, screenshots, file naming — is scripted.
#
# Usage: run-playbook.sh [run-number]
#   Output: ../run-<N>/Txx-<state>.png
#
# Pre-requisite gesture bindings on the device (Tools → Gesture Manager):
#   Tap Top-left corner       → Screenshot
#   Tap Top-right corner      → Toggle orientation
#   Tap Bottom-right corner   → Increase font size
#   Tap Bottom-left corner    → Decrease font size
#   Two-finger tap TL         → Increase line spacing
#   Two-finger tap TR         → Decrease line spacing
#   Two-finger tap BL         → Next chapter
#   Two-finger tap BR         → Previous chapter

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/../device.env"

RUN="${1:-1}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-${RUN}"
mkdir -p "$OUT_DIR"

snap() { "${HERE}/snap" "${OUT_DIR}/$1"; }
tap()  { "${HERE}/kobo-tap" "$1"; }
ask()  { echo; read -r -p "  >> $1 [ENTER] " _; }
note() { echo; echo "=== $1 ==="; }

note "Run ${RUN} → ${OUT_DIR}"

note "Pre-flight"
ask "Open pencil-anchor-test.epub on the Kobo and go to Chapter 1"
snap "T00-preflight.png"

note "T01: stroke on [L05] + rotate (Ch.1)"
snap "T01-baseline.png"
ask "Draw a horizontal squiggle through [L05]"
snap "T01-after-draw.png"
tap tr; sleep 2.5
snap "T01-after-rotate.png"
tap tr; sleep 2.5
snap "T01-after-rotate-back.png"

note "T02: font-size up/down (Ch.1)"
ask "Clear strokes (Pencil menu → clear page)"
ask "Draw squiggle on [L10]"
snap "T02-after-draw.png"
tap br; sleep 1.5; tap br; sleep 1.5
snap "T02-after-fontup2.png"
tap bl; sleep 1.5; tap bl; sleep 1.5; tap bl; sleep 1.5; tap bl; sleep 1.5
snap "T02-after-fontdown2.png"
tap br; sleep 1.5; tap br; sleep 1.5
snap "T02-after-restore.png"

note "T03: font family (Ch.3) — manual reflow step"
ask "Clear strokes; navigate to Chapter 3 (or use two-finger tap BL ×2 for next chapter)"
ask "Draw squiggle through 'WHALE' in paragraph 3"
snap "T03-after-draw.png"
ask "Change font family (Tools → Font → pick a different family)"
snap "T03-after-font.png"
ask "Restore baseline font"
snap "T03-after-restore.png"

note "T04: line-spacing (Ch.3)"
ask "Clear strokes"
ask "Draw squiggle through 'AHAB' in last paragraph"
snap "T04-after-draw.png"
tap ttl; sleep 1.5; tap ttl; sleep 1.5
snap "T04-after-linesp.png"
tap ttr; sleep 1.5; tap ttr; sleep 1.5
snap "T04-after-restore.png"

note "T05: page margins (Ch.1) — manual reflow step"
ask "Clear strokes; navigate back to Chapter 1"
ask "Draw squiggle on [L08]"
snap "T05-after-draw.png"
ask "Change margins (Tools → Page margins → wider preset)"
snap "T05-after-margin.png"
ask "Restore baseline margins"
snap "T05-after-restore.png"

note "T06: killer test — three strokes + rotate (Ch.2)"
ask "Clear strokes; navigate to Chapter 2"
ask "Draw three squiggles: one each on [MK04], [MK12], [MK20]"
snap "T06-after-draw.png"
tap tr; sleep 2.5
snap "T06-after-rotate.png"
tap tr; sleep 2.5

note "T07: gutter stroke fallback (Ch.4)"
ask "Clear strokes; navigate to Chapter 4"
ask "Draw a squiggle ENTIRELY in the left gutter (no text touched)"
snap "T07-after-draw.png"
tap tr; sleep 2.5
snap "T07-after-rotate.png"
tap tr; sleep 2.5

note "T08: persistence"
ask "Clear strokes; navigate to Chapter 1"
ask "Draw squiggle on [L03]"
snap "T08-after-draw.png"
ask "Close the book (back to library), then re-open it and go to Chapter 1"
snap "T08-after-reopen.png"

note "Done"
echo "Photos:"
ls -1 "${OUT_DIR}" | sed 's/^/  /'
echo
echo "Send the contents of ${OUT_DIR} for analysis."
