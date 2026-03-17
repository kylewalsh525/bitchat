import SwiftUI

struct SupportExportView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var exporter = SupportBundleExporter()
    @State private var isExporting = false
    @State private var exportedURL: URL? = nil
    @State private var statusText: String? = nil

    private var surfaceBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(.windowBackgroundColor)
        #endif
    }

    var body: some View {
        Form {
            Section {
                SettingsIconRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Export a redacted debug bundle for beta support.",
                    subtitle: "No Cashu tokens, proofs, or private keys are included."
                )
            }

            Section {
                Button {
                    export()
                } label: {
                    if isExporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Generating…")
                        }
                    } else {
                        Text("Generate bundle")
                    }
                }
                .disabled(isExporting)

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label("Share bundle", systemImage: "square.and.arrow.up")
                    }
                }

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Includes") {
                SettingsIconRow(icon: "iphone", title: "App version + platform")
                SettingsIconRow(icon: "switch.2", title: "Feature flags (agent runtime/payments/locking)")
                SettingsIconRow(icon: "person.crop.rectangle", title: "Agent config (redacted)")
                SettingsIconRow(icon: "wallet.pass", title: "Wallet summary (balances + reserved)")
                SettingsIconRow(icon: "tray.2", title: "Payment store summary (counts + statuses)")
                SettingsIconRow(icon: "clock.arrow.circlepath", title: "Recent agent/payment events (redacted)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Support")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .scrollContentBackground(.hidden)
        .background(surfaceBackground)
    }

    private func export() {
        isExporting = true
        exportedURL = nil
        statusText = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let url = try await exporter.exportBundle(viewModel: viewModel)
                exportedURL = url
                statusText = "Bundle generated."
            } catch {
                statusText = error.localizedDescription
            }
        }
    }
}
