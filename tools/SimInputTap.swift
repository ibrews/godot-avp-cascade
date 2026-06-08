// SimInputTap.swift — unified one-window input for the Godot visionOS simulator.
//
// Installs a GLOBAL (listen-only) keyboard tap and forwards the action keys to the app over
// UDP. Because it's global, you keep the SIMULATOR window focused: WASD + Option-drag drive
// the sim's own viewpoint (move/look), while C/V/B/N reach the Godot app through this tap.
// No pip, no extra windows. (The in-app keyboard channel is dead in the sim — see KB
// godot-avp-simulator-input.md — which is why we tap + UDP.)
//
//   C (hold) OR left-click (hold)   grab / poke the panel button under the view centre
//   V         cycle hands     B   reset sandbox     N   toggle sky / passthrough
//
// BUILD:  swiftc -O tools/SimInputTap.swift -o tools/siminputtap
// RUN:    ./tools/siminputtap     (grant Accessibility to your Terminal when prompted)

import Cocoa
import CoreGraphics
import Network

let conn = NWConnection(host: "127.0.0.1", port: 9999, using: .udp)
conn.start(queue: .global())
func send(_ s: String) { conn.send(content: s.data(using: .ascii), completion: .idempotent) }

// macOS virtual keycodes → (keyDown packet, keyUp packet or nil)
let keymap: [Int64: (down: String, up: String?)] = [
    8:  ("C1", "C0"),  // C — grab (press-and-hold)
    9:  ("V", nil),    // V — cycle hands
    11: ("B", nil),    // B — reset
    45: ("N", nil),    // N — toggle sky
]

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .leftMouseDown:
        send("C1")  // left-click = grab (same as holding C) — natural with WASD
    case .leftMouseUp:
        send("C0")
    case .keyDown, .keyUp:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if let m = keymap[kc] {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { send(m.down) }
            } else if let up = m.up {
                send(up)
            }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)  // listen-only: never consume the event
}

let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
         | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: CGEventMask(mask),
                                  callback: callback,
                                  userInfo: nil) else {
    FileHandle.standardError.write(Data("Failed to create event tap — grant Accessibility permission to your Terminal (System Settings ▸ Privacy & Security ▸ Accessibility), then re-run.\n".utf8))
    exit(1)
}
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("SimInputTap active — focus the SIMULATOR. WASD/Option-drag = move/look, C(hold)=grab, V=hands, B=reset, N=sky. Ctrl-C to quit.")
CFRunLoopRun()
