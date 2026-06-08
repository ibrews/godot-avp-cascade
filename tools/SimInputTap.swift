// SimInputTap.swift — unified one-window input for the Godot visionOS simulator.
//
// Installs a GLOBAL (listen-only) keyboard/mouse tap and forwards the action keys to the app over
// UDP. Because it's global, you keep the SIMULATOR window focused: WASD + Option-drag drive the
// sim's own viewpoint (move/look), while C/V/B/N reach the Godot app through this tap. No pip, no
// extra windows. (The in-app keyboard channel is dead in the sim — see KB
// godot-avp-simulator-input.md — which is why we tap + UDP.)
//
//   C (TOGGLE) or left-click (HOLD)   grab the object under the view centre / poke a panel button
//   V  cycle hands     B  reset sandbox     N  toggle sky / passthrough
//
// FOCUS-GATED (task 1): events are only forwarded while the Simulator is the frontmost app, so the
// tap never steals keystrokes while you type in another app — even though the tap itself is global.
// If a grab is toggled on and focus then leaves the Simulator, we auto-release it (we'd otherwise
// miss the release key/click while gated out, leaving the object stuck "held").
//
// GRAB STATE (task 2): C and left-click share ONE `grabbing` flag so they can't fight. C flips it
// (press once to grab, again to release); left-mouse forces it down on press and up on release.
// With C as a toggle the mouse stays free, so Option-drag look works while grabbing (task 4).
// Left-mouse HOLD keeps the mouse busy, so Option-drag look won't engage during a mouse-hold grab —
// use the C toggle when you want to look around while holding.
//
// BUILD:  swiftc -O tools/SimInputTap.swift -o tools/siminputtap
// RUN:    ./tools/siminputtap     (grant Accessibility to your Terminal when prompted)

import Cocoa
import CoreGraphics
import Network

let conn = NWConnection(host: "127.0.0.1", port: 9999, using: .udp)
conn.start(queue: .global())
func send(_ s: String) { conn.send(content: s.data(using: .ascii), completion: .idempotent) }

// Unified grab state shared by C (toggle) and left-click (hold), de-duped so redundant presses
// don't spam C1/C0 or double-toggle. MUST be a global: a @convention(c) CGEventTap callback can
// reference globals but cannot capture local mutable state.
var grabbing = false
func setGrab(_ on: Bool) {
    if grabbing == on { return }
    grabbing = on
    send(on ? "C1" : "C0")
}

// One-shot action keys: fire once on keyDown (ignore autorepeat + keyUp). C (keycode 8) is handled
// separately below as the grab toggle.
let oneShot: [Int64: String] = [
    9:  "V",   // cycle hands
    11: "B",   // reset sandbox
    45: "N",   // toggle sky / passthrough
]

// Focus gate (task 1): is the visionOS Simulator the frontmost app? Only then do we forward.
@inline(__always) func simulatorFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iphonesimulator"
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    // Listen-only tap is global, so it fires regardless of focus. Ignore everything unless the
    // Simulator is frontmost, so we never grab input while the user is in another app.
    guard simulatorFrontmost() else { return Unmanaged.passUnretained(event) }

    switch type {
    case .leftMouseDown:
        setGrab(true)   // left-click = grab (press-and-hold), natural alongside WASD
    case .leftMouseUp:
        setGrab(false)
    case .keyDown, .keyUp:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if kc == 8 {  // C — TOGGLE grab on keyDown (not a hold, so it's comfortable with WASD)
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                setGrab(!grabbing)
            }
        } else if type == .keyDown, let packet = oneShot[kc] {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { send(packet) }
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

// Auto-release the grab when the Simulator loses focus: while focus-gated out we'd miss the
// release key/click, so a toggled-on grab would otherwise stay stuck "held" until you returned.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didDeactivateApplicationNotification,
    object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if app?.bundleIdentifier == "com.apple.iphonesimulator" { setGrab(false) }
}

print("SimInputTap active — focus the SIMULATOR. WASD/Option-drag = move/look, C = grab toggle (or hold left-click), V = hands, B = reset, N = sky. Ctrl-C to quit.")
CFRunLoopRun()
