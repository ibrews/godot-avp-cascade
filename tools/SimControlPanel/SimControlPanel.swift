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
//      Verbs: C1/C0 grab down/up · B reset sandbox · V cycle hands · N toggle immersion.
//      NEW calibration verbs: "K<key><float>" / "KR" (reset) — see SimController.sendCalib.
//      Loopback needs no Local Network permission.
//
//   2. MultipeerConnectivity, serviceType "Bonjour"  (from tools/simhands_canned_sender.swift)
//      → modules/visionos_xr/simhands_bridge.mm (clancey fork), which feeds the stream into
//      XRHandTracker when launched with GODOT_SIMHANDS=1. Same MC contract as VisionOS-SimHands'
//      BonjourSession, so if this connects, the real webcam helper will too. We send the same
//      21-landmark JSON, but with MANUAL pinch (panel-driven) instead of the canned sine loop.
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
/// — except the pinch is driven on demand by the panel (open ⇄ pinch) instead of a sine loop.
final class SimHandsFeed: NSObject, MCSessionDelegate,
                          MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    private let serviceType = "Bonjour"
    private let peerID = MCPeerID(displayName: "SimControlPanel")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "com.agilelens.simcontrolpanel.feed")

    /// 0 = open hand, 1 = full pinch. Set from the UI; eased toward each tick for a natural close.
    var pinchTarget: Double = 0
    private var pinch: Double = 0

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
        pinch = 0; pinchTarget = 0
        notifyPeers()
    }

    private func tick() {
        pinch += (pinchTarget - pinch) * 0.25      // ~0.1 s ease toward the target
        let data = buildJSON(pinch)
        let peers = session.connectedPeers
        guard !peers.isEmpty, !data.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func buildJSON(_ t: Double) -> Data {
        var joints: [[String: Double]] = []
        joints.reserveCapacity(21)
        for i in 0..<21 {
            let o = openHand[i], p = pinchedHand[i]
            joints.append([
                "x": o.0 * (1.0 - t) + p.0 * t,
                "y": o.1 * (1.0 - t) + p.1 * t,
                "z": 0.0,
            ])
        }
        // displayName "Left" → the bridge replicates SimHands' L/R swap → Godot RIGHT hand.
        let root: [String: Any] = [
            "landmarks": [joints],
            "handednesses": [[["displayName": "Left", "index": 0, "score": 1.0]]],
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

// MARK: - Controller (all UI state + both channels)

@MainActor @Observable
final class SimController {
    private let udp = UDPSender()
    private let feed = SimHandsFeed()

    var feedOn = false
    var pinching = false
    var connectedPeers: [String] = []

    // Calibration — defaults MIRROR simhands_bridge.mm SIMHANDS_DEF_* (keep in sync).
    var handScale = 0.09    // KS  SIMHANDS_HAND_KNUCKLE_M  (self-normalized hand size, m)
    var plane     = 0.55    // KP  SIMHANDS_PLANE_M         (x/y travel across the image plane)
    var depth     = 0.45    // KD  SIMHANDS_DEPTH_M         (wrist distance in front of origin)
    var yOffset   = -0.10   // KY  SIMHANDS_Y_OFFSET_M      (head-relative height, pre floor offset)
    var zGain     = 1.0     // KZ  SIMHANDS_Z_SHAPE_GAIN    (finger-curl depth from MediaPipe z)

    private var lastSent: [String: Date] = [:]

    init() {
        feed.onPeersChanged = { [weak self] names in
            Task { @MainActor in self?.connectedPeers = names }
        }
    }

    // One-shot scene commands (UDP → simulator_input.gd → main_v2.gd).
    func toggleImmersion() { udp.send("N") }
    func resetSandbox()    { udp.send("B") }
    func cycleHands()      { udp.send("V") }

    // Grab: press-and-hold → C1 (down) / C0 (up), same as SimInputTap's C/left-click.
    func setGrab(_ on: Bool) { udp.send(on ? "C1" : "C0") }

    // SimHands canned feed on/off (this app becomes the MC peer the bridge connects to).
    func setFeed(_ on: Bool) {
        feedOn = on
        if on { feed.start() } else { feed.stop(); connectedPeers = [] }
    }

    // Simulate pinch: drives the feed's open⇄pinch interpolation (real MC data → real pinch).
    func setPinch(_ on: Bool) {
        pinching = on
        feed.pinchTarget = on ? 1.0 : 0.0
    }

    /// Send one calibration verb. Throttled per key (≥40 ms) so a slider drag doesn't storm
    /// the cfg writer; pass force on drag-end to guarantee the final value lands.
    func sendCalib(_ key: String, _ value: Double, force: Bool = false) {
        let now = Date()
        if !force, let t = lastSent[key], now.timeIntervalSince(t) < 0.04 { return }
        lastSent[key] = now
        udp.send("K" + key + String(format: "%.4f", value))
    }

    /// Re-assert all five sliders (useful right after launch to sync the cfg to this panel).
    func pushAllCalib() {
        sendCalib("S", handScale, force: true)
        sendCalib("P", plane, force: true)
        sendCalib("D", depth, force: true)
        sendCalib("Y", yOffset, force: true)
        sendCalib("Z", zGain, force: true)
    }

    /// Reset sliders to first-light defaults and tell the bridge to drop the cfg (→ its defaults).
    func resetCalib() {
        handScale = 0.09; plane = 0.55; depth = 0.45; yOffset = -0.10; zGain = 1.0
        udp.send("KR")
    }
}

// MARK: - Reusable controls

/// A button that reports press (true) and release (false) — for grab and pinch holds.
private struct HoldButton: View {
    let title: String
    let systemImage: String
    let onChange: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(down ? Color.accentColor : Color(nsColor: .controlColor))
            .foregroundStyle(down ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; onChange(true) } }
                    .onEnded { _ in down = false; onChange(false) }
            )
    }
}

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

// MARK: - Main view

struct ContentView: View {
    @State private var c = SimController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            GroupBox("Scene") {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { c.toggleImmersion() } label: {
                            Label("Immersion", systemImage: "cube.transparent").frame(maxWidth: .infinity)
                        }
                        Button { c.cycleHands() } label: {
                            Label("Hands", systemImage: "hand.raised").frame(maxWidth: .infinity)
                        }
                        Button { c.resetSandbox() } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    HoldButton(title: "Grab (hold)", systemImage: "hand.pinch") { c.setGrab($0) }
                }
                .padding(6)
            }

            GroupBox("SimHands feed (MultipeerConnectivity)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { c.feedOn }, set: { c.setFeed($0) })) {
                        Text("Stream canned hand → bridge")
                    }
                    HoldButton(title: "Simulate pinch (hold)", systemImage: "hand.pinch.fill") { c.setPinch($0) }
                        .disabled(!c.feedOn).opacity(c.feedOn ? 1 : 0.4)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(c.connectedPeers.isEmpty ? Color.secondary : Color.green)
                            .frame(width: 8, height: 8)
                        Text(c.feedOn
                             ? (c.connectedPeers.isEmpty ? "advertising — waiting for sim…"
                                                         : "connected: \(c.connectedPeers.joined(separator: ", "))")
                             : "feed off")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(6)
            }

            GroupBox("Hand calibration (live → bridge)") {
                VStack(alignment: .leading, spacing: 7) {
                    CalibSlider(title: "Y offset (m)", key: "Y", value: $c.yOffset,
                                range: -1.0...2.0, send: send)
                    CalibSlider(title: "Depth (m)", key: "D", value: $c.depth,
                                range: 0.15...1.0, send: send)
                    CalibSlider(title: "Hand scale (m)", key: "S", value: $c.handScale,
                                range: 0.04...0.18, send: send)
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

            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // sendCalib bound for CalibSlider's closure (carries the force flag through).
    private func send(_ key: String, _ value: Double, _ force: Bool) {
        c.sendCalib(key, value, force: force)
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
        .windowResizability(.contentSize)
    }
}
