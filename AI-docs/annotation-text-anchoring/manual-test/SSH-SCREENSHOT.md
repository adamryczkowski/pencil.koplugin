# Remote screenshot via SSH from Kobo

The Kobo has no native screenshot key, but KOReader exposes a screenshot
gesture and saves PNGs to `/mnt/onboard/screenshots/`. With KOReader's SSH
server enabled, you can pull screenshots over the same channel the
`just deploy-ssh` command uses (port 2222 by default).

This is **substantially faster and more reproducible** than phone-camera
photos. Recommended once the rig is set up.

## Prerequisites

1. **Kobo SSH server enabled.** In KOReader: `Tools menu → Network → SSH
   server → Start`. Default port `2222`. Same port the `justfile` uses.
2. **Public-key auth** ideally — interactive password works but slows the
   mirror loop below.
3. Kobo IP visible in Settings → Network or in your router's DHCP table.

Test connectivity:
```bash
ssh -p 2222 root@<KOBO-IP> "uname -a && ls /mnt/onboard/screenshots/"
```

## Triggering a screenshot on the device

KOReader's `Screenshoter` widget fires on a gesture. The factory default is
**two-finger long-tap on diagonally opposite corners** (top-left + bottom-right,
or top-right + bottom-left). Customisable in `Tools → Gesture Manager`.

Bind it to a single tap for testing:
1. `Tools → Gesture Manager → Tap → Right edge`.
2. Action: `Screenshot`.

After this, a single right-edge tap saves a PNG.

Screenshot files land at:
```
/mnt/onboard/screenshots/Screenshot_YYYY-MM-DD_HHMMSS.png
```

## One-shot pull (manual)

```bash
KOBO=<KOBO-IP>
mkdir -p ./screenshots
scp -P 2222 "root@${KOBO}:/mnt/onboard/screenshots/Screenshot_*.png" ./screenshots/
```

`scp` returns exit 0 even when files exist; rerun is idempotent (will
re-copy already-pulled files, harmless).

## Auto-mirror loop (recommended)

This watches the device folder and copies new PNGs locally as they appear.
Run it in another terminal while you test:

```bash
KOBO=<KOBO-IP>
LOCAL=./screenshots
mkdir -p "$LOCAL"
while true; do
  rsync -e "ssh -p 2222" -t --ignore-existing \
    "root@${KOBO}:/mnt/onboard/screenshots/" "$LOCAL/" 2>/dev/null
  sleep 2
done
```

`--ignore-existing` means new shots only; `-t` preserves timestamps so file
ordering matches capture order. On a typical home LAN this latches a new
screenshot within ~2-3 s of the gesture.

Then in this conversation, just point me at the local folder and I can
`Read` each PNG directly.

## Direct framebuffer dump (fallback)

If the KOReader screenshot path is broken on your build, the framebuffer is
readable directly. Kobo's framebuffer is typically 16-bit at `/dev/fb0`:

```bash
ssh -p 2222 root@<KOBO-IP> "cat /dev/fb0" > fb.raw
# Convert: requires `fbgrab` or a small Python script — needs width/height
# /bpp from `/sys/class/graphics/fb0/{virtual_size,bits_per_pixel}`
```

This is messy enough that the KOReader screenshot route is almost always
the right answer. Mentioned only as a "if all else fails" lifeline.

## Wiring into this conversation

When you have screenshots locally, either:
- **Drop them in `AI-docs/annotation-text-anchoring/manual-test/run-N/`**
  (create the folder per test run; `N` = run number) and tell me the path.
  I will `Read` each file by name.
- **Or attach individual photos** to your message and I will look at them
  directly.

For the playbook in `PLAYBOOK.md`, the file-naming scheme
`Txx-<state>.{jpg,png}` lets me pattern-match without needing a manifest.
