import Foundation
import Network
import os.log
import CommonCrypto
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
        // Ensure a TLS cert+key pair exists before building the config JSON.
        // The cert lives on disk; the private key lives exclusively in Keychain.
        Self.ensureTLSCert()

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
        // Use https:// when TLS is configured (cert+key both present).
        let scheme = (Self.currentTLSCertFile != nil) ? "https" : "http"
        appState.serverBaseURL = "\(scheme)://127.0.0.1:\(p)"
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

        var payload: [String: Any] = [
            "repos":         repos,
            "dataDir":       dataDir,
            "pairedTokens":  pairedTokens,
            "cache": [
                "repositoryRFCListReadTTLSeconds": ConfigStore.shared.cacheReadTTLSeconds,
                "repositoryRFCListJitterSeconds": ConfigStore.shared.cacheJitterSeconds,
            ],
        ]
        // Include TLS cert path + key PEM so the Go server starts in HTTPS mode.
        if let certFile = Self.currentTLSCertFile,
           let keyPEM   = KeychainHelper.shared.tlsPrivateKey, !keyPEM.isEmpty {
            payload["tlsCertFile"] = certFile
            payload["tlsKeyPEM"]   = keyPEM
        }
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

    /// Returns the localhost URL for the embedded server using the correct scheme.
    static func localServerURL(port: Int) -> String {
        let scheme = (currentTLSCertFile != nil) ? "https" : "http"
        return "\(scheme)://127.0.0.1:\(port)"
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

    // MARK: - TLS certificate management

    /// Path to the on-disk TLS certificate; nil if not yet generated.
    private(set) static var currentTLSCertFile: String? = nil
    /// SHA-256 hex fingerprint of the current TLS certificate.
    private(set) static var tlsFingerprint: String = ""

    /// Ensures a TLS cert+key pair exists. Generates if either is missing.
    static func ensureTLSCert() {
        let dataDir  = appSupportDirectory()
        let certFile = "\(dataDir)/hermit/tls.crt"
        let certExists = FileManager.default.fileExists(atPath: certFile)
        let keyExists  = !(KeychainHelper.shared.tlsPrivateKey ?? "").isEmpty

        if certExists && keyExists {
            if let pem = try? String(contentsOfFile: certFile, encoding: .utf8),
               let fp  = tlsFingerprintFromPEM(pem) {
                // Reject certs that have no IP SANs — Apple's TLS stack rejects
                // them at the handshake level before our delegate is called.
                if certHasIPSANs(pem) {
                    currentTLSCertFile = certFile
                    tlsFingerprint = fp
                    return
                }
                NSLog("[EmbeddedServerManager] TLS cert missing SANs — regenerating")
            }
        }
        // Regenerate — cert missing, key missing, cert unreadable, or cert lacks SANs.
        generateTLSCert(dataDir: dataDir)
    }

    /// Returns true when the PEM cert contains IP SANs AND a .local DNS SAN
    /// (both required for Mac→Mac loopback and iPad→Mac mDNS connections).
    private static func certHasIPSANs(_ pem: String) -> Bool {
        let lines = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let der = Data(base64Encoded: lines.joined()),
              let cert = SecCertificateCreateWithData(nil, der as CFData)
        else { return false }
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(cert, [kSecOIDSubjectAltName] as CFArray, &error) as? [String: Any],
              let sanEntry = values[kSecOIDSubjectAltName as String] as? [String: Any],
              let sanValues = sanEntry["value"] as? [[String: Any]]
        else { return false }
        let hasIP  = sanValues.contains { ($0["label"] as? String) == "IP Address" }
        let hasDotLocal = sanValues.contains {
            ($0["label"] as? String) == "DNS Name" &&
            ($0["value"] as? String)?.hasSuffix(".local") == true
        }
        return hasIP && hasDotLocal
    }

    private static func generateTLSCert(dataDir: String) {
        let result = MobileGenerateTLSCert(dataDir)
        guard !result.hasPrefix("error:"),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let certFile = json["certFile"],
              let keyPEM   = json["keyPEM"],
              let fp       = json["fingerprint"]
        else {
            NSLog("[EmbeddedServerManager] MobileGenerateTLSCert failed: %@", result)
            return
        }
        KeychainHelper.shared.tlsPrivateKey = keyPEM
        currentTLSCertFile = certFile
        tlsFingerprint = fp
    }

    /// SHA-256 fingerprint of the first DER cert in a PEM block using CommonCrypto.
    private static func tlsFingerprintFromPEM(_ pem: String) -> String? {
        let lines = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let der = Data(base64Encoded: lines.joined()) else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        der.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(der.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
