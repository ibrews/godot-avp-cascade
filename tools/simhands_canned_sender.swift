// simhands_canned_sender.swift
//
// Deterministic stand-in for the VisionOS-SimHands macOS helper, for autonomously
// testing the native engine bridge (simhands_bridge.mm) WITHOUT a webcam or a human.
//
// It speaks the SAME MultipeerConnectivity contract as SimHands' BonjourSession
// (serviceType "Bonjour", encryption .none, usage .combined = advertise + browse +
// auto-invite + auto-accept) and broadcasts the SAME JSON shape:
//   {"landmarks":[[{"x":..,"y":..,"z":..} x21]],
//    "handednesses":[[{"displayName":"Left"}]]}
// at ~30 Hz, animating ONE right hand whose index finger pinches the thumb and
// releases on a ~4 s sine loop — so a pinch deterministically crosses the game's
// 0.024 m threshold and back.
//
// Because it exercises the exact MC discovery/connect/data path, if the sim app
// connects to THIS, it will also connect to the real SimHands helper.
//
// Build & run (macOS):
//   swiftc -O tools/simhands_canned_sender.swift -o tools/simhands_canned_sender
//   ./tools/simhands_canned_sender
// First run may prompt for Local Network access — allow it. Leave it running while
// the sim app (launched with GODOT_SIMHANDS=1) is in the immersive scene.
//
// Handedness note: this emits displayName "Left"; the bridge replicates SimHands'
// MediaPipe L/R swap, so it drives Godot's RIGHT hand (/user/hand_tracker/right).

import Foundation
import MultipeerConnectivity

let serviceType = "Bonjour"

// MediaPipe-style normalized landmarks (x: 0=left,1=right; y: 0=top,1=bottom).
// A right hand, palm to camera, fingers up. 21 landmarks in MediaPipe order.
let openHand: [(Double, Double)] = [
    (0.50, 0.80), // 0  wrist
    (0.42, 0.74), // 1  thumb cmc
    (0.37, 0.68), // 2  thumb mcp
    (0.34, 0.62), // 3  thumb ip
    (0.31, 0.57), // 4  thumb tip
    (0.46, 0.58), // 5  index mcp (knuckle)
    (0.45, 0.48), // 6  index pip
    (0.44, 0.41), // 7  index dip
    (0.44, 0.35), // 8  index tip
    (0.52, 0.57), // 9  middle mcp (knuckle)
    (0.52, 0.46), // 10 middle pip
    (0.52, 0.38), // 11 middle dip
    (0.52, 0.32), // 12 middle tip
    (0.58, 0.58), // 13 ring mcp
    (0.59, 0.48), // 14 ring pip
    (0.60, 0.41), // 15 ring dip
    (0.61, 0.36), // 16 ring tip
    (0.64, 0.61), // 17 pinky mcp
    (0.66, 0.53), // 18 pinky pip
    (0.67, 0.47), // 19 pinky dip
    (0.68, 0.43), // 20 pinky tip
]

// Same hand, but the index finger curled in to meet the thumb tip (a pinch).
var pinchedHand: [(Double, Double)] = openHand
// index pip / dip / tip swing toward thumb tip (0.31, 0.57)
pinchedHand[6] = (0.43, 0.52)
pinchedHand[7] = (0.38, 0.55)
pinchedHand[8] = (0.33, 0.56)

func buildJSON(_ t: Double) -> Data {
    var joints: [[String: Double]] = []
    joints.reserveCapacity(21)
    for i in 0..<21 {
        let o = openHand[i]
        let p = pinchedHand[i]
        joints.append([
            "x": o.0 * (1.0 - t) + p.0 * t,
            "y": o.1 * (1.0 - t) + p.1 * t,
            "z": 0.0,
        ])
    }
    let root: [String: Any] = [
        "landmarks": [joints],
        "handednesses": [[["displayName": "Left", "index": 0, "score": 1.0]]],
    ]
    return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
}

final class CannedSender: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    let peerID = MCPeerID(displayName: "SimHandsCanned")
    let session: MCSession
    let advertiser: MCNearbyServiceAdvertiser
    let browser: MCNearbyServiceBrowser
    var lastConnectedCount = 0

    override init() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        print("[canned] advertising + browsing service '\(serviceType)' as '\(peerID.displayName)' — waiting for the sim app…")
    }

    func broadcast(_ data: Data) {
        let peers = session.connectedPeers
        if peers.count != lastConnectedCount {
            print("[canned] connected peers: \(peers.map { $0.displayName })")
            lastConnectedCount = peers.count
        }
        guard !peers.isEmpty, !data.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    // Browser: auto-invite (mirrors BonjourSession .automatic).
    func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        print("[canned] found peer '\(peerID.displayName)' — inviting")
        b.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("[canned] lost peer '\(peerID.displayName)'")
    }
    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[canned] browse error: \(error.localizedDescription)")
    }

    // Advertiser: auto-accept (mirrors BonjourSession security.default).
    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("[canned] invitation from '\(peerID.displayName)' — accepting")
        invitationHandler(true, session)
    }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[canned] advertise error: \(error.localizedDescription)")
    }

    // Session.
    func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = ["notConnected", "connecting", "connected"][min(state.rawValue, 2)]
        print("[canned] peer '\(peerID.displayName)' → \(name)")
    }
    func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

let sender = CannedSender()
sender.start()

let startDate = Date()
let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
    let elapsed = Date().timeIntervalSince(startDate)
    // sine 0→1→0; full pinch at the peak, full open at the trough; ~4 s period.
    let t = sin(elapsed * 2.0 * Double.pi / 4.0) * 0.5 + 0.5
    sender.broadcast(buildJSON(t))
}
RunLoop.main.add(timer, forMode: .common)
print("[canned] streaming canned hand at 30 Hz (4 s pinch/release loop). Ctrl-C to stop.")
RunLoop.main.run()
