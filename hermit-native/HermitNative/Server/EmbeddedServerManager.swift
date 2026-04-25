import Foundation
import Network
import AppKit
#if HERMIT_EMBEDDED_SERVER
import HermitServer
#endif

// MARK: - hermit-y9x: Launch embedded Go server at app startup
// MARK: - hermit-6et: Register Bonjour _hermit._tcp service after server starts

/// Manages the lifecycle of the embedded Hermit Go server on macOS.
///
/// Production: Go server compiled into HermitServer.xcframework via `make gomobile-build`,
/// started in-process via MobileStart(). Enable with -DHERMIT_EMBEDDED_SERVER.
///
/// Debug fallback: when xcframework is not available, spawns the Go server as a
/// subprocess via `make run` from the repo root, then polls until it responds.
/// The subprocess is terminated when the app quits.
#if os(macOS)
@MainActor
final class EmbeddedServerManager: ObservableObject {

    static let shared = EmbeddedServerManager()

    @Published private(set) var port: Int? = nil
    @Published private(set) var errorMessage: String? = nil

    private var bonjourListener: NWListener? = nil
    private var serverProcess: Process? = nil   // debug subprocess only

    private init() {
        // Stop subprocess when app terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: - Start

    func start(appState: AppState) {
        guard port == nil else { return }

#if HERMIT_EMBEDDED_SERVER
        let config = buildConfigJSON(appState: appState)
        let result = MobileStart(config)

        if result.hasPrefix("error:") {
            errorMessage = result
            return
        }
        guard let p = Int(result) else {
            errorMessage = "embedded server returned unexpected port: \(result)"
            return
        }

        port = p
        errorMessage = nil
        appState.serverBaseURL = "http://127.0.0.1:\(p)"
        registerBonjour(port: p)
#else
        // Dev fallback: spawn Go server as a subprocess.
        startSubprocess(appState: appState)
#endif
    }

    // MARK: - Stop

    func stop() {
        bonjourListener?.cancel()
        bonjourListener = nil
#if HERMIT_EMBEDDED_SERVER
        MobileStop()
#else
        serverProcess?.terminate()
        serverProcess = nil
#endif
        port = nil
    }

    // MARK: - Dev subprocess fallback
    // Used when HERMIT_EMBEDDED_SERVER is not set (xcframework not yet built).
    // Runs the pre-built bin/hermit binary as a child process and polls until ready.

    private func startSubprocess(appState: AppState) {
        guard let repoRoot = findRepoRoot() else {
            errorMessage = "Could not locate Hermit repo root to start server."
            return
        }

        let binaryURL = repoRoot.appendingPathComponent("bin/hermit")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            errorMessage = "Server binary not found at \(binaryURL.path). Run make build first."
            return
        }

        let process = Process()
        process.executableURL = binaryURL
        process.currentDirectoryURL = repoRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GITEA_TOKEN": appState.pat,
        ]) { _, new in new }

        // Redirect stdout/stderr to a log file
        let logPath = "/tmp/hermit-server-subprocess.log"
        _ = FileManager.default.createFile(atPath: logPath, contents: Data())
        if let logFH = FileHandle(forWritingAtPath: logPath) {
            process.standardOutput = logFH
            process.standardError  = logFH
        }

        do {
            try process.run()
        } catch {
            self.errorMessage = "Failed to start server subprocess: \(error)"
            return
        }

        serverProcess = process

        // Poll until the server responds then update AppState
        let listenPort = 8080
        Task {
            await pollUntilReady(port: listenPort, timeout: 15)
            await MainActor.run {
                self.port = listenPort
                self.errorMessage = nil
                appState.serverBaseURL = "http://127.0.0.1:\(listenPort)"
                self.registerBonjour(port: listenPort)
            }
        }
    }

    private func pollUntilReady(port: Int, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://127.0.0.1:\(port)/api/v1/health")!
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await MainActor.run {
            self.errorMessage = "Server did not respond within \(Int(timeout))s."
        }
    }

    private func findRepoRoot() -> URL? {
        var candidate = Bundle.main.bundleURL
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("config/hermit.yaml").path) {
                return candidate
            }
        }
        let known = ["~/Development/github/hashicorp/hermit", "~/code/hashicorp/hermit"]
        for raw in known {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("config/hermit.yaml").path) {
                return url
            }
        }
        return nil
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
                    print("[EmbeddedServerManager] Bonjour listener failed: \(error)")
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
            print("[EmbeddedServerManager] Failed to create Bonjour listener: \(error)")
        }
    }

    // MARK: - Config JSON

    private func buildConfigJSON(appState: AppState) -> String {
        let dataDir = Self.appSupportDirectory()
        let payload: [String: String] = [
            "baseURL":  appState.baseURL,
            "pat":      appState.pat,
            "owner":    appState.repoOwner,
            "repo":     appState.repoName,
            "docsPath": appState.docsPath,
            "rfcLabel": appState.rfcLabel,
            "dataDir":  dataDir,
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
}
#endif
