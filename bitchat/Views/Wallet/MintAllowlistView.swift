import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct MintAllowlistView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var newMintURL: String = ""
    @State private var statusText: String? = nil
    @State private var statusTone: MintStatusTone = .neutral

    private var surfaceBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(.windowBackgroundColor)
        #endif
    }

    var body: some View {
        List {
            Section {
                SettingsIconRow(
                    icon: "checkmark.shield",
                    title: "Mint allowlist protects payments",
                    subtitle: "BitChat only imports and pays with mints you approve."
                )
                SettingsIconRow(
                    icon: "hand.raised",
                    title: "New mint? You decide",
                    subtitle: "Unknown mints are blocked until you approve them."
                )
                SettingsIconRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Changes apply right away",
                    subtitle: "Removing a mint blocks new imports/payments from that mint."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Approved Mints") {
                if viewModel.cashuMintAllowlistStore.allowedMintURLs.isEmpty {
                    SettingsIconRow(
                        icon: "tray",
                        title: "No approved mints yet",
                        subtitle: "Import a token, then approve its mint."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.cashuMintAllowlistStore.allowedMintURLs, id: \.self) { mint in
                        let host = URL(string: mint)?.host ?? mint
                        HStack(alignment: .center, spacing: 12) {
                            SettingsIconRow(icon: "link", title: host, subtitle: mint)
                                .textSelection(.enabled)
                            Button("Remove", role: .destructive) {
                                viewModel.cashuMintAllowlistStore.revoke(mintURL: mint)
                                statusText = "Removed \(host)."
                                statusTone = .neutral
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .onDelete(perform: deleteMints)
                }
            }

            Section("Approve New Mint") {
                TextField("https://mint.example.com", text: $newMintURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                HStack(spacing: 10) {
                    Button("Paste") {
                        if let pasted = readPasteboardString() {
                            newMintURL = pasted
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Approve mint") {
                        approveMint()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(CashuMintAllowlistStore.normalizeMintURL(newMintURL).isEmpty)

                    Spacer(minLength: 0)
                }

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(statusTone.color)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Approved Mints")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(surfaceBackground)
    }

    private func deleteMints(at offsets: IndexSet) {
        let mints = viewModel.cashuMintAllowlistStore.allowedMintURLs
        for idx in offsets {
            guard idx >= 0 && idx < mints.count else { continue }
            viewModel.cashuMintAllowlistStore.revoke(mintURL: mints[idx])
        }
    }

    private func approveMint() {
        let normalized = CashuMintAllowlistStore.normalizeMintURL(newMintURL)
        guard !normalized.isEmpty else {
            statusText = "Enter a valid mint URL."
            statusTone = .failure
            return
        }
        viewModel.cashuMintAllowlistStore.allow(mintURL: normalized)
        statusText = "Approved \(URL(string: normalized)?.host ?? normalized)."
        statusTone = .success
        newMintURL = ""
    }

    private func readPasteboardString() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }
}

private enum MintStatusTone {
    case neutral
    case success
    case failure

    var color: Color {
        switch self {
        case .neutral:
            return .secondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}
