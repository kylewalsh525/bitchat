import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WalletView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var balances: [String: [String: UInt64]] = [:]
    @State private var reserved: [(paymentID: String, mintURL: String, unit: String, amount: UInt64)] = []

    @State private var importTokenText: String = ""
    @State private var importStatus: String? = nil
    @State private var pendingMintApprovals: [String] = []
    @State private var showMintApprovalSheet = false

    @State private var exportMintURL: String = ""
    @State private var exportUnit: String = "sat"
    @State private var exportAmountText: String = ""
    @State private var exportTokenResult: String = ""
    @State private var exportStatus: String? = nil
    @State private var thirdwebClientID: String = ""
    @State private var thirdwebStatus: String? = nil

    private var accent: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var availableMintURLs: [String] {
        Array(balances.keys).sorted()
    }

    private var availableUnitsForSelectedMint: [String] {
        let mint = exportMintURL
        return balances[mint]?.keys.sorted() ?? []
    }

    var body: some View {
        Form {
            Section {
                Text("Cashu ecash is stored locally on this device. Bearer proofs and tokens are never broadcast in rooms.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Balances") {
                if balances.isEmpty {
                    Text("No wallet balance yet. Import a token to get started.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableMintURLs, id: \.self) { mintURL in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mintURL)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            let byUnit = balances[mintURL] ?? [:]
                            ForEach(byUnit.keys.sorted(), id: \.self) { unit in
                                let amount = byUnit[unit] ?? 0
                                Text("\(amount) \(unit)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Reserved (in-flight)") {
                if reserved.isEmpty {
                    Text("No in-flight payments.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reserved, id: \.paymentID) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("payment \(item.paymentID.prefix(8))…")
                                .font(.system(.footnote, design: .monospaced))
                            Text("\(item.amount) \(item.unit) • \(URL(string: item.mintURL)?.host ?? item.mintURL)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Import") {
                TextEditor(text: $importTokenText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
                    )
                    .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("Paste Cashu token")

                HStack(spacing: 12) {
                    Button("Paste") {
                        importTokenText = readPasteboardString() ?? importTokenText
                    }
                    .buttonStyle(.bordered)

                    Button("Import token") {
                        beginImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importTokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let importStatus {
                    Text(importStatus)
                        .font(.footnote)
                        .foregroundStyle(importStatus.lowercased().contains("imported") ? .green : .secondary)
                }
            }

            Section("Export") {
                if availableMintURLs.isEmpty {
                    Text("Export is available after you import a token.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Mint", selection: $exportMintURL) {
                        ForEach(availableMintURLs, id: \.self) { mint in
                            Text(URL(string: mint)?.host ?? mint).tag(mint)
                        }
                    }

                    if !availableUnitsForSelectedMint.isEmpty {
                        Picker("Unit", selection: $exportUnit) {
                            ForEach(availableUnitsForSelectedMint, id: \.self) { unit in
                                Text(unit).tag(unit)
                            }
                        }
                    }

                    TextField("Amount", text: $exportAmountText)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif

                    HStack(spacing: 12) {
                        Button("Export token") {
                            exportToken()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Copy") {
                            writePasteboardString(exportTokenResult)
                        }
                        .buttonStyle(.bordered)
                        .disabled(exportTokenResult.isEmpty)

                        if !exportTokenResult.isEmpty {
                            ShareLink(item: exportTokenResult) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let exportStatus {
                        Text(exportStatus)
                            .font(.footnote)
                            .foregroundStyle(exportStatus.lowercased().contains("exported") ? .green : .secondary)
                    }

                    if !exportTokenResult.isEmpty {
                        TextEditor(text: $exportTokenResult)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
                            )
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Mint allowlist") {
                NavigationLink("Manage approved mints") {
                    MintAllowlistView()
                }
                Text("Unknown mints require explicit approval before import or payment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("x402 Guest Wallet (thirdweb)") {
                Text("x402 is online-only and less private than Cashu. Set a thirdweb client ID to enable guest wallet provisioning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("thirdweb client id", text: $thirdwebClientID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                HStack(spacing: 12) {
                    Button("Save") {
                        viewModel.thirdwebGuestWalletBridge.setConfiguredClientID(thirdwebClientID)
                        thirdwebStatus = "Saved client id."
                    }
                    .buttonStyle(.bordered)

                    Button("Connect guest") {
                        Task { @MainActor in
                            do {
                                let address = try await viewModel.thirdwebGuestWalletBridge.ensureGuestWallet()
                                thirdwebStatus = "Connected: \(address)"
                            } catch {
                                thirdwebStatus = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    Button("Link wallet") {
                        Task { @MainActor in
                            do {
                                try await viewModel.thirdwebGuestWalletBridge.linkWallet()
                                thirdwebStatus = "Wallet linked."
                            } catch {
                                thirdwebStatus = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Export private key") {
                        Task { @MainActor in
                            do {
                                let key = try await viewModel.thirdwebGuestWalletBridge.exportPrivateKey()
                                writePasteboardString(key)
                                thirdwebStatus = "Private key copied to clipboard."
                            } catch {
                                thirdwebStatus = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Reset") {
                        Task { @MainActor in
                            await viewModel.thirdwebGuestWalletBridge.resetWallet()
                            thirdwebStatus = "Wallet reset."
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let address = viewModel.thirdwebGuestWalletBridge.walletAddress, !address.isEmpty {
                    Text(address)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let thirdwebStatus, !thirdwebStatus.isEmpty {
                    Text(thirdwebStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Wallet")
        .tint(accent)
        .onAppear {
            reload()
            thirdwebClientID = viewModel.thirdwebGuestWalletBridge.configuredClientID() ?? ""
        }
        .onChange(of: viewModel.cashuMintAllowlistStore.allowedMintURLs) { _ in
            // Keep UI coherent after approvals.
            reload()
        }
        .sheet(isPresented: $showMintApprovalSheet) {
            MintApprovalSheet(
                mints: pendingMintApprovals,
                onCancel: {
                    pendingMintApprovals = []
                    showMintApprovalSheet = false
                },
                onApprove: {
                    for mint in pendingMintApprovals {
                        viewModel.cashuMintAllowlistStore.allow(mintURL: mint)
                    }
                    showMintApprovalSheet = false
                    pendingMintApprovals = []
                    importNow()
                }
            )
        }
    }

    private func reload() {
        balances = viewModel.cashuWalletService.balancesByMintAndUnit()
        reserved = viewModel.cashuWalletService.reservedSummary()

        if exportMintURL.isEmpty, let first = availableMintURLs.first {
            exportMintURL = first
        }
        if !availableUnitsForSelectedMint.contains(exportUnit), let firstUnit = availableUnitsForSelectedMint.first {
            exportUnit = firstUnit
        }
    }

    private func beginImport() {
        importStatus = nil
        exportStatus = nil

        let token = importTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundles = CashuTokenParser.parseTokenString(token) else {
            importStatus = "Invalid token."
            return
        }

        let mints = Array(Set(bundles.map { CashuMintAllowlistStore.normalizeMintURL($0.mintURL) }))
            .filter { !$0.isEmpty }
            .sorted()
        let unapproved = mints.filter { !viewModel.cashuMintAllowlistStore.isAllowed(mintURL: $0) }
        if !unapproved.isEmpty {
            pendingMintApprovals = unapproved
            showMintApprovalSheet = true
            return
        }

        importNow()
    }

    private func importNow() {
        let token = importTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            let imported = try viewModel.cashuWalletService.importToken(token)
            importStatus = "Imported \(imported)."
            importTokenText = ""
            reload()
        } catch {
            importStatus = error.localizedDescription
        }
    }

    private func exportToken() {
        exportStatus = nil
        let amountText = exportAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = UInt64(amountText), amount > 0 else {
            exportStatus = "Enter a valid amount."
            return
        }
        do {
            let token = try viewModel.cashuWalletService.exportToken(mintURL: exportMintURL, unit: exportUnit, amount: amount)
            exportTokenResult = token
            exportStatus = "Exported \(amount) \(exportUnit)."
            reload()
        } catch {
            exportStatus = error.localizedDescription
        }
    }

    private func readPasteboardString() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    private func writePasteboardString(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = trimmed
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        #endif
    }
}
