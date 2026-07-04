import Foundation
import Network
import Combine

// MARK: - hermit-m6z: ServerDiscoveryService — NWBrowser Bonjour discovery (iPad)

/// Represents a Hermit server discovered on the local network via Bonjour.
struct DiscoveredServer: Identifiable, Equatable {
    let id: String          // unique key: "host:port"
    let displayName: String // Bonjour service name, e.g. "Hermit" or "Steven's Mac"
    let host: String
    let port: Int

    var baseURL: String { "http://\(host):\(port)" }
}

/// Scans the local network for `_hermit._tcp` Bonjour services and publishes
/// results into AppState.discoveredServers.
///
/// Lifecycle: call `start()` when the Settings Server tab appears,
/// `stop()` when it disappears.
///
/// Requires:
///   com.apple.developer.networking.multicast   (iOS entitlement)
///   NSLocalNetworkUsageDescription             (Info.plist)
@MainActor
final class ServerDiscoveryService: ObservableObject {

    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var isScanning = false

    private var browser: NWBrowser?
    private var resolving: [NWBrowser.Result: NWConnection] = [:]

    // MARK: - Start / Stop

    func start() {
        guard browser == nil else { return }
        isScanning = true
        servers = []

        let params = NWParameters.tcp
        let b = NWBrowser(for: .bonjour(type: "_hermit._tcp", domain: nil), using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .cancelled, .failed:
                    self?.isScanning = false
                    self?.browser = nil
                default:
                    break
                }
            }
        }

        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        isScanning = false
    }

    // MARK: - Result handling

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // Remove servers no longer present
        let current = servers.filter { s in
            results.contains { matchesServer(s, result: $0) }
        }

        // Start with servers still visible; new ones appended during resolution
        servers = current

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // Resolve hostname + port via a short-lived NWConnection
            let conn = NWConnection(to: result.endpoint, using: .tcp)
            resolving[result] = conn

            conn.stateUpdateHandler = { [weak self, weak conn] state in
                Task { @MainActor [weak self] in
                    guard let self, let conn else { return }
                    if case .preparing = state,
                       case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr): hostStr = "\(addr)"
                        case .ipv6(let addr): hostStr = "[\(addr)]"
                        case .name(let n, _): hostStr = n
                        @unknown default:     hostStr = "\(host)"
                        }
                        let portInt = Int(port.rawValue)
                        let server = DiscoveredServer(
                            id: "\(hostStr):\(portInt)",
                            displayName: name,
                            host: hostStr,
                            port: portInt
                        )
                        if !self.servers.contains(server) {
                            self.servers.append(server)
                        }
                        conn.cancel()
                        self.resolving.removeValue(forKey: result)
                    }
                }
            }
            conn.start(queue: .main)
        }

        // (new servers are appended during the resolution loop above)
    }

    private func matchesServer(_ server: DiscoveredServer, result: NWBrowser.Result) -> Bool {
        guard case .service(let name, _, _, _) = result.endpoint else { return false }
        return server.displayName == name
    }
}
