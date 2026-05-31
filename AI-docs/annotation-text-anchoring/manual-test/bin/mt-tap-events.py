#!/usr/bin/env python3
"""Generate MT-B protocol touch events for one phase of a corner-tap.

Usage: mt-tap-events.py <x> <y> <two:0|1> <phase:down|up> <fmt>

<fmt> is the struct.pack format for one `input_event`. On most Kobos:
  32-bit ARM (armv7l):  IIHHi
  64-bit ARM (aarch64): qqHHi
Auto-set by bin/detect-device.sh; passed through bin/kobo-tap.

Writes the byte stream to stdout for piping into ssh ... cat > /dev/input/event1.
"""
import struct
import sys

if len(sys.argv) != 6:
    sys.exit(__doc__)

x       = int(sys.argv[1])
y       = int(sys.argv[2])
two     = int(sys.argv[3])
phase   = sys.argv[4]
fmt     = sys.argv[5]

# Linux input event constants.
EV_SYN, EV_ABS, EV_KEY = 0, 3, 1
SYN_REPORT = 0
ABS_MT_SLOT         = 0x2f
ABS_MT_TRACKING_ID  = 0x39
ABS_MT_POSITION_X   = 0x35
ABS_MT_POSITION_Y   = 0x36
BTN_TOUCH           = 0x14a

def ev(type_, code, value):
    # input_event: sec, usec, type, code, value
    return struct.pack(fmt, 0, 0, type_, code, value)

buf = b""

if phase == "down":
    buf += ev(EV_ABS, ABS_MT_SLOT,        0)
    buf += ev(EV_ABS, ABS_MT_TRACKING_ID, 1001)
    buf += ev(EV_ABS, ABS_MT_POSITION_X,  x)
    buf += ev(EV_ABS, ABS_MT_POSITION_Y,  y)
    buf += ev(EV_KEY, BTN_TOUCH,          1)
    if two:
        buf += ev(EV_ABS, ABS_MT_SLOT,        1)
        buf += ev(EV_ABS, ABS_MT_TRACKING_ID, 1002)
        buf += ev(EV_ABS, ABS_MT_POSITION_X,  x + 40)
        buf += ev(EV_ABS, ABS_MT_POSITION_Y,  y + 40)
    buf += ev(EV_SYN, SYN_REPORT, 0)

elif phase == "up":
    buf += ev(EV_ABS, ABS_MT_SLOT,        0)
    buf += ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
    if two:
        buf += ev(EV_ABS, ABS_MT_SLOT,        1)
        buf += ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
    buf += ev(EV_KEY, BTN_TOUCH, 0)
    buf += ev(EV_SYN, SYN_REPORT, 0)

else:
    sys.exit(f"unknown phase: {phase}")

sys.stdout.buffer.write(buf)
