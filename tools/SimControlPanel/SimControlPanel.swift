// SimControlPanel.swift — macOS dev control panel for the Godot visionOS SIMULATOR.
//
// A regular on-screen macOS window (NOT spatial) with clickable buttons / toggles /
// sliders that drive SIMULATOR-ONLY dev settings of the Godot app
// (com.agilelens.godotvisionpilot) running in the visionOS Simulator. It has ZERO effect
// on a real headset: every channel it speaks is sim-only by construction.
//
// Two output channels — both lifted from existing, proven tools so we don't reinvent them:
//
//   1. UDP 127.0.0.1:9999  (from tools/SimInputTap.swift)
//      → test-project/simulator_input.gd, which is sim-gated via OS.has_environment.
//      Verbs: C1/C0 grab latch down/up · B full scene reset · V cycle hands · N toggle immersion ·
//      N1/N0 set immersion immersive/mixed · G<x>,<y>,<z>/GR head-tracking · H0/H1/H2 hand source ·
//      K<key><float>/KR hand calibration. Loopback needs no Local Network permission.
//
//   2. MultipeerConnectivity, serviceType "Bonjour"  (from tools/simhands_canned_sender.swift)
//      → modules/visionos_xr/simhands_bridge.mm (clancey fork), which feeds the stream into
//      XRHandTracker when launched with GODOT_SIMHANDS=1. Same MC contract as VisionOS-SimHands'
//      BonjourSession, so if this connects, the real webcam helper will too. We send the same
//      21-landmark JSON, with MANUAL pinch (momentary / loop) and a selectable driven hand.
//
// HAND SOURCE PICKER (Off / Canned / Webcam): the bridge auto-connects to every "Bonjour" peer, so
// to keep the real webcam helper, this panel, and the canned sender from fighting, the picker (a) sends
// a UDP "H" verb on 9999 so the bridge locks to one source, and (b) starts/stops THIS panel's own
// canned feed — "Canned" streams it, "Webcam"/"Off" stop it so the panel yields to the real helper.
// So every tool can stay connected at once while exactly one source drives the trackers.
//
// Calibration (hand placement Y / depth / scale, etc.) is applied in the BRIDGE, not here:
// the bridge self-normalizes hand size (shape_scale = KNUCKLE / measured-span), so perturbing
// the normalized landmarks we send can't change metric hand size — and tuning in the bridge
// also calibrates the REAL webcam helper, not just our canned feed. So calibration rides the
// 9999 channel → simulator_input.gd → user://simhands_calibration.cfg → bridge re-reads live.
//
// BUILD:  ./tools/SimControlPanel/build.sh      (swiftc → ad-hoc-signed .app)
// RUN:    open tools/SimControlPanel/SimControlPanel.app
//
// See tools/SimControlPanel/README.md and KB godot-avp-simulator-dev-tools.md.

import SwiftUI
import Network
import MultipeerConnectivity

// MARK: - UDP command channel (127.0.0.1:9999 → simulator_input.gd)

/// Fire-and-forget ASCII packets over loopback UDP. Lifted from SimInputTap's send path.
final class UDPSender {
    private let conn: NWConnection
    init(host: String = "127.0.0.1", port: UInt16 = 9999) {
        conn = NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: .udp)
        conn.start(queue: .global())
    }
    func send(_ s: String) {
        conn.send(content: s.data(using: .ascii), completion: .idempotent)
    }
}

// MARK: - SimHands MC feed (serviceType "Bonjour" → simhands_bridge.mm)

/// Native MultipeerConnectivity peer that advertises + browses the "Bonjour" service and
/// streams 21-landmark MediaPipe hand JSON at 30 Hz, exactly like simhands_canned_sender.swift
/// — except the pinch is driven on demand by the panel (momentary tap / continuous loop) and the
/// driven Godot hand (left/right) is selectable.
final class SimHandsFeed: NSObject, MCSessionDelegate,
                          MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    private let serviceType = "Bonjour"
    private let peerID = MCPeerID(displayName: "SimControlPanel")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "com.agilelens.simcontrolpanel.feed")

    /// 0 = open hand, 1 = full pinch. Eased toward each tick for a natural close.
    var pinchTarget: Double = 0
    private var pinch: Double = 0
    /// Continuously cycle open⇄pinch (panel "Loop" checkbox). Owns pinchTarget while on.
    var loopPinch = false
    /// Which Godot hand the feed drives. false → send displayName "Left" → Godot RIGHT (the default);
    /// true → send "Right" → Godot LEFT, with the landmark x mirrored so it reads as a left hand.
    var feedHandIsLeft = false

    private var tickCount = 0
    private var releaseAtTick: Int? = nil   // momentary pinch: auto-release at this tick

    /// Called (on main) whenever the connected-peer set changes.
    var onPeersChanged: (([String]) -> Void)?

    // MediaPipe-style normalized landmarks (x: 0=left,1=right; y: 0=top,1=bottom).
    // A right hand, palm to camera, fingers up. 21 landmarks in MediaPipe order.
    // Identical table to tools/simhands_canned_sender.swift.
    private let openHand: [(Double, Double)] = [
        (0.50, 0.80), (0.42, 0.74), (0.37, 0.68), (0.34, 0.62), (0.31, 0.57),
        (0.46, 0.58), (0.45, 0.48), (0.44, 0.41), (0.44, 0.35),
        (0.52, 0.57), (0.52, 0.46), (0.52, 0.38), (0.52, 0.32),
        (0.58, 0.58), (0.59, 0.48), (0.60, 0.41), (0.61, 0.36),
        (0.64, 0.61), (0.66, 0.53), (0.67, 0.47), (0.68, 0.43),
    ]
    private var pinchedHand: [(Double, Double)] = []

    override init() {
        super.init()
        // Index pip/dip/tip curl in to meet the thumb tip (a pinch) — same offsets as the canned sender.
        pinchedHand = openHand
        pinchedHand[6] = (0.43, 0.52)
        pinchedHand[7] = (0.38, 0.55)
        pinchedHand[8] = (0.33, 0.56)

        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        pinch = 0; pinchTarget = 0; loopPinch = false; releaseAtTick = nil
        notifyPeers()
    }

    /// Momentary single pinch + release. Closes now, auto-opens after ~0.27 s (on the feed queue so
    /// it composes with the tick loop). No-op feel if looping is on (loop owns the target).
    func pinchOnce() {
        q.async { [weak self] in
            guard let self else { return }
            self.pinchTarget = 1.0
            self.releaseAtTick = self.tickCount + 8   // ~0.27 s @ 30 Hz
        }
    }

    private func tick() {
        tickCount += 1
        if loopPinch {
            // ~1.2 s cycle: pinch for the first half, release for the second.
            pinchTarget = (tickCount % 36 < 18) ? 1.0 : 0.0
            releaseAtTick = nil
        } else if let r = releaseAtTick, tickCount >= r {
            pinchTarget = 0.0
            releaseAtTick = nil
        }
        pinch += (pinchTarget - pinch) * 0.25      // ~0.1 s ease toward the target
        let data = buildJSON(pinch)
        let peers = session.connectedPeers
        guard !peers.isEmpty, !data.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func buildJSON(_ t: Double) -> Data {
        let mirror = feedHandIsLeft
        // displayName "Left" → bridge → Godot RIGHT; "Right" → Godot LEFT (the bridge replicates
        // SimHands' L/R swap). Mirror x for the left hand so the shape reads as a left hand, not a
        // right hand on the left tracker (the bridge's chirality flip handles the rig mirror).
        let displayName = mirror ? "Right" : "Left"
        var joints: [[String: Double]] = []
        joints.reserveCapacity(21)
        for i in 0..<21 {
            let o = openHand[i], p = pinchedHand[i]
            var x = o.0 * (1.0 - t) + p.0 * t
            let y = o.1 * (1.0 - t) + p.1 * t
            if mirror { x = 1.0 - x }
            joints.append(["x": x, "y": y, "z": 0.0])
        }
        let root: [String: Any] = [
            "landmarks": [joints],
            "handednesses": [[["displayName": displayName, "index": 0, "score": 1.0]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private func notifyPeers() {
        let names = session?.connectedPeers.map { $0.displayName } ?? []
        let cb = onPeersChanged
        DispatchQueue.main.async { cb?(names) }
    }

    // Browser: auto-invite (mirrors BonjourSession .automatic).
    func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        b.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}

    // Advertiser: auto-accept (mirrors BonjourSession security.default).
    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    // Session.
    func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) { notifyPeers() }
    func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    func session(_ s: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true) // encryption is .none (matches SimHands) — accept.
    }
}

// MARK: - Hand source + driven-hand selection

/// Which feed the SimHands bridge should let drive the trackers. The bridge auto-connects to EVERY
/// "Bonjour" peer (real webcam helper, this panel's canned feed, the canned-sender CLI), so without a
/// single-source rule their frames fight. The panel sends the matching UDP "H" verb
/// (→ simulator_input.gd → user://simhands_calibration.cfg → bridge) AND starts/stops its OWN canned
/// feed so it yields to the real helper in .webcam/.off. Raw value = the bridge's SimHandsSource int.
enum HandSource: Int, CaseIterable, Identifiable {
    case off = 0, canned = 1, webcam = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .canned: return "Canned"
        case .webcam: return "Webcam"
        }
    }
}

/// Which Godot hand the panel's canned feed drives. The canned table is one hand at a time.
enum FeedHand: Int, CaseIterable, Identifiable {
    case left = 0, right = 1
    var id: Int { rawValue }
    var label: String { self == .left ? "Left" : "Right" }
}

// MARK: - Controller (all UI state + both channels)

@MainActor @Observable
final class SimController {
    private let udp = UDPSender()
    private let feed = SimHandsFeed()

    var handSource: HandSource = .off
    var feedHand: FeedHand = .right       // canned feed drives Godot RIGHT by default (legacy behavior)
    var pinchLooping = false
    var grabLatched = false               // #3: Grab is a latching toggle, not a hold
    var immersive = true                  // #1: seeded to the launch default (main_v2 boots immersive)
    var connectedPeers: [String] = []

    // Head-tracking prototype (#7). The pad + z slider drive a fake head position (normalized -1..1);
    // simulator_input.gd maps it to an XROrigin offset (smoothed, clamped, hand-scale-multiplied).
    var headTracking = false
    var headKnob: CGPoint = .zero         // pad position, -1..1 (y up); bound to the HeadPad
    var headZ: Double = 0                 // forward/back, -1..1

    // Calibration — defaults MIRROR simhands_bridge.mm SIMHANDS_DEF_* (keep in sync).
    var handScale = 0.09    // KS  SIMHANDS_HAND_KNUCKLE_M  (self-normalized hand size, m)
    var plane     = 0.55    // KP  SIMHANDS_PLANE_M         (x/y travel across the image plane)
    var depth     = 0.45    // KD  SIMHANDS_DEPTH_M         (wrist distance in front of origin)
    var yOffset   = -0.10   // KY  SIMHANDS_Y_OFFSET_M      (head-relative height, pre floor offset)
    var zGain     = 1.0     // KZ  SIMHANDS_Z_SHAPE_GAIN    (finger-curl depth from MediaPipe z)
    var smoothing = 0.9     // KM  SIMHANDS_SMOOTHING       (0=raw .. 1=heavy .. 3=glassy promo capture)

    private var lastSent: [String: Date] = [:]

    init() {
        feed.onPeersChanged = { [weak self] names in
            Task { @MainActor in self?.connectedPeers = names }
        }
    }

    // --- Scene (UDP → simulator_input.gd → main_v2.gd) ---

    /// Explicit immersion set (#1): N1 = immersive (opaque sky), N0 = mixed (passthrough). The panel is
    /// the only immersion controller in the sim, so it stays authoritative and labels the state.
    func setImmersion(_ on: Bool) {
        immersive = on
        udp.send(on ? "N1" : "N0")
    }
    func cycleHands() { udp.send("V") }
    /// Full scene reset (#2): simulator_input.gd's "B" now also restarts the round (fresh cascade).
    func resetSandbox() { udp.send("B") }

    /// Grab (#3): a LATCHING toggle. Click once → hold the grab (C1); if it latched onto an object you
    /// keep holding it (rigid-to-head, even while WASD-driving) until you click again to release (C0).
    func toggleGrab() {
        grabLatched.toggle()
        udp.send(grabLatched ? "C1" : "C0")
    }

    // --- Hand source + driven hand ---

    /// Select which feed drives the SimHands bridge. Sends the UDP "H" verb so the bridge restricts
    /// itself to that source, AND starts/stops THIS app's canned feed so it yields to the real webcam
    /// helper in .webcam/.off — every feed can stay connected while only the selected one drives.
    func setHandSource(_ src: HandSource) {
        handSource = src
        udp.send("H\(src.rawValue)")            // → simulator_input.gd → cfg → bridge forced source
        if src == .canned {
            feed.start()                         // advertise + stream our canned hand
        } else {
            setPinchLoop(false)                  // pinch/loop only apply to our own canned feed
            feed.stop()                          // yield: stop advertising/sending → helper takes over
            connectedPeers = []
        }
    }

    /// Which Godot hand the canned feed drives (#4). Effective immediately on the next feed tick.
    func setFeedHand(_ hand: FeedHand) {
        feedHand = hand
        feed.feedHandIsLeft = (hand == .left)
    }

    // --- Pinch (canned feed) ---

    /// Momentary single pinch + release (#3).
    func pinchOnce() { feed.pinchOnce() }

    /// Continuous pinch/release loop (#3). Off also forces the hand open.
    func setPinchLoop(_ on: Bool) {
        pinchLooping = on
        feed.loopPinch = on
        if !on { feed.pinchTarget = 0 }
    }

    // --- Head tracking (#7) ---

    func setHeadTracking(_ on: Bool) {
        headTracking = on
        if on {
            sendHead()                           // engage at the current pad position
        } else {
            headKnob = .zero; headZ = 0
            udp.send("GR")                       // disengage + recenter the viewpoint
        }
    }
    func recenterHead() {
        headKnob = .zero; headZ = 0
        udp.send("GR")
    }
    /// Emit the current fake head position. Throttled like the calibration sliders.
    func sendHead(force: Bool = false) {
        guard headTracking else { return }
        let now = Date()
        if !force, let t = lastSent["G"], now.timeIntervalSince(t) < 0.03 { return }
        lastSent["G"] = now
        udp.send(String(format: "G%.3f,%.3f,%.3f", headKnob.x, headKnob.y, headZ))
    }

    // --- Calibration ---

    /// Send one calibration verb. Throttled per key (≥40 ms) so a slider drag doesn't storm
    /// the cfg writer; pass force on drag-end to guarantee the final value lands.
    func sendCalib(_ key: String, _ value: Double, force: Bool = false) {
        let now = Date()
        if !force, let t = lastSent[key], now.timeIntervalSince(t) < 0.04 { return }
        lastSent[key] = now
        udp.send("K" + key + String(format: "%.4f", value))
    }

    /// Re-assert all sliders (useful right after launch to sync the cfg to this panel).
    func pushAllCalib() {
        sendCalib("S", handScale, force: true)
        sendCalib("P", plane, force: true)
        sendCalib("D", depth, force: true)
        sendCalib("Y", yOffset, force: true)
        sendCalib("Z", zGain, force: true)
        sendCalib("M", smoothing, force: true)
    }

    /// Reset sliders to first-light defaults and tell the bridge to drop the cfg (→ its defaults).
    func resetCalib() {
        handScale = 0.09; plane = 0.55; depth = 0.45; yOffset = -0.10; zGain = 1.0; smoothing = 0.9
        udp.send("KR")
        udp.send("H\(handSource.rawValue)")  // KR deletes the cfg (→ source AUTO) — re-assert the pick
    }
}

// MARK: - Reusable controls

private struct CalibSlider: View {
    let title: String
    let key: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let send: (String, Double, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range,
                   onEditingChanged: { editing in if !editing { send(key, value, true) } })
                .controlSize(.small)
                .onChange(of: value) { _, v in send(key, v, false) }
        }
    }
}

/// A 2D drag pad emitting a normalized position in [-1,1]² (y up). Drives the fake head signal (#7).
private struct HeadPad: View {
    let enabled: Bool
    @Binding var pos: CGPoint
    let onMove: () -> Void
    private let side: CGFloat = 128

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))
            Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1, height: side)
            Rectangle().fill(.secondary.opacity(0.25)).frame(width: side, height: 1)
            Circle()
                .fill(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
                .offset(x: pos.x * (side / 2 - 9), y: -pos.y * (side / 2 - 9))
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard enabled else { return }
                    let nx = max(-1, min(1, Double((v.location.x - side / 2) / (side / 2))))
                    let ny = max(-1, min(1, Double(-(v.location.y - side / 2) / (side / 2))))
                    pos = CGPoint(x: nx, y: ny)
                    onMove()
                }
        )
        .disabled(!enabled)
    }
}

// MARK: - Main view

struct ContentView: View {
    @State private var c = SimController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                sceneGroup
                grabGroup
                sourceGroup
                calibrationGroup
                headGroup
                footer
            }
            .padding(16)
            .frame(width: 360)
        }
        // Resizable + scrollable: ideal height fits a laptop screen (head pad clear of the dock);
        // the ScrollView reaches everything when shorter, and Alex can drag it taller.
        .frame(minWidth: 360, idealWidth: 360, maxWidth: 360,
               minHeight: 460, idealHeight: 740, maxHeight: .infinity)
    }

    // MARK: Scene

    private var sceneGroup: some View {
        GroupBox("Scene") {
            VStack(spacing: 8) {
                // #1: immersion shows + sets the actual state (panel is authoritative via N0/N1).
                Picker("View mode", selection: Binding(get: { c.immersive }, set: { c.setImmersion($0) })) {
                    Text("Mixed").tag(false)
                    Text("Immersive").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    Button { c.cycleHands() } label: {
                        Label("Hands", systemImage: "hand.raised").frame(maxWidth: .infinity)
                    }
                    Button { c.resetSandbox() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(6)
        }
    }

    // MARK: Grab

    private var grabGroup: some View {
        GroupBox("Grab") {
            VStack(alignment: .leading, spacing: 6) {
                Button { c.toggleGrab() } label: {
                    Label(c.grabLatched ? "Holding — click to release" : "Grab",
                          systemImage: c.grabLatched ? "hand.raised.fill" : "hand.raised.app")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(c.grabLatched ? Color.accentColor : Color(nsColor: .controlColor))
                        .foregroundStyle(c.grabLatched ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Latching toggle — reach an object at the view centre, click to hold it (carries with the head while you WASD-drive), click again to release.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    // MARK: Hand source

    private var sourceGroup: some View {
        GroupBox("Hand source (MultipeerConnectivity)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Hand source",
                       selection: Binding(get: { c.handSource }, set: { c.setHandSource($0) })) {
                    ForEach(HandSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(sourceHelp)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // #4: which Godot hand the canned feed drives.
                HStack {
                    Text("Drives").font(.caption).foregroundStyle(.secondary)
                    Picker("Drives", selection: Binding(get: { c.feedHand }, set: { c.setFeedHand($0) })) {
                        ForEach(FeedHand.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(c.handSource != .canned)
                    .opacity(c.handSource == .canned ? 1 : 0.4)
                }

                // #3: momentary pinch + loop checkbox (canned feed only).
                HStack(spacing: 8) {
                    Button { c.pinchOnce() } label: {
                        Label("Pinch", systemImage: "hand.pinch").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(c.handSource != .canned || c.pinchLooping)
                    Toggle(isOn: Binding(get: { c.pinchLooping }, set: { c.setPinchLoop($0) })) {
                        Text("Loop")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(c.handSource != .canned)
                }
                .opacity(c.handSource == .canned ? 1 : 0.4)

                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(6)
        }
    }

    // MARK: Calibration

    private var calibrationGroup: some View {
        GroupBox("Hand calibration (live → bridge)") {
            VStack(alignment: .leading, spacing: 7) {
                CalibSlider(title: "Y offset (m)", key: "Y", value: $c.yOffset,
                            range: -1.0...2.0, send: send)
                CalibSlider(title: "Depth (m)", key: "D", value: $c.depth,
                            range: 0.15...1.0, send: send)
                CalibSlider(title: "Hand scale (m) → size + travel", key: "S", value: $c.handScale,
                            range: 0.04...0.18, send: send)
                CalibSlider(title: "Smoothing (0 raw · 1 heavy · 3 glassy)", key: "M", value: $c.smoothing,
                            range: 0.0...3.0, send: send)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 7) {
                        CalibSlider(title: "Plane (m)", key: "P", value: $c.plane,
                                    range: 0.2...1.2, send: send)
                        CalibSlider(title: "Z gain", key: "Z", value: $c.zGain,
                                    range: 0.0...3.0, send: send)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                HStack(spacing: 8) {
                    Button { c.pushAllCalib() } label: {
                        Label("Apply all", systemImage: "arrow.up.circle").frame(maxWidth: .infinity)
                    }
                    Button { c.resetCalib() } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(6)
        }
    }

    // MARK: Head tracking (#7)

    private var headGroup: some View {
        GroupBox("Head tracking (sim · prototype)") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { c.headTracking }, set: { c.setHeadTracking($0) })) {
                    Text("Move the viewpoint with a fake head signal")
                }
                HStack(alignment: .top, spacing: 12) {
                    HeadPad(enabled: c.headTracking, pos: $c.headKnob) { c.sendHead() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Forward / back").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { c.headZ }, set: { c.headZ = $0; c.sendHead() }),
                               in: -1.0...1.0)
                            .controlSize(.small)
                            .disabled(!c.headTracking)
                        Button { c.recenterHead() } label: {
                            Label("Recenter", systemImage: "scope").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!c.headTracking)
                        Text("Prototype: drag the pad to move your head; travel scales with Hand scale. Webcam face detection feeds the same path later.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(6)
        }
    }

    // sendCalib bound for CalibSlider's closure (carries the force flag through).
    private func send(_ key: String, _ value: Double, _ force: Bool) {
        c.sendCalib(key, value, force: force)
    }

    // Hand-source picker help + connection status (reflects THIS panel's canned feed; in .webcam/.off
    // the panel feed is stopped so the real helper — or nothing — drives via the bridge's lock).
    private var sourceHelp: String {
        switch c.handSource {
        case .off: return "Hands hidden — the bridge ignores every feed."
        case .canned: return "This panel streams a canned hand. Use Pinch / Loop."
        case .webcam: return "Yields to the real VisionOS-SimHands webcam helper."
        }
    }
    private var statusColor: Color {
        switch c.handSource {
        case .off: return .secondary
        case .canned: return c.connectedPeers.isEmpty ? .orange : .green
        case .webcam: return .blue
        }
    }
    private var statusText: String {
        switch c.handSource {
        case .off: return "hands off"
        case .canned: return c.connectedPeers.isEmpty
            ? "advertising — waiting for sim…"
            : "driving \(c.feedHand.label): \(c.connectedPeers.joined(separator: ", "))"
        case .webcam: return "yielded to webcam helper"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Godot Sim Control Panel").font(.headline)
            Text("visionOS Simulator dev tooling · UDP 127.0.0.1:9999")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Text("Simulator-only. No effect on a real Apple Vision Pro.")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}

// MARK: - App

@main
struct SimControlPanelApp: App {
    var body: some Scene {
        WindowGroup("Godot Sim Control Panel") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
