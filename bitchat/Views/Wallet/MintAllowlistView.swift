import SwiftUI

struct MintAllowlistView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var newMintURL: String = ""

    var body: some View {
        Form {
            Section {
                Text("Only approved mints can be used for imports and payments. This reduces accidental payments to unknown or malicious mints.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Approved mints") {
                if viewModel.cashuMintAllowlistStore.allowedMintURLs.isEmpty {
                    Text("No approved mints yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.cashuMintAllowlistStore.allowedMintURLs, id: \.self) { mint in
                        Text(mint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .onDelete(perform: deleteMints)
                }
            }

            Section("Add mint") {
                TextField("https://mint.example.com", text: $newMintURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

                Button("Approve mint") {
                    let normalized = CashuMintAllowlistStore.normalizeMintURL(newMintURL)
                    viewModel.cashuMintAllowlistStore.allow(mintURL: normalized)
                    newMintURL = ""
                }
                .disabled(CashuMintAllowlistStore.normalizeMintURL(newMintURL).isEmpty)
            }
        }
        .navigationTitle("Mint Allowlist")
    }

    private func deleteMints(at offsets: IndexSet) {
        let mints = viewModel.cashuMintAllowlistStore.allowedMintURLs
        for idx in offsets {
            guard idx >= 0 && idx < mints.count else { continue }
            viewModel.cashuMintAllowlistStore.revoke(mintURL: mints[idx])
        }
    }
}

