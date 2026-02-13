import SwiftUI

struct SupportExportView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var exporter = SupportBundleExporter()
    @State private var isExporting = false
    @State private var exportedURL: URL? = nil
    @State private var statusText: String? = nil

    var body: some View {
        Form {
            Section {
                Text("Export a redacted debug bundle for beta support.")
                    .foregroundStyle(.secondary)
                Text("No Cashu tokens, proofs, or private keys are included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Text("App version + platform")
                Text("Feature flags (agent runtime/payments/locking)")
                Text("Agent config (redacted)")
                Text("Wallet summary (balances + reserved)")
                Text("Payment store summary (counts + statuses)")
                Text("Recent agent/payment events (redacted)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Support")
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

