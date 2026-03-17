import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum WalletSetupTab: String, CaseIterable, Identifiable {
    case cashu = "Cashu"
    case x402 = "x402"

    var id: String { rawValue }
}

struct WalletView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var tab: WalletSetupTab = .cashu

    @State private var balances: [String: [String: UInt64]] = [:]
    @State private var reserved: [ReservedPaymentSummary] = []

    @State private var importTokenText: String = ""
    @State private var importStatus: String? = nil
    @State private var importStatusTone: InlineStatusTone = .neutral
    @State private var pendingMintApprovals: [String] = []
    @State private var pendingNormalizedImportToken: String? = nil
    @State private var pendingImportBundles: [CashuMintProofBundle] = []

    @State private var exportMintURL: String = ""
    @State private var exportUnit: String = "sat"
    @State private var exportAmountText: String = ""
    @State private var exportTokenResult: String = ""
    @State private var exportStatus: String? = nil
    @State private var exportStatusTone: InlineStatusTone = .neutral

    @State private var thirdwebActionState: ThirdwebActionState = .idle
    @State private var showAdvancedCashu = false
    @State private var showAdvancedX402 = false
    @State private var reloadScheduler = WalletReloadScheduler()

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

    private var hasCashuBalance: Bool {
        !balances.isEmpty
    }

    private var hasReservedPayments: Bool {
        !reserved.isEmpty
    }

    private var bridgeAvailable: Bool {
        viewModel.thirdwebGuestWalletBridge.isBridgeAvailable
    }

    private var hasGuestWallet: Bool {
        !(viewModel.thirdwebGuestWalletBridge.walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var x402SetupReadiness: X402ReadinessState {
        X402ReadinessEvaluator.evaluate(
            allowX402Payments: true,
            bridgeAvailable: bridgeAvailable,
            walletAddress: viewModel.thirdwebGuestWalletBridge.walletAddress
        )
    }

    private var x402ActionMessage: String? {
        switch thirdwebActionState {
        case .idle:
            return nil
        case .connecting:
            return "Creating or reconnecting your guest wallet..."
        case .resetting:
            return "Resetting wallet..."
        case .note(let message), .success(let message), .failure(let message):
            return message
        }
    }

    private var x402ActionMessageColor: Color {
        switch thirdwebActionState {
        case .success:
            return .green
        case .failure:
            return .red
        default:
            return .secondary
        }
    }

    private var canConnectGuestWallet: Bool {
        bridgeAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Wallet rail", selection: $tab) {
                ForEach(WalletSetupTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .cashu:
                        cashuTab
                    case .x402:
                        x402Tab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .navigationTitle("Wallet Setup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(accent)
        .onAppear {
            scheduleReload(immediate: true)
            if tab == .x402 {
                Task { await viewModel.thirdwebGuestWalletBridge.prewarm(timeoutSeconds: 20) }
            }
        }
        .onDisappear {
            reloadScheduler.cancel()
        }
        .onChange(of: tab) { newValue in
            if newValue == .x402 {
                Task { await viewModel.thirdwebGuestWalletBridge.prewarm(timeoutSeconds: 20) }
            }
        }
        .onChange(of: viewModel.cashuMintAllowlistStore.allowedMintURLs) { _ in
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cashuWalletDidUpdate)) { _ in
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thirdwebWalletDidUpdate)) { _ in
            scheduleReload()
        }
    }

    @ViewBuilder
    private var cashuTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cashu is like digital cash. You can import a token to add funds, then pay agents even without internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                SettingsIconRow(icon: "1.circle", title: "Import token", subtitle: "Paste a cashuA or cashuB token.")
                SettingsIconRow(icon: "2.circle", title: "Approve mint", subtitle: "New mints must be approved before import/pay.")
                SettingsIconRow(icon: "3.circle", title: "Ready to pay", subtitle: hasCashuBalance ? "You have spendable balance." : "No spendable balance yet.")

                TextEditor(text: $importTokenText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 110)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Paste Cashu token")

                HStack(spacing: 10) {
                    Button("Paste") {
                        importTokenText = readPasteboardString() ?? importTokenText
                    }
                    .buttonStyle(.bordered)

                    Button("Import") {
                        beginImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importTokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let importStatus {
                    Text(importStatus)
                        .font(.footnote)
                        .foregroundStyle(importStatusTone.color)
                }
            }
        } label: {
            Label("Cashu", systemImage: "wallet.pass")
        }

        if !pendingMintApprovals.isEmpty {
            let stillUnapproved = pendingMintApprovals.filter { !viewModel.cashuMintAllowlistStore.isAllowed(mintURL: $0) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This token is from a new mint. You must approve it before you can import or spend it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pendingMintApprovals, id: \.self) { mint in
                            Text(mint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.12))
                    )

                    HStack(spacing: 10) {
                        Button("Cancel") {
                            pendingMintApprovals = []
                            pendingNormalizedImportToken = nil
                            pendingImportBundles = []
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Approve mints") {
                            for mint in pendingMintApprovals {
                                viewModel.cashuMintAllowlistStore.allow(mintURL: mint)
                            }
                            scheduleReload(immediate: true)
                        }
                        .buttonStyle(.bordered)

                        Button("Import now") {
                            importNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!stillUnapproved.isEmpty)
                    }

                    if !stillUnapproved.isEmpty {
                        Text("Tap “Approve mints” first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Label("Mint Approval Needed", systemImage: "checkmark.shield")
            }
        }

        NavigationLink {
            MintAllowlistView()
        } label: {
            SettingsIconRow(
                icon: "checkmark.shield",
                title: "Manage approved mints",
                subtitle: "Only approved mints can be used for imports and payments."
            )
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if balances.isEmpty {
                    Text("No balance yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableMintURLs, id: \.self) { mintURL in
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsIconRow(
                                icon: "link",
                                title: URL(string: mintURL)?.host ?? mintURL,
                                subtitle: mintURL
                            )
                            let byUnit = balances[mintURL] ?? [:]
                            ForEach(byUnit.keys.sorted(), id: \.self) { unit in
                                let amount = byUnit[unit] ?? 0
                                Text("\(amount) \(unit)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvancedCashu) {
                    VStack(alignment: .leading, spacing: 14) {
                        exportControls
                        Divider()
                        reservedSummary
                    }
                    .padding(.top, 8)
                }
                .font(.footnote)
            }
        } label: {
            Label("Balances", systemImage: "tray.full")
        }
    }

    @ViewBuilder
    private var x402Tab: some View {
            GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("x402 is the online-only option. If you have internet, it can be used to pay without Cashu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("A guest wallet is a temporary wallet BitChat creates for you. No account is required.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("BitChat keeps the wallet on this device and stores only the wallet address in this beta.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                SettingsIconRow(
                    icon: x402SetupReadiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle",
                    title: "Status: \(x402SetupReadiness.title)",
                    subtitle: x402SetupReadiness.detail
                )

                if !bridgeAvailable {
                    Text("thirdweb bridge is unavailable on this device.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                Button("Connect guest wallet") {
                            connectThirdwebGuestWallet()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(thirdwebActionState.isBusy || !canConnectGuestWallet)

                        if thirdwebActionState.isBusy {
                            ProgressView()
                                .progressViewStyle(.circular)
                            }
                }

                        if let x402ActionMessage {
                            Text(x402ActionMessage)
                                .font(.footnote)
                                .foregroundStyle(x402ActionMessageColor)
                        }

                SettingsIconRow(
                    icon: "person.crop.circle",
                    title: "Wallet: \(viewModel.thirdwebGuestWalletBridge.walletAddress ?? "not connected")"
                )
                if let pathSummary = viewModel.lastX402PaymentContext?.pathSummary {
                    SettingsIconRow(icon: "arrow.triangle.branch", title: "Last payment: \(pathSummary)")
                        .textSelection(.enabled)
                }

                NavigationLink {
                    X402LearnMoreView()
                } label: {
                    SettingsIconRow(
                        icon: "info.circle",
                        title: "Learn more",
                        subtitle: "What x402 is, what it shares, and when to use Cashu instead."
                    )
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvancedX402) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Reset wallet") {
                            resetThirdwebWallet()
                        }
                        .buttonStyle(.bordered)
                        .disabled(thirdwebActionState.isBusy)

                        Text("If you remove or reset your guest wallet, any remaining funds in that wallet move with it and become inaccessible from BitChat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    // DisclosureGroup content is indented by default; counter that so it lines up with the rest of the card.
                }
            }
        } label: {
            Label("x402", systemImage: "globe")
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsIconRow(icon: "square.and.arrow.up", title: "Export token", subtitle: "Create a transferable token slice.")

            if availableMintURLs.isEmpty {
                Text("Export is available after importing a token.")
                    .font(.footnote)
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

                HStack(spacing: 10) {
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
                        .foregroundStyle(exportStatusTone.color)
                }

                if !exportTokenResult.isEmpty {
                    TextEditor(text: $exportTokenResult)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var reservedSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsIconRow(icon: "clock.arrow.circlepath", title: "Reserved (in-flight)")

            if !hasReservedPayments {
                Text("No in-flight payments.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reserved) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("payment \(item.paymentID.prefix(8))…")
                            .font(.system(.caption, design: .monospaced))
                        Text("\(item.amount) \(item.unit) • \(URL(string: item.mintURL)?.host ?? item.mintURL)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func readinessRow(title: String, detail: String, isReady: Bool) -> some View {
        SettingsIconRow(
            icon: isReady ? "checkmark.circle.fill" : "exclamationmark.circle",
            title: "\(title): \(detail)"
        )
    }

    private func scheduleReload(immediate: Bool = false) {
        reloadScheduler.schedule(immediate: immediate) {
            reloadNow()
        }
    }

    private func reloadNow() {
        let nextBalances = viewModel.cashuWalletService.balancesByMintAndUnit()
        if balances != nextBalances {
            balances = nextBalances
        }

        let nextReserved = viewModel.cashuWalletService.reservedSummary().map {
            ReservedPaymentSummary(paymentID: $0.paymentID, mintURL: $0.mintURL, unit: $0.unit, amount: $0.amount)
        }
        if reserved != nextReserved {
            reserved = nextReserved
        }

        let availableMints = Array(nextBalances.keys).sorted()
        let nextMintSelection = Self.resolveSelection(current: exportMintURL, available: availableMints)
        if exportMintURL != nextMintSelection {
            exportMintURL = nextMintSelection
        }

        let availableUnits = nextBalances[nextMintSelection]?.keys.sorted() ?? []
        let nextUnitSelection = Self.resolveSelection(current: exportUnit, available: availableUnits, fallback: "sat")
        if exportUnit != nextUnitSelection {
            exportUnit = nextUnitSelection
        }
    }

    static func resolveSelection(current: String, available: [String], fallback: String = "") -> String {
        if available.contains(current) {
            return current
        }
        return available.first ?? fallback
    }

    private func beginImport() {
        importStatus = nil
        importStatusTone = .neutral
        exportStatus = nil
        exportStatusTone = .neutral

        guard let normalizedToken = CashuTokenParser.extractFirstTokenCandidate(from: importTokenText),
              let bundles = CashuTokenParser.parseTokenString(normalizedToken) else {
            importStatus = "Couldn't parse token. Supported: cashuA/cashuB."
            importStatusTone = .failure
            return
        }

        pendingNormalizedImportToken = normalizedToken
        pendingImportBundles = bundles

        let mints = Array(Set(bundles.map { CashuMintAllowlistStore.normalizeMintURL($0.mintURL) }))
            .filter { !$0.isEmpty }
            .sorted()
        let unapproved = mints.filter { !viewModel.cashuMintAllowlistStore.isAllowed(mintURL: $0) }
        if !unapproved.isEmpty {
            pendingMintApprovals = unapproved
            return
        }

        importNow()
    }

    private func importNow() {
        let token: String
        let bundles: [CashuMintProofBundle]

        if let pendingNormalizedImportToken, !pendingNormalizedImportToken.isEmpty, !pendingImportBundles.isEmpty {
            token = pendingNormalizedImportToken
            bundles = pendingImportBundles
        } else {
            guard let normalizedToken = CashuTokenParser.extractFirstTokenCandidate(from: importTokenText),
                  let parsed = CashuTokenParser.parseTokenString(normalizedToken) else {
                importStatus = "Couldn't parse token. Supported: cashuA/cashuB."
                importStatusTone = .failure
                return
            }
            token = normalizedToken
            bundles = parsed
        }

        do {
            let imported = try viewModel.cashuWalletService.importToken(token)
            if imported == 0 {
                importStatus = "Token already imported."
                importStatusTone = .neutral
            } else {
                let mintHosts = Array(Set(bundles.map { URL(string: $0.mintURL)?.host ?? $0.mintURL })).sorted()
                let units = Array(Set(bundles.map(\.unit))).sorted()
                if mintHosts.count == 1, units.count == 1 {
                    importStatus = "Imported \(imported) \(units[0]) from \(mintHosts[0])."
                } else {
                    importStatus = "Imported \(imported) across \(mintHosts.count) mint(s)."
                }
                importStatusTone = .success
            }
            importTokenText = ""
            pendingNormalizedImportToken = nil
            pendingImportBundles = []
            pendingMintApprovals = []
            scheduleReload(immediate: true)
        } catch {
            importStatus = error.localizedDescription
            importStatusTone = .failure
        }
    }

    private func exportToken() {
        exportStatus = nil
        exportStatusTone = .neutral

        let amountText = exportAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = UInt64(amountText), amount > 0 else {
            exportStatus = "Enter a valid amount."
            exportStatusTone = .failure
            return
        }
        do {
            let token = try viewModel.cashuWalletService.exportToken(mintURL: exportMintURL, unit: exportUnit, amount: amount)
            exportTokenResult = token
            exportStatus = "Exported \(amount) \(exportUnit)."
            exportStatusTone = .success
            scheduleReload(immediate: true)
        } catch {
            exportStatus = error.localizedDescription
            exportStatusTone = .failure
        }
    }

    private func connectThirdwebGuestWallet() {
        guard bridgeAvailable else {
            thirdwebActionState = .failure("thirdweb bridge is unavailable on this device.")
            return
        }
        thirdwebActionState = .connecting

        Task { @MainActor in
            do {
                let address = try await viewModel.thirdwebGuestWalletBridge.ensureGuestWallet()
                thirdwebActionState = .success("Connected guest wallet: \(address)")
                scheduleReload(immediate: true)
            } catch {
                thirdwebActionState = .failure(friendlyThirdwebError(error))
            }
        }
    }

    private func resetThirdwebWallet() {
        thirdwebActionState = .resetting
        Task { @MainActor in
            await viewModel.thirdwebGuestWalletBridge.resetWallet()
            thirdwebActionState = .success("Wallet reset.")
            scheduleReload(immediate: true)
        }
    }

    private func friendlyThirdwebError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return mapFriendlyThirdwebError(localized)
        }
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return mapFriendlyThirdwebError(raw)
    }

    private func mapFriendlyThirdwebError(_ message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "thirdweb action failed." }
        let lowered = normalized.lowercased()
        if lowered.contains("runtime is still loading") || lowered.contains("timed out") {
            return "thirdweb is still starting. Check internet, then try again."
        }
        if lowered.contains("script error") || lowered.contains("javascript") {
            return "thirdweb runtime failed to start. Check internet and try again."
        }
        if lowered.contains("importing a module script failed") || lowered.contains("module script") {
            return "thirdweb couldn't load its web libraries. Check your internet/CSP and try again."
        }
        return normalized
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

@MainActor
final class WalletReloadScheduler {
    private var task: Task<Void, Never>?
    private let delayNanoseconds: UInt64

    init(delayMilliseconds: UInt64 = 120) {
        self.delayNanoseconds = delayMilliseconds * 1_000_000
    }

    deinit {
        task?.cancel()
    }

    func schedule(immediate: Bool = false, operation: @escaping @MainActor () -> Void) {
        task?.cancel()
        if immediate {
            operation()
            task = nil
            return
        }
        task = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                operation()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

private struct ReservedPaymentSummary: Identifiable, Equatable {
    let paymentID: String
    let mintURL: String
    let unit: String
    let amount: UInt64

    var id: String { paymentID }
}

private enum InlineStatusTone {
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

private enum ThirdwebActionState: Equatable {
    case idle
    case connecting
    case resetting
    case note(String)
    case success(String)
    case failure(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .resetting:
            return true
        default:
            return false
        }
    }
}
