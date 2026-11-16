#!/usr/bin/env python3
"""Drives a VM through the QEMU monitor: screenshots, key presses, commands."""
import os
import socket
import subprocess
import sys
import time

SOCK = os.environ.get("QEMU_MON", "/tmp/pfmon.sock")

SPECIAL = {
    " ": "spc", "-": "minus", ".": "dot", "/": "slash", ",": "comma",
    ";": "semicolon", "=": "equal", "'": "apostrophe", "`": "grave_accent",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
    "\t": "tab", "\n": "ret",
    "!": "shift-1", "@": "shift-2", "#": "shift-3", "$": "shift-4",
    "%": "shift-5", "^": "shift-6", "&": "shift-7", "*": "shift-8",
    "(": "shift-9", ")": "shift-0", "_": "shift-minus", "+": "shift-equal",
    "{": "shift-bracket_left", "}": "shift-bracket_right",
    "|": "shift-backslash", ":": "shift-semicolon", '"': "shift-apostrophe",
    "<": "shift-comma", ">": "shift-dot", "?": "shift-slash",
    "~": "shift-grave_accent",
}


def mon(cmds, wait=0.4):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(SOCK)
    time.sleep(0.3)
    try:
        s.recv(65536)
    except Exception:
        pass
    out = b""
    for c in cmds:
        s.send((c + "\n").encode())
        time.sleep(wait)
        try:
            out += s.recv(262144)
        except Exception:
            pass
    s.close()
    return out.decode(errors="replace")


def keyname(ch):
    if ch in SPECIAL:
        return SPECIAL[ch]
    if ch.isupper():
        return "shift-" + ch.lower()
    return ch


def send_text(text, delay=0.06):
    mon(["sendkey " + keyname(c) for c in text], wait=delay)


if __name__ == "__main__":
    act = sys.argv[1]
    if act == "shot":
        png = sys.argv[2]
        ppm = "/tmp/_shot.ppm"
        if os.path.exists(ppm):
            os.unlink(ppm)
        mon([f"screendump {ppm}"], wait=1.5)
        for _ in range(20):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.5)
        subprocess.run(["convert", ppm, png], check=True)
        print(png, os.path.getsize(png))
    elif act == "keys":
        mon([f"sendkey {k}" for k in sys.argv[2:]], wait=0.25)
        print("ok")
    elif act == "type":
        send_text(sys.argv[2])
        print("ok")
    elif act == "run":
        # Type the command and press Enter.
        send_text(sys.argv[2])
        mon(["sendkey ret"], wait=0.3)
        print("ok")
    else:
        print(mon(sys.argv[1:], wait=0.8))
