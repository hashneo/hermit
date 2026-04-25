import Foundation
import MultipeerConnectivity

// MARK: - hermit-1ow: Multipeer Connectivity pairing handshake

// ─────────────────────────────────────────────────────────────────────────────
// OVERVIEW
//
// Mac (PairingAdvertiser)  ←→  iPad (PairingBrowser)
//
// 1. Mac advertises via MCNearbyServiceAdvertiser ("hermit-pair").
// 2. iPad discovers via MCNearbyServiceBrowser, sends invite.
// 3. User accepts on Mac — confirmation alert shown by PairingAdvertiser.
// 4. MCSession established; Mac generates 256-bit random token.
// 5. Mac sends JSON {"token":"<hex>"} over encrypted MCSession channel.
// 6. Both sides store token in Keychain.
// 7. MCSession closed — pairing complete.
//
// Subsequent API calls (local network mode) include the token as
//   Authorization: Bearer <token>
//
// The Go server middleware validates Bearer tokens against the in-memory
// token map populated at launch from Keychain storage.
// ─────────────────────────────────────────────────────────────────────────────

private let pairingServiceType = "hermit-pair"

// MARK: - Shared token store (Go server side bridge)

/// In-memory store of (peerID displayName → token) that the Go server
/// middleware reads to authorise local-network requests.
///
/// Populated at app launch from Keychain; updated when a new device pairs.
@MainActor
final class PairedTokenStore: ObservableObject {
    static let shared = PairedTokenStore()
    private init() {}

    @Published private(set) var pairedDevices: [String: String] = [:] // displayName → token

    func load() {
        // Load all persisted tokens from Keychain
        pairedDevices = KeychainHelper.shared.loadPairedTokens()
    }

    func add(peerName: String, token: String) {
        pairedDevices[peerName] = token
        KeychainHelper.shared.savePairedToken(peerName: peerName, token: token)
    }

    func revoke(peerName: String) {
        pairedDevices.removeValue(forKey: peerName)
        KeychainHelper.shared.deletePairedToken(peerName: peerName)
    }

    func token(for peerName: String) -> String? {
        pairedDevices[peerName]
    }
}

// MARK: - PairingAdvertiser (macOS)

#if os(macOS)
/// Runs on the Mac. Advertises the hermit-pair service, accepts invitations,
/// generates a token, and sends it to the paired iPad over an encrypted MCSession.
@MainActor
final class PairingAdvertiser: NSObject, ObservableObject {

    @Published var pendingInvitation: PendingInvitation? = nil
    @Published var pairingStatus: String = ""

    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    private let myPeerID = MCPeerID(displayName: Host.current().localizedName ?? "Hermit Mac")

    struct PendingInvitation {
        let peerName: String
        let accept: () -> Void
        let decline: () -> Void
    }

    func start() {
        let adv = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["version": "1"],
            serviceType: pairingServiceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        pairingStatus = "Advertising for pairing"
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        pairingStatus = ""
    }
}

extension PairingAdvertiser: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                     didReceiveInvitationFromPeer peerID: MCPeerID,
                     withContext context: Data?,
                     invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let sess = MCSession(peer: self.myPeerID,
                                 securityIdentity: nil,
                                 encryptionPreference: .required)
            sess.delegate = self
            self.session = sess

            self.pendingInvitation = PendingInvitation(
                peerName: peerID.displayName,
                accept: {
                    invitationHandler(true, sess)
                },
                decline: {
                    invitationHandler(false, nil)
                    Task { @MainActor in self.pendingInvitation = nil }
                }
            )
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                     didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.pairingStatus = "Advertising failed: \(error.localizedDescription)" }
    }
}

extension PairingAdvertiser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession,
                  peer peerID: MCPeerID,
                  didChange state: MCSessionState) {
        guard state == .connected else { return }
        Task { @MainActor in
            self.pendingInvitation = nil
            self.sendToken(to: peerID, session: session)
        }
    }

    @MainActor
    private func sendToken(to peer: MCPeerID, session: MCSession) {
        // Generate 32-byte (256-bit) random token
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let payload: [String: String] = ["token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            PairedTokenStore.shared.add(peerName: peer.displayName, token: token)
            pairingStatus = "Paired with \(peer.displayName)"
        } catch {
            pairingStatus = "Failed to send token: \(error.localizedDescription)"
        }

        // Tear down the pairing session — API calls use HTTP Bearer from here
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            session.disconnect()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                  withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                  fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                  fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif

// MARK: - PairingBrowser (iOS/iPadOS)

#if os(iOS)
/// Runs on the iPad. Discovers the Mac's hermit-pair service, sends an
/// invitation, and stores the token received from the Mac.
@MainActor
final class PairingBrowser: NSObject, ObservableObject {

    @Published var discoveredMacs: [MCPeerID] = []
    @Published var pairingStatus: String = ""
    @Published var isPaired = false

    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

    func start() {
        let b = MCNearbyServiceBrowser(peer: myPeerID, serviceType: pairingServiceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
        pairingStatus = "Scanning for Macs…"
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        pairingStatus = ""
    }

    func invite(peer: MCPeerID) {
        let sess = MCSession(peer: myPeerID,
                             securityIdentity: nil,
                             encryptionPreference: .required)
        sess.delegate = self
        session = sess
        browser?.invitePeer(peer, to: sess, withContext: nil, timeout: 30)
        pairingStatus = "Waiting for \(peer.displayName) to accept…"
    }
}

extension PairingBrowser: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                  foundPeer peerID: MCPeerID,
                  withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.discoveredMacs.contains(peerID) {
                self.discoveredMacs.append(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.discoveredMacs.removeAll { $0 == peerID } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.pairingStatus = "Browse failed: \(error.localizedDescription)" }
    }
}

extension PairingBrowser: MCSessionDelegate {
    nonisolated func session(_ session: MCSession,
                  peer peerID: MCPeerID,
                  didChange state: MCSessionState) {
        guard state == .connected else { return }
        Task { @MainActor in self.pairingStatus = "Connected — waiting for token…" }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = payload["token"] else { return }
        Task { @MainActor in
            KeychainHelper.shared.localNetworkToken = token
            self.isPaired = true
            self.pairingStatus = "Paired with \(peerID.displayName)"
            session.disconnect()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                  withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                  fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                  fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif
