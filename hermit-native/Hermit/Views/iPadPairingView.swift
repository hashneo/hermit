import SwiftUI
#if os(iOS)
import MultipeerConnectivity

/// Shown on iPad when not yet connected to a Mac.
/// Scans for nearby Macs via Bonjour and lets the user initiate pairing.
/// Replaces SetupView for the local-network mode — no server URL or PAT entry needed.
struct iPadPairingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pairingBrowser: PairingBrowser
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // ── Header ─────────────────────────────────────────────
                VStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.ipad")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Connect to Hermit")
                        .font(.title2).bold()
                    Text("Make sure Hermit is running on your Mac and both devices are on the same network.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }

                // ── Mac discovery list ─────────────────────────────────
                VStack(spacing: 0) {
                    if pairingBrowser.discoveredMacs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Searching for Macs…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(pairingBrowser.discoveredMacs, id: \.displayName) { peer in
                                Button {
                                    pairingBrowser.invite(peer: peer)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "laptopcomputer")
                                            .font(.title3)
                                            .foregroundStyle(.tint)
                                            .frame(width: 32)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(peer.displayName)
                                                .font(.body).fontWeight(.medium)
                                            Text("Tap to pair")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                            .imageScale(.small)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)
                                if peer != pairingBrowser.discoveredMacs.last {
                                    Divider().padding(.leading, 62)
                                }
                            }
                        }
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 32)

                // ── Pairing status ─────────────────────────────────────
                if !pairingBrowser.pairingStatus.isEmpty {
                    Text(pairingBrowser.pairingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .navigationTitle("Hermit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                        .environmentObject(appState)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
    }
}
#endif
