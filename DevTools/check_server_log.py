#!/usr/bin/env python3
"""Asserts that the mock server saw exactly the input the core test sends."""
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
first_session = events[: next(i for i, e in enumerate(events) if e["event"] == "disconnected") + 1]

def expect(cond, what):
    print(("PASS  " if cond else "FAIL  ") + what)
    if not cond:
        sys.exit(1)

encodings = next(e for e in first_session if e["event"] == "set_encodings")["encodings"]
expect(encodings[:2] == [7, -25], f"asks for Tight with JPEG quality 80 ({encodings})")
expect(-258 in encodings and -223 in encodings, "asks for extended keys and DesktopSize")

pf = next(e for e in first_session if e["event"] == "set_pixel_format")
expect(pf["bpp"] == 32 and pf["shifts"] == [16, 8, 0], "sets a 32bpp BGRX pixel format")

keys = [(e["scancode"], int(e["down"])) for e in first_session if e["event"] == "ext_key"]
TAB = 0x0F
CMD, C, SPACE, CTRL, ALT, P, SHIFT, H, I, ONE = 0xDB, 0x2E, 0x39, 0x1D, 0x38, 0x19, 0x2A, 0x23, 0x17, 0x02
expected = [
    (CMD, 1), (C, 1), (C, 0), (CMD, 0),                 # ⌘C, sent as a tap
    (CMD, 1), (SPACE, 1), (SPACE, 0), (CMD, 0),         # ⌘Space
    (CTRL, 1), (CMD, 1), (CMD, 0), (CTRL, 0),           # ⌃⌘V released before local action
    (ALT, 1), (ALT, 0), (CMD, 1), (TAB, 1), (TAB, 0), (TAB, 1), (TAB, 0), (CMD, 0),  # ⌥Tab Tab → ⌘ held
    (ALT, 1), (ALT, 0), (CMD, 1), (SPACE, 1), (SPACE, 0), (CMD, 0),                  # ⌥Space → ⌘Space
    (ALT, 1), (ALT, 0), (ALT, 1), (ALT, 0), (P, 1), (P, 0),  # PiKVM "type clipboard" magic
    (SHIFT, 1), (H, 1), (H, 0), (SHIFT, 0), (I, 1), (I, 0), (SHIFT, 1), (ONE, 1), (ONE, 0), (SHIFT, 0),
]
expect(keys == expected, "key sequence matches\n   got:      %s\n   expected: %s" % (keys, expected))

cut = [e["text"] for e in first_session if e["event"] == "cut_text"]
expect(cut == ["héllo ✓"], f"clipboard text arrives as UTF-8 ({cut})")

pointer = [(e["buttons"], e["x"], e["y"]) for e in first_session if e["event"] == "pointer"]
expect(pointer == [(1, 1279, 10), (16, 1279, 10), (0, 1279, 10)], f"pointer clamped to the resized screen, wheel down ({pointer})")

fburs = [e for e in first_session if e["event"] == "fbur"]
expect(not fburs[0]["incremental"] and all(e["incremental"] for e in fburs[1:]), "first update request is full, the rest incremental")

second = events[len(first_session):]
expect(any(e["event"] == "auth" and e["password"] == "wrong" for e in second), "second session tried the wrong password")
print("ALL SERVER CHECKS PASSED")
