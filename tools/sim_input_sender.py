#!/usr/bin/env python3
"""sim_input_sender.py — drive the Godot visionOS SIMULATOR with your Mac keyboard.

WHY THIS EXISTS: a custom-Metal-immersive Godot app gets no usable keyboard input inside the
visionOS simulator (GameController never sees the sim's forwarded keys, and the immersive
CompositorServices scene has no UIResponder). But the sim app shares the host loopback, so we
send commands over UDP to a PacketPeerUDP listener in the app (test-project/simulator_input.gd).
See KB intelligence/techniques/godot-avp-simulator-input.md.

KEYS (work from anywhere — this is a GLOBAL listener):
    C  (hold)  grab / poke a control-panel button under the view centre
    V          cycle hands (mesh / both / real)      [middle-pinch]
    B          reset the sandbox                      [ring-pinch]
    N          toggle sky / passthrough               [pinky-pinch]
    ESC        quit

AIMING: the sim has no head tracking; use the Simulator's own viewpoint controls to look
around (W/A/S/D move, Option-drag to rotate) — those go to the system camera. Point the view
centre at a cube or a panel button, then hold C to grab / poke.

SETUP:  pip3 install pynput   (needs Accessibility permission for your terminal)
RUN:    python3 tools/sim_input_sender.py
"""

import socket
import sys

PORT = 9999
ADDR = ("127.0.0.1", PORT)
_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send(msg: str) -> None:
    _sock.sendto(msg.encode("ascii"), ADDR)


def main() -> int:
    try:
        from pynput import keyboard
    except ImportError:
        print("Missing dependency. Run:  pip3 install pynput", file=sys.stderr)
        print("(pynput needs Accessibility permission for your terminal app.)", file=sys.stderr)
        return 1

    c_down = False  # de-dup auto-repeat so we send C1 once per physical press

    def on_press(key):
        nonlocal c_down
        try:
            ch = key.char.lower()
        except AttributeError:
            if key == keyboard.Key.esc:
                print("bye")
                return False
            return
        if ch == "c":
            if not c_down:
                c_down = True
                send("C1")
        elif ch in ("b", "v", "n"):
            send(ch.upper())

    def on_release(key):
        nonlocal c_down
        try:
            if key.char.lower() == "c":
                c_down = False
                send("C0")
        except AttributeError:
            pass

    print(f"Sending to {ADDR}.  C=grab(hold)  V=hands  B=reset  N=sky.  ESC to quit.")
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
