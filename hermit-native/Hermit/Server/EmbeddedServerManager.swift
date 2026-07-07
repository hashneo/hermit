import Foundation
import Network
import os.log
#if os(macOS)
import AppKit
#endif
#if HERMIT_EMBEDDED_SERVER
import HermitServer
#endif

// MARK: - hermit-nnn: Debug logging helpers

private let hermitLog = OSLog(subsystem: "me.steven.hermit", category: "EmbeddedServer")

/// Resolve a writable log path that works under both sandboxed and non-sandboxed builds.
private let hermitLogPath: String = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-native-debug.log")
    return url.path
}()

/// Append a timestamped line to the debug log file and emit an os_log message.
private func esLog(_ message: String) {
    os_log("%{public}@", log: hermitLog, type: .debug, message)
    let line = "[\(Date())] [EmbeddedServerManager] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: hermitLogPath),
       let fh = FileHandle(forWritingAtPath: hermitLogPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: hermitLogPath), options: .atomic)
    }
}

/// Replace every "pat":"<value>" in a JSON string with "pat":"[REDACTED]".
private func redactPATs(in json: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #""pat"\s*:\s*"[^"]*""#) else { return json }
    let range = NSRange(json.startIndex..., in: json)
    return regex.stringByReplacingMatches(in: json, range: range, withTemplate: #""pat":"[REDACTED]""#)
}

// MARK: - hermit-y9x: Launch embedded Go server at app startup
// MARK: - hermit-6et: Register Bonjour _hermit._tcp service after server starts

/// Manages the lifecycle of the embedded Hermit Go server on macOS.
///
/// The Go server is compiled into HermitServer.xcframework via `make gomobile-build`
/// and started in-process via MobileStart(). Enable with -DHERMIT_EMBEDDED_SERVER.
///
/// There is no subprocess fallback. If MobileStart is unavailable the build
/// simply fails to compile, making the architecture explicit and non-negotiable.
#if os(macOS)
@MainActor
final class EmbeddedServerManager: ObservableObject {

    static let shared = EmbeddedServerManager()

    @Published private(set) var port: Int? = nil
    @Published private(set) var errorMessage: String? = nil

    private var bonjourListener: NWListener? = nil

    private init() {}

    // MARK: - Start

    func start(appState: AppState) {
        guard port == nil else { return }

#if HERMIT_EMBEDDED_SERVER
        let config = buildConfigJSON(appState: appState)

        // hermit-nnn: log config JSON with PATs redacted, then log the raw result
        esLog("MobileStart config: \(redactPATs(in: config))")

        // Redirect Go slog to the same debug log file before starting the server
        // so that all server-side structured logs land alongside Swift esLog output.
        let logResult = MobileSetLogFile(hermitLogPath)
        esLog("MobileSetLogFile result: \(logResult)")

        esLog("Calling MobileStart…")

        let result = MobileStart(config)

        esLog("MobileStart result: \(result)")

        if result.hasPrefix("error:") {
            errorMessage = result
            esLog("MobileStart error — errorMessage set: \(result)")
            return
        }
        guard let p = Int(result) else {
            let msg = "embedded server returned unexpected port: \(result)"
            errorMessage = msg
            esLog("MobileStart unexpected result — errorMessage set: \(msg)")
            return
        }

        esLog("MobileStart succeeded — port=\(p)")
        port = p
        errorMessage = nil
        appState.serverBaseURL = "http://127.0.0.1:\(p)"
        registerBonjour(port: p)
        PairingAdvertiser.shared.restart()
#else
        // hermit-abh: subprocess fallback intentionally removed.
        // MobileStart (HermitServer.xcframework) is the only supported start path.
        // Build with -DHERMIT_EMBEDDED_SERVER to enable the server.
        esLog("HERMIT_EMBEDDED_SERVER not set — server will not start in this build.")
        errorMessage = "Server not available: build with HERMIT_EMBEDDED_SERVER."
#endif
    }

    // MARK: - Restart

    /// Stop the running server and start it again with fresh config from appState.
    /// Safe to call at any time; no-ops if the server was not running.
    func restart(appState: AppState) {
        esLog("restart requested")
        stop()
        start(appState: appState)
    }

    // MARK: - Stop

    func stop() {
        bonjourListener?.cancel()
        bonjourListener = nil
#if HERMIT_EMBEDDED_SERVER
        MobileStop()
#endif
        port = nil
    }

    // MARK: - Bonjour advertising

    private func registerBonjour(port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(
                name: "Hermit",
                type: "_hermit._tcp",
                txtRecord: NWTXTRecord(["version": "1"])
            )
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    esLog("Bonjour listener failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                // Only need the advertisement; reject connections on this listener
                // (real API traffic goes to the Go server's port).
                connection.cancel()
            }
            listener.start(queue: .main)
            bonjourListener = listener
        } catch {
            esLog("Failed to create Bonjour listener: \(error)")
        }
    }

    // MARK: - Config JSON

    private func buildConfigJSON(appState: AppState) -> String {
        let dataDir = Self.appSupportDirectory()
        let accountStore = AccountStore.shared
        let repoStore    = RepositoryStore.shared

        // Build one RepoConfig entry per repository, resolving its account's PAT.
        // All repos are sent — the Go server registers them all simultaneously.
        var repos: [[String: String]] = []
        for repo in repoStore.repositories {
            guard let account = accountStore.connections.first(where: { $0.id == repo.accountID }),
                  let pat = accountStore.token(for: account), !pat.isEmpty else { continue }
            repos.append([
                "baseURL":  Self.resolvedAPIBase(for: account.endpoint),
                "pat":      pat,
                "owner":    repo.owner,
                "repo":     repo.name,
                "docsPath": repo.docsPath,
            ])
        }

        // Legacy fallback for first-launch migration before any stores are populated.
        if repos.isEmpty && !appState.pat.isEmpty && !appState.repoOwner.isEmpty {
            repos.append([
                "baseURL":  Self.resolvedAPIBase(for: appState.giteaBaseURL.isEmpty ? appState.baseURL : appState.giteaBaseURL),
                "pat":      appState.pat,
                "owner":    appState.repoOwner,
                "repo":     appState.repoName,
                "docsPath": appState.docsPath,
            ])
        }

        // Paired token values (not peer names) — the Go server validates these.
        let pairedTokens = Array(PairedTokenStore.shared.pairedDevices.values)

        let payload: [String: Any] = [
            "repos":         repos,
            "dataDir":       dataDir,
            "pairedTokens":  pairedTokens,
            "cache": [
                "repositoryRFCListReadTTLSeconds": ConfigStore.shared.cacheReadTTLSeconds,
                "repositoryRFCListJitterSeconds": ConfigStore.shared.cacheJitterSeconds,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str  = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func appSupportDirectory() -> String {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls.first?.appendingPathComponent("Hermit").path ?? NSHomeDirectory()
    }

    /// Returns the correct API base URL for a registry endpoint.
    ///
    /// The Go server's github_client constructs paths as `{baseURL}/repos/…`
    /// which is the GitHub REST API layout. GitHub Enterprise exposes that at
    /// `/api/v3`, while Gitea exposes the same layout under `/api/v1`.
    static func resolvedAPIBase(for rawEndpoint: String) -> String {
        let trimmed = rawEndpoint.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let host = URL(string: trimmed)?.host else { return trimmed }
        if host == "github.com" || host == "api.github.com" { return trimmed }
        if trimmed.hasSuffix("/api/v3") { return trimmed }
        if trimmed.hasSuffix("/api/v1") { return trimmed }
        return trimmed + "/api/v1"
    }

    /// Registers a paired device token with the running Go server.
    /// Called immediately after a successful MCSession pairing handshake.
    static func registerPairedToken(_ token: String) {
        let result = MobileRegisterPairedToken(token)
        if result != "ok" {
            NSLog("[EmbeddedServerManager] registerPairedToken: %@", result)
        }
    }

    /// Revokes a paired device token from the running Go server.
    /// The iPad receives 401 on its next request and returns to the pairing screen.
    static func revokePairedToken(_ token: String) {
        let result = MobileRevokePairedToken(token)
        if result != "ok" {
            NSLog("[EmbeddedServerManager] revokePairedToken: %@", result)
        }
    }
}
#endif
