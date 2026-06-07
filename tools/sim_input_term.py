#!/usr/bin/env python3
"""sim_input_term.py — zero-dependency sender for the Godot visionOS simulator.

Run this in a Terminal, keep that Terminal focused, and press keys here (NOT in the sim
window — the sim can't receive app keyboard input; that's why this bridge exists). Commands
go over UDP to the app's listener (test-project/simulator_input.gd).

    c   toggle grab on/off  (grab/poke the control-panel button under the view centre)
    v   cycle hands         b   reset sandbox        n   toggle sky / passthrough
    q   quit

Aim with the Simulator's own viewpoint controls (W/A/S/D move, Option-drag rotate) in the
sim window, then come back here and press c to grab/poke. No install needed.
"""
import socket
import sys
import termios
import tty

ADDR = ("127.0.0.1", 9999)
_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_grab = False


def send(msg):
    _sock.sendto(msg.encode("ascii"), ADDR)


def main():
    global _grab
    print("Sim sender (terminal). c=grab toggle  v=hands  b=reset  n=sky  q=quit")
    print("Keep THIS window focused and press keys here.")
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while True:
            ch = sys.stdin.read(1).lower()
            if ch == "q":
                break
            elif ch == "c":
                _grab = not _grab
                send("C1" if _grab else "C0")
                print(f"grab {'ON' if _grab else 'off'}")
            elif ch in ("b", "v", "n"):
                send(ch.upper())
                print(f"sent {ch.upper()}")
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        if _grab:
            send("C0")
    print("bye")


if __name__ == "__main__":
    main()
