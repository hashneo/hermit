import Foundation
import MultipeerConnectivity
#if os(macOS)
import SystemConfiguration
#endif

// MARK: - hermit-1ow: Multipeer Connectivity pairing handshake
//
// ─────────────────────────────────────────────────────────────────────────────
// DESIGN
//
// Mac (PairingAdvertiser) — always advertising via MCNearbyServiceAdvertiser.
//   discoveryInfo carries everything the iPad needs to connect:
//     "port"     — server listen port
//     "owner"    — repo owner
//     "repo"     — repo name
//     "docsPath" — docs path
//     "rfcLabel" — RFC label
//
// iPad (PairingBrowser) — runs forever in the background.
//   foundPeer  → reads discoveryInfo, updates AppState (server URL + repo config)
//   lostPeer   → clears serverBaseURL so the UI stops trying to connect
//
// Pairing (one-time token exchange):
//   1. iPad invites Mac via MCSession
//   2. Mac accepts, generates a 256-bit random token, sends ONLY {"token":"<hex>"}
//   3. iPad stores token; all future API calls use Authorization: Bearer <token>
//   4. Session torn down — server URL always comes from mDNS, never from session data
//
// If the Mac's port changes, the advertiser restarts with the new port.
// The iPad's browser picks up the new discoveryInfo on the next foundPeer event.
// ─────────────────────────────────────────────────────────────────────────────

private let pairingServiceType = "hermit-pair"

// MARK: - Shared token store (Mac side — Go server bridge)

@MainActor
final class PairedTokenStore: ObservableObject {
    static let shared = PairedTokenStore()
    private init() {}

    @Published private(set) var pairedDevices: [String: String] = [:]

    func load() {
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
}

// MARK: - PairingAdvertiser (macOS)

#if os(macOS)
/// Always-on advertiser. Restarts when serverBaseURL changes so discoveryInfo
/// stays current. The iPad derives the server URL purely from discoveryInfo —
/// nothing is sent over the MCSession except the auth token.
@MainActor
final class PairingAdvertiser: NSObject, ObservableObject {
    static let shared = PairingAdvertiser()

    @Published var pendingInvitation: PendingInvitation? = nil
    @Published var pairingStatus: String = ""

    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    // Use SCDynamicStoreCopyLocalHostName — this is the mDNS name (scutil --get LocalHostName),
    // NOT Host.current().localizedName which is the computer name and may not resolve.
    private let myPeerID = MCPeerID(
        displayName: SCDynamicStoreCopyLocalHostName(nil) as String? ?? "hermit-mac"
    )

    struct PendingInvitation {
        let peerName: String
        let accept: () -> Void
        let decline: () -> Void
    }

    func start() {
        advertiser?.stopAdvertisingPeer()
        let port = AppState.shared.serverBaseURL
            .split(separator: ":").last.flatMap { String($0) } ?? "8080"
        let info: [String: String] = [
            "port":     port,
            "owner":    AppState.shared.repoOwner,
            "repo":     AppState.shared.repoName,
            "docsPath": AppState.shared.docsPath,
            "rfcLabel": AppState.shared.rfcLabel,
        ]
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID,
                                            discoveryInfo: info,
                                            serviceType: pairingServiceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        pairingStatus = "Advertising"
        let msg = "[\(Date())] [PairingAdvertiser] started advertising on port \(port)\n"
        if let data = msg.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: "/tmp/hermit-native-debug.log") {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        }
    }

    func restart() {
        let msg = "[\(Date())] [PairingAdvertiser] restart() called — serverBaseURL=\(AppState.shared.serverBaseURL)\n"
        if let data = msg.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: "/tmp/hermit-native-debug.log") {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        }
        start()
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
                accept:  { invitationHandler(true, sess) },
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
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Only the token — iPad gets server URL from mDNS discoveryInfo, not here.
        guard let data = try? JSONSerialization.data(withJSONObject: ["token": token]) else { return }

        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            PairedTokenStore.shared.add(peerName: peer.displayName, token: token)
            pairingStatus = "Paired with \(peer.displayName)"
        } catch {
            pairingStatus = "Failed to send token: \(error.localizedDescription)"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.disconnect() }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif

// MARK: - PairingBrowser (iOS/iPadOS)

#if os(iOS)
/// Runs forever on the iPad. On foundPeer, applies all config from discoveryInfo
/// to AppState — this is the single source of truth for server URL and repo config.
/// Pairing (MCSession) only exchanges the auth token.
@MainActor
final class PairingBrowser: NSObject, ObservableObject {

    @Published var discoveredMacs: [MCPeerID] = []
    @Published var pairingStatus: String = ""
    @Published var isPaired: Bool = false

    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

    func start() {
        guard browser == nil else { return }
        let b = MCNearbyServiceBrowser(peer: myPeerID, serviceType: pairingServiceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
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
        // All connection info comes from discoveryInfo — this is the mDNS record.
        let port      = info?["port"]     ?? "8080"
        let owner     = info?["owner"]    ?? ""
        let repo      = info?["repo"]     ?? ""
        let docsPath  = info?["docsPath"] ?? "docs-cms/rfcs"
        let rfcLabel  = info?["rfcLabel"] ?? "hermit:rfc-ready"
        // peerID.displayName is the Mac's LocalHostName (e.g. Stevens-MacBook-Pro)
        let serverURL = "http://\(peerID.displayName).local:\(port)"

        Task { @MainActor in
            if !self.discoveredMacs.contains(peerID) {
                self.discoveredMacs.append(peerID)
            }
            // Update AppState from mDNS — this is always the source of truth.
            // serverBaseURL is intentionally NOT persisted to Keychain; it must
            // always come from live mDNS discovery so stale URLs never survive
            // across installs or network changes.
            AppState.shared.serverBaseURL = serverURL
            AppState.shared.serverMode    = .localNetwork
            AppState.shared.repoOwner     = owner
            AppState.shared.repoName      = repo
            AppState.shared.docsPath      = docsPath
            AppState.shared.rfcLabel      = rfcLabel
            KeychainHelper.shared.serverMode    = .localNetwork
            KeychainHelper.shared.repoOwner     = owner
            KeychainHelper.shared.repoName      = repo
            KeychainHelper.shared.docsPath      = docsPath
            KeychainHelper.shared.rfcLabel      = rfcLabel
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredMacs.removeAll { $0 == peerID }
            // Clear server URL so the UI stops trying to connect.
            if AppState.shared.serverMode == .localNetwork {
                AppState.shared.serverBaseURL = ""
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                  didNotStartBrowsingForPeers error: Error) {
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
            AppState.shared.localNetworkToken = token
            self.isPaired = true
            self.pairingStatus = "Paired with \(peerID.displayName)"
            session.disconnect()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif
