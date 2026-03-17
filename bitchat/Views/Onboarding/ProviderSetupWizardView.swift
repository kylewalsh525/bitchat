import SwiftUI

enum ProviderSetupGatewayURLValidation: Equatable {
    case valid(normalizedURL: String)
    case empty
    case invalid(reason: String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .valid:
            return nil
        case .empty:
            return "Enter a gateway URL."
        case .invalid(let reason):
            return reason
        }
    }
}

enum ProviderSetupValidator {
    static func validateGatewayURL(_ raw: String) -> ProviderSetupGatewayURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let components = URLComponents(string: trimmed) else {
            return .invalid(reason: "Enter a valid URL (for example, http://127.0.0.1:8080/agent/run).")
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .invalid(reason: "Gateway URL must use http:// or https://.")
        }
        guard let host = components.host, !host.isEmpty else {
            return .invalid(reason: "Gateway URL needs a host name.")
        }
        return .valid(normalizedURL: components.url?.absoluteString ?? trimmed)
    }
}

struct ProviderSetupWizardView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var step: Step = .intro
    @State private var draft: AgentConfig = .default
    @State private var loadedDraft = false

    @State private var gatewayHealth: AgentGatewayHealth = .idle
    @State private var catalogStatus: AgentCatalogStatus = .idle
    @State private var catalog: AgentCatalog? = nil

    @State private var acceptedMintsMultiline: String = ""
    @State private var memoryQuickNote: String = ""

    private let catalogService = AgentCatalogService()

    private enum Step: Int, CaseIterable {
        case intro
        case runtime
        case model
        case payments
        case finish

        var title: String {
            switch self {
            case .intro: return "Provider Mode"
            case .runtime: return "Runtime"
            case .model: return "Model"
            case .payments: return "Payments"
            case .finish: return "Finish"
            }
        }

        var subtitle: String {
            switch self {
            case .intro:
                return "Set the basics. You won’t advertise until the end."
            case .runtime:
                return "Choose echo mode or connect a local gateway."
            case .model:
                return "Pick a model (catalog optional) and set an optional model hash."
            case .payments:
                return "Optional. Configure Cashu or x402 terms."
            case .finish:
                return "Review and enable provider mode."
            }
        }
    }

    private var accent: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var surfaceBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(.windowBackgroundColor)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .navigationTitle("Provider Setup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(surfaceBackground.ignoresSafeArea())
        .tint(accent)
        .onAppear {
            viewModel.refreshAgentMemoryEntries()
            if !loadedDraft {
                draft = viewModel.agentConfig
                if !draft.enabled {
                    // Fresh provider enablement starts with payments off to avoid
                    // carrying stale terms from earlier experiments.
                    draft.paymentTerms = nil
                } else {
                    // Wizard is per-request pricing oriented. Strip hidden per-token
                    // fields so zero pricing behaves as expected.
                    draft.paymentTerms = normalizedWizardPaymentTerms(draft.paymentTerms)
                }
                acceptedMintsMultiline = (draft.paymentTerms?.acceptedMints ?? []).joined(separator: "\n")
                applySuggestedAcceptedMintsIfNeeded()
                loadedDraft = true
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(
                    value: Double(step.rawValue + 1),
                    total: Double(Step.allCases.count)
                )
                .tint(accent)
                .accessibilityLabel("Provider setup progress")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:
            introStep
        case .runtime:
            runtimeStep
        case .model:
            modelStep
        case .payments:
            paymentsStep
        case .finish:
            finishStep
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { goBack() }
                .buttonStyle(.bordered)
                .disabled(step == .intro)

            Spacer()

            Button(step == .finish ? "Enable" : "Continue") {
                if step == .finish {
                    enableProvider()
                } else {
                    goNext()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .intro:
            return !draft.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .runtime:
            if draft.runtime.mode == .gateway {
                return gatewayURLValidation.isValid
            }
            return true
        case .model:
            return !draft.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .payments:
            if let terms = draft.paymentTerms {
                if terms.paymentRail == .cashu {
                    if terms.effectivePriceModel == .perRequest, terms.pricePerRequest == 0 {
                        return true
                    }
                    let mints = parsedAcceptedMints()
                    return !mints.isEmpty && terms.sanitized() != nil
                }
                return terms.sanitized() != nil
            }
            return true
        case .finish:
            return true
        }
    }

    private var gatewayURLValidation: ProviderSetupGatewayURLValidation {
        ProviderSetupValidator.validateGatewayURL(draft.runtime.gatewayURL)
    }

    private var shouldShowGatewayValidationError: Bool {
        draft.runtime.mode == .gateway && !gatewayURLValidation.isValid
    }

    private var providerRoleBinding: Binding<AgentProviderRole> {
        Binding(
            get: { AgentProviderRole(normalizing: draft.role) },
            set: { draft.role = $0.rawValue }
        )
    }

    private var suggestedAcceptedMints: [String] {
        let normalized = viewModel.cashuMintAllowlistStore.allowedMintURLs
            .map(CashuMintAllowlistStore.normalizeMintURL)
            .filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: normalized)) as? [String] ?? normalized
    }
}

private extension ProviderSetupWizardView {
    var introStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Provider mode advertises your agent info to nearby peers. You can disable it anytime in Settings.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Model type") {
                    Picker("Model type", selection: providerRoleBinding) {
                        ForEach(AgentProviderRole.allCases, id: \.self) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Quality")
                        .font(.footnote.weight(.semibold))
                    Slider(
                        value: Binding(
                            get: { Double(draft.qualityScore) },
                            set: { draft.qualityScore = UInt8(max(0, min(100, Int($0)))) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                    Text("\(draft.qualityScore)/100")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

            Text("Tip: if you don’t know what to pick, use `General` and quality `50`.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: Binding(
                get: { draft.runtime.mode },
                set: { draft.runtime.mode = $0 }
            )) {
                Text("Echo (demo)").tag(AgentRuntimeMode.echo)
                Text("Gateway").tag(AgentRuntimeMode.gateway)
            }
            .pickerStyle(.segmented)

            if draft.runtime.mode == .gateway {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: Binding(
                        get: { draft.runtime.gatewayPreset },
                        set: { preset in
                            draft.runtime.gatewayPreset = preset
                            if preset != .custom {
                                draft.runtime.gatewayURL = preset.defaultURL
                            }
                            gatewayHealth = .idle
                            catalogStatus = .idle
                            catalog = nil
                        }
                    )) {
                        ForEach([AgentGatewayPreset.localOllama, .localLMStudio, .custom], id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }

                    LabeledContent("Gateway URL") {
                        TextField("http://127.0.0.1:8080/agent/run", text: Binding(
                            get: { draft.runtime.gatewayURL },
                            set: { value in
                                draft.runtime.gatewayURL = value
                                if gatewayHealth != .idle {
                                    gatewayHealth = .idle
                                }
                                if catalogStatus != .idle {
                                    catalogStatus = .idle
                                }
                            }
                        ))
                        .autocorrectionDisabled(true)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    }

                    if shouldShowGatewayValidationError, let message = gatewayURLValidation.errorDescription {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LabeledContent("Token (optional)") {
                        SecureField("token", text: Binding(
                            get: { draft.runtime.gatewayToken ?? "" },
                            set: { value in
                                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                draft.runtime.gatewayToken = trimmed.isEmpty ? nil : trimmed
                            }
                        ))
                        .multilineTextAlignment(.trailing)
                    }

                    Toggle("Stream responses", isOn: Binding(
                        get: { draft.runtime.streamResponses },
                        set: { draft.runtime.streamResponses = $0 }
                    ))

                    Stepper(
                        value: Binding(
                            get: { Int(draft.runtime.timeoutSeconds) },
                            set: { draft.runtime.timeoutSeconds = UInt32(max(5, min(300, $0))) }
                        ),
                        in: 5...300,
                        step: 5
                    ) {
                        Text("Runtime timeout: \(draft.runtime.timeoutSeconds)s")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Test connection") {
                            testGateway()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!gatewayURLValidation.isValid)

                        Button("Fetch catalog") {
                            fetchCatalog()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!gatewayURLValidation.isValid)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        statusRow(
                            title: "Connection",
                            status: healthStatusSummary()
                        )
                        statusRow(
                            title: "Catalog",
                            status: catalogStatusSummary()
                        )
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

                Text("Gateway runs locally (for example, on your laptop). Your model identity (`modelHash`) is self-attested, not proof of compute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Echo mode is useful for testing provider discovery and payment flows. It does not run a real model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.runtime.mode == .gateway {
                if let catalog, !catalog.models.isEmpty {
                    Text("Select a model from the gateway catalog:")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(catalog.models) { model in
                            Button {
                                selectCatalogModel(model)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name ?? model.id)
                                            .font(.system(.body, design: .monospaced))
                                        Text(model.provider)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if draft.modelId == model.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))
                } else {
                    Text("No catalog loaded yet. You can continue with manual entry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Model ID") {
                    TextField("model", text: Binding(
                        get: { draft.modelId },
                        set: { draft.modelId = $0 }
                    ))
                    .autocorrectionDisabled(true)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                }

                LabeledContent("Model hash (optional)") {
                    TextField("ollama:sha256:…", text: Binding(
                        get: { draft.modelHash ?? "" },
                        set: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.modelHash = trimmed.isEmpty ? nil : trimmed
                        }
                    ))
                    .autocorrectionDisabled(true)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-recall relevant memory", isOn: Binding(
                    get: { viewModel.agentMemoryAutoRecallEnabled },
                    set: { viewModel.setAgentMemoryAutoRecall(enabled: $0) }
                ))

                if viewModel.agentMemoryEntries.isEmpty {
                    Text("No memory notes yet. Add one to improve follow-up answers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Create today’s memory note") {
                        _ = viewModel.ensureTodayMemoryEntrySelected()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Attach memory notes to include with requests:")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.agentMemoryEntries, id: \.id) { entry in
                        Toggle(isOn: Binding(
                            get: { viewModel.isAgentMemoryEntryAttached(entry.id) },
                            set: { _ in viewModel.toggleAttachedAgentMemoryEntry(entryID: entry.id) }
                        )) {
                            Text(viewModel.memoryEntryLabel(for: entry))
                                .font(.footnote)
                        }
                    }
                    Text("\(viewModel.attachedAgentMemoryEntryIDs.count) attached")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("Quick memory note", text: $memoryQuickNote)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = memoryQuickNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        _ = viewModel.appendAgentDailyMemoryNote(trimmed)
                        memoryQuickNote = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(memoryQuickNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

            Text("`modelHash` is a self-attested artifact digest (identity-bound via signed announces). It is not proof the model is actually running.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    var paymentsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable payments", isOn: Binding(
                get: { draft.paymentTerms != nil },
                set: { enabled in
                    if enabled {
                        if draft.paymentTerms == nil {
                            draft.paymentTerms = AgentPaymentTerms(
                                paymentRail: .cashu,
                                settlementMode: .onlineRequired,
                                unit: "sat",
                                priceModel: .perRequest,
                                pricePerRequest: 100,
                                acceptedMints: suggestedAcceptedMints,
                                requestTTLSeconds: 120
                            )
                        }
                    } else {
                        draft.paymentTerms = nil
                    }
                    draft.paymentTerms = normalizedWizardPaymentTerms(draft.paymentTerms)
                    acceptedMintsMultiline = (draft.paymentTerms?.acceptedMints ?? []).joined(separator: "\n")
                    applySuggestedAcceptedMintsIfNeeded()
                }
            ))

            if draft.paymentTerms != nil {
                if let terms = draft.paymentTerms {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Effective payment terms")
                            .font(.footnote.weight(.semibold))
                        Text("Rail: \(terms.paymentRail.rawValue) · Settlement: \(terms.settlementMode.rawValue) · Locking: \((terms.requiresLocking ?? .none).rawValue) · TTL: \(terms.requestTTLSeconds == 0 ? 120 : terms.requestTTLSeconds)s")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Price 0 disables payment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Advertise as notary signer", isOn: Binding(
                    get: { draft.notaryPolicy.isNotaryCapable },
                    set: { draft.notaryPolicy.isNotaryCapable = $0 }
                ))

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Rail", selection: Binding(
                        get: { draft.paymentTerms?.paymentRail ?? .cashu },
                        set: { rail in
                            guard var terms = draft.paymentTerms else { return }
                            terms.paymentRail = rail
                            if rail == .x402 {
                                terms.settlementMode = .onlineRequired
                                terms.requiresLocking = AgentPaymentLockingMode.none
                                terms.priceModel = .perRequest
                                terms.pricePerInputToken = nil
                                terms.pricePerOutputToken = nil
                                terms.minDeposit = nil
                                terms.granularityTokens = nil
                                if terms.unit.isEmpty { terms.unit = "usdc" }
                                if terms.pricePerRequest == 0 { terms.pricePerRequest = 100 }
                                terms.acceptedMints = []
                                acceptedMintsMultiline = ""
                                if terms.x402ChainID == nil || terms.x402ChainID == 0 {
                                    terms.x402ChainID = 8453
                                }
                                if terms.x402FacilitatorID?.isEmpty != false {
                                    terms.x402FacilitatorID = "thirdweb"
                                }
                            } else {
                                terms.x402ChainID = nil
                                terms.x402TokenAddress = nil
                                terms.x402PayTo = nil
                                terms.x402GatewayURL = nil
                                terms.x402FacilitatorID = nil
                                terms.x402Scheme = nil
                                terms.priceModel = .perRequest
                                terms.pricePerInputToken = nil
                                terms.pricePerOutputToken = nil
                                terms.minDeposit = nil
                                terms.granularityTokens = nil
                                if terms.unit.isEmpty { terms.unit = "sat" }
                                if terms.acceptedMints.isEmpty {
                                    terms.acceptedMints = suggestedAcceptedMints
                                }
                            }
                            draft.paymentTerms = terms
                            acceptedMintsMultiline = (draft.paymentTerms?.acceptedMints ?? []).joined(separator: "\n")
                            applySuggestedAcceptedMintsIfNeeded()
                        }
                    )) {
                        Text("Cashu").tag(AgentPaymentRail.cashu)
                        Text("x402").tag(AgentPaymentRail.x402)
                    }

                    if (draft.paymentTerms?.paymentRail ?? .cashu) == .cashu {
                        Picker("Settlement", selection: Binding(
                            get: { draft.paymentTerms?.settlementMode ?? .onlineRequired },
                            set: { mode in
                                guard var terms = draft.paymentTerms else { return }
                                terms.settlementMode = mode
                                if mode == .offlineAccepted {
                                    terms.requiresLocking = .p2pk
                                } else {
                                    terms.requiresLocking = AgentPaymentLockingMode.none
                                }
                                draft.paymentTerms = terms
                            }
                        )) {
                            Text("Online required").tag(AgentSettlementMode.onlineRequired)
                            Text("Offline accepted").tag(AgentSettlementMode.offlineAccepted)
                        }

                        Picker("Locking", selection: Binding(
                            get: { draft.paymentTerms?.requiresLocking ?? (draft.paymentTerms?.settlementMode == .offlineAccepted ? .p2pk : AgentPaymentLockingMode.none) },
                            set: { mode in
                                guard var terms = draft.paymentTerms else { return }
                                terms.requiresLocking = mode
                                draft.paymentTerms = terms
                            }
                        )) {
                            Text("P2PK").tag(AgentPaymentLockingMode.p2pk)
                            Text("None (unsafe)").tag(AgentPaymentLockingMode.none)
                        }

                        LabeledContent("Unit") {
                            TextField("sat", text: Binding(
                                get: { draft.paymentTerms?.unit ?? "sat" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.unit = value
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Price per request") {
                            TextField("100", text: Binding(
                                get: { String(draft.paymentTerms?.pricePerRequest ?? 100) },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    if let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        terms.priceModel = .perRequest
                                        terms.pricePerInputToken = nil
                                        terms.pricePerOutputToken = nil
                                        terms.minDeposit = nil
                                        terms.granularityTokens = nil
                                        terms.pricePerRequest = parsed
                                        draft.paymentTerms = terms
                                    }
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }

                        quoteTierPolicySection

                        LabeledContent("Request TTL (seconds)") {
                            TextField("120", text: Binding(
                                get: { String(draft.paymentTerms?.requestTTLSeconds ?? 120) },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    if let parsed = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        terms.requestTTLSeconds = parsed
                                        draft.paymentTerms = terms
                                    }
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Accepted mints (one per line)")
                                .font(.footnote.weight(.semibold))
                            Text("Add mint URLs you are willing to accept. Requesters can pay you when they have funds in at least one matching mint.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $acceptedMintsMultiline)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 90)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
                                )
                                .autocorrectionDisabled(true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            if !suggestedAcceptedMints.isEmpty {
                                Button("Use my approved wallet mints (\(suggestedAcceptedMints.count))") {
                                    acceptedMintsMultiline = suggestedAcceptedMints.joined(separator: "\n")
                                    if var terms = draft.paymentTerms {
                                        terms.acceptedMints = suggestedAcceptedMints
                                        draft.paymentTerms = terms
                                    }
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Text("No approved wallet mints found yet. Add mints in Wallet → Mint Allowlist, then return here.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(parsedAcceptedMints().isEmpty ? "At least one mint is required." : "\(parsedAcceptedMints().count) mint(s)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent("Unit") {
                            TextField("usdc", text: Binding(
                                get: { draft.paymentTerms?.unit ?? "usdc" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.unit = value
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Price per request") {
                            TextField("100", text: Binding(
                                get: { String(draft.paymentTerms?.pricePerRequest ?? 100) },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    if let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        terms.priceModel = .perRequest
                                        terms.pricePerInputToken = nil
                                        terms.pricePerOutputToken = nil
                                        terms.minDeposit = nil
                                        terms.granularityTokens = nil
                                        terms.pricePerRequest = parsed
                                        draft.paymentTerms = terms
                                    }
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }

                        quoteTierPolicySection

                        LabeledContent("Chain ID") {
                            TextField("8453", text: Binding(
                                get: { String(draft.paymentTerms?.x402ChainID ?? 8453) },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    if let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        terms.x402ChainID = parsed
                                        draft.paymentTerms = terms
                                    }
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }

                        LabeledContent("Token address") {
                            TextField("0x...", text: Binding(
                                get: { draft.paymentTerms?.x402TokenAddress ?? "" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.x402TokenAddress = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Pay-to address") {
                            TextField("0x...", text: Binding(
                                get: { draft.paymentTerms?.x402PayTo ?? "" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.x402PayTo = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Gateway URL") {
                            TextField("https://provider.example/x402", text: Binding(
                                get: { draft.paymentTerms?.x402GatewayURL ?? "" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.x402GatewayURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Facilitator ID") {
                            TextField("thirdweb", text: Binding(
                                get: { draft.paymentTerms?.x402FacilitatorID ?? "thirdweb" },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    terms.x402FacilitatorID = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    draft.paymentTerms = terms
                                }
                            ))
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        }

                        LabeledContent("Request TTL (seconds)") {
                            TextField("120", text: Binding(
                                get: { String(draft.paymentTerms?.requestTTLSeconds ?? 120) },
                                set: { value in
                                    guard var terms = draft.paymentTerms else { return }
                                    if let parsed = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                        terms.requestTTLSeconds = parsed
                                        draft.paymentTerms = terms
                                    }
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }

                        Text("x402 is online-only and less private than Cashu. Use this when both requester and provider have internet path.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

                if (draft.paymentTerms?.paymentRail ?? .cashu) == .cashu,
                   (draft.paymentTerms?.settlementMode ?? .onlineRequired) == .offlineAccepted {
                    Text("Offline acceptance is higher risk until the mint finalizes. Default locking is P2PK (recommended).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if (draft.paymentTerms?.requiresLocking ?? .p2pk) == .none {
                        Label("Unsafe configuration: offline acceptance without P2PK locking.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Require notary receipts", isOn: Binding(
                            get: { draft.notaryPolicy.requiredOfflineSignatures > 0 },
                            set: { enabled in
                                if enabled && draft.notaryPolicy.requiredOfflineSignatures == 0 {
                                    draft.notaryPolicy.requiredOfflineSignatures = 2
                                }
                                if !enabled {
                                    draft.notaryPolicy.requiredOfflineSignatures = 0
                                }
                            }
                        ))

                        if draft.notaryPolicy.requiredOfflineSignatures > 0 {
                            Stepper(
                                value: Binding(
                                    get: { Int(draft.notaryPolicy.requiredOfflineSignatures) },
                                    set: { draft.notaryPolicy.requiredOfflineSignatures = UInt8(max(1, min(8, $0))) }
                                ),
                                in: 1...8
                            ) {
                                Text("Required receipts: \(draft.notaryPolicy.requiredOfflineSignatures)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Stepper(
                                value: Binding(
                                    get: { Int(draft.notaryPolicy.collectTimeoutMs / 1000) },
                                    set: { seconds in
                                        let clamped = max(1, min(15, seconds))
                                        draft.notaryPolicy.collectTimeoutMs = UInt64(clamped) * 1000
                                    }
                                ),
                                in: 1...15
                            ) {
                                Text("Collect timeout: \(max(1, Int(draft.notaryPolicy.collectTimeoutMs / 1000)))s")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Notaries are peers that can attest to a spend attempt. This reduces offline double-spend risk.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            } else {
                Text("Payments are optional. You can enable them later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var quoteTierPolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quote wait options")
                .font(.footnote.weight(.semibold))

            Stepper(
                value: Binding(
                    get: { Int(draft.quoteTierPolicy.sanitized().immediateDiscountBps) },
                    set: { value in
                        draft.quoteTierPolicy.immediateDiscountBps = UInt16(max(0, min(9_500, value)))
                        draft.quoteTierPolicy = draft.quoteTierPolicy.sanitized()
                    }
                ),
                in: 0...9_500,
                step: 100
            ) {
                Text("Immediate discount: \(draft.quoteTierPolicy.sanitized().immediateDiscountBps / 100)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Stepper(
                value: Binding(
                    get: { Int(draft.quoteTierPolicy.sanitized().standardWaitSeconds) },
                    set: { value in
                        draft.quoteTierPolicy.standardWaitSeconds = UInt16(max(5, min(300, value)))
                        draft.quoteTierPolicy = draft.quoteTierPolicy.sanitized()
                    }
                ),
                in: 5...300,
                step: 5
            ) {
                Text("Standard wait: ~\(draft.quoteTierPolicy.sanitized().standardWaitSeconds)s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Stepper(
                value: Binding(
                    get: { Int(draft.quoteTierPolicy.sanitized().standardDiscountBps) },
                    set: { value in
                        draft.quoteTierPolicy.standardDiscountBps = UInt16(max(0, min(9_500, value)))
                        draft.quoteTierPolicy = draft.quoteTierPolicy.sanitized()
                    }
                ),
                in: 0...9_500,
                step: 100
            ) {
                Text("Standard discount: \(draft.quoteTierPolicy.sanitized().standardDiscountBps / 100)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Stepper(
                value: Binding(
                    get: { Int(draft.quoteTierPolicy.sanitized().economyWaitSeconds) },
                    set: { value in
                        draft.quoteTierPolicy.economyWaitSeconds = UInt16(max(10, min(900, value)))
                        draft.quoteTierPolicy = draft.quoteTierPolicy.sanitized()
                    }
                ),
                in: 10...900,
                step: 10
            ) {
                Text("Economy wait: ~\(draft.quoteTierPolicy.sanitized().economyWaitSeconds)s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Stepper(
                value: Binding(
                    get: { Int(draft.quoteTierPolicy.sanitized().economyDiscountBps) },
                    set: { value in
                        draft.quoteTierPolicy.economyDiscountBps = UInt16(max(0, min(9_500, value)))
                        draft.quoteTierPolicy = draft.quoteTierPolicy.sanitized()
                    }
                ),
                in: 0...9_500,
                step: 100
            ) {
                Text("Economy discount: \(draft.quoteTierPolicy.sanitized().economyDiscountBps / 100)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You are about to advertise as a provider.")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Role", draft.role)
                summaryRow("Model", draft.modelId)
                summaryRow("Quality", "\(draft.qualityScore)/100")
                summaryRow("Runtime", draft.runtime.mode.rawValue)
                summaryRow("Timeout", "\(draft.runtime.timeoutSeconds)s")
                if draft.runtime.mode == .gateway {
                    summaryRow("Gateway", draft.runtime.gatewayURL)
                }
                summaryRow("Memory recall", viewModel.agentMemoryAutoRecallEnabled ? "on" : "off")
                summaryRow("Attached memory", "\(viewModel.attachedAgentMemoryEntryIDs.count)")
                if let terms = draft.paymentTerms?.sanitized() {
                    summaryRow("Payments", terms.paymentRail.rawValue)
                    summaryRow("Settlement", terms.settlementMode.rawValue)
                    summaryRow("Unit", terms.unit)
                    summaryRow("Price", "\(terms.pricePerRequest) \(terms.unit)")
                    summaryRow("Standard wait", "~\(draft.quoteTierPolicy.sanitized().standardWaitSeconds)s")
                    summaryRow("Economy wait", "~\(draft.quoteTierPolicy.sanitized().economyWaitSeconds)s")
                    if terms.paymentRail == .cashu {
                        summaryRow("Locking", (terms.requiresLocking ?? .none).rawValue)
                        if draft.notaryPolicy.requiredOfflineSignatures > 0 {
                            let secs = max(1, Int(draft.notaryPolicy.collectTimeoutMs / 1000))
                            summaryRow("Notary", "\(draft.notaryPolicy.requiredOfflineSignatures) receipts / \(secs)s")
                        }
                        summaryRow("Mints", "\(parsedAcceptedMints().count)")
                    } else {
                        summaryRow("Chain", "eip155:\(terms.x402ChainID ?? 0)")
                        summaryRow("Token", terms.x402TokenAddress ?? "unset")
                    }
                } else {
                    summaryRow("Payments", "disabled")
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))

            Text("After enabling, nearby peers can discover you and send agent requests.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label + ":")
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    func goNext() {
        guard let idx = Step.allCases.firstIndex(of: step) else { return }
        let next = Step.allCases.index(after: idx)
        if next < Step.allCases.endIndex {
            step = Step.allCases[next]
        }
    }

    func goBack() {
        guard let idx = Step.allCases.firstIndex(of: step), idx > Step.allCases.startIndex else { return }
        step = Step.allCases[Step.allCases.index(before: idx)]
    }

    func parsedAcceptedMints() -> [String] {
        acceptedMintsMultiline
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(CashuMintAllowlistStore.normalizeMintURL)
            .filter { !$0.isEmpty }
    }

    func applySuggestedAcceptedMintsIfNeeded(force: Bool = false) {
        guard var terms = draft.paymentTerms, terms.paymentRail == .cashu else { return }
        let existing = parsedAcceptedMints()
        guard force || existing.isEmpty else { return }
        guard !suggestedAcceptedMints.isEmpty else { return }
        terms.acceptedMints = suggestedAcceptedMints
        draft.paymentTerms = terms
        acceptedMintsMultiline = suggestedAcceptedMints.joined(separator: "\n")
    }

    func healthStatusSummary() -> (text: String, tone: Color, icon: String) {
        switch gatewayHealth {
        case .idle:
            return ("Not tested yet", .secondary, "circle")
        case .checking:
            return ("Checking…", .secondary, "clock")
        case .ok:
            return ("Connected", .green, "checkmark.circle.fill")
        case .failed:
            return ("Failed", .orange, "xmark.octagon.fill")
        }
    }

    func catalogStatusSummary() -> (text: String, tone: Color, icon: String) {
        switch catalogStatus {
        case .idle:
            return ("Not fetched yet", .secondary, "circle")
        case .loading:
            return ("Loading…", .secondary, "clock")
        case .loaded:
            return ("Loaded", .green, "checkmark.circle.fill")
        case .failed:
            return ("Failed", .orange, "xmark.octagon.fill")
        }
    }

    func statusDetail(for status: AgentGatewayHealth) -> String? {
        switch status {
        case .failed(let message):
            return message
        case .ok(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .idle, .checking:
            return nil
        }
    }

    func statusDetail(for status: AgentCatalogStatus) -> String? {
        switch status {
        case .failed(let message):
            return message
        case .loaded(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .idle, .loading:
            return nil
        }
    }

    func statusRow(title: String, status: (text: String, tone: Color, icon: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(status.text, systemImage: status.icon)
                    .font(.footnote)
                    .foregroundStyle(status.tone)
            }
            if title == "Connection", let detail = statusDetail(for: gatewayHealth) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if title == "Catalog", let detail = statusDetail(for: catalogStatus) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func testGateway() {
        switch gatewayURLValidation {
        case .valid(let normalizedURL):
            gatewayHealth = .checking
            Task { @MainActor in
                let result = await catalogService.checkHealth(urlString: normalizedURL)
                switch result {
                case .success:
                    gatewayHealth = .ok(Date())
                case .failure(let error):
                    gatewayHealth = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        case .empty, .invalid:
            gatewayHealth = .failed(gatewayURLValidation.errorDescription ?? "Enter a valid gateway URL.")
        }
    }

    func fetchCatalog() {
        switch gatewayURLValidation {
        case .valid(let normalizedURL):
            catalogStatus = .loading
            Task { @MainActor in
                let result = await catalogService.fetchCatalog(urlString: normalizedURL)
                switch result {
                case .success(let catalog):
                    self.catalog = catalog
                    self.catalogStatus = .loaded(Date())
                case .failure(let error):
                    self.catalogStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        case .empty, .invalid:
            catalogStatus = .failed(gatewayURLValidation.errorDescription ?? "Enter a valid gateway URL.")
        }
    }

    func selectCatalogModel(_ model: AgentCatalogModel) {
        draft.modelId = model.id
        if let quality = model.qualityScore {
            draft.qualityScore = quality
        }
        if let hash = model.modelHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty {
            draft.modelHash = hash
        }
    }

    func normalizedWizardPaymentTerms(_ terms: AgentPaymentTerms?) -> AgentPaymentTerms? {
        guard var terms else { return nil }
        if terms.paymentRail == .cashu {
            terms.priceModel = .perRequest
            terms.pricePerInputToken = nil
            terms.pricePerOutputToken = nil
            terms.minDeposit = nil
            terms.granularityTokens = nil
            if terms.requestTTLSeconds == 0 {
                terms.requestTTLSeconds = 120
            }
            if terms.requiresLocking == nil {
                terms.requiresLocking = terms.settlementMode == .offlineAccepted ? .p2pk : AgentPaymentLockingMode.none
            }
        }
        return terms
    }

    func enableProvider() {
        var final = draft
        final.enabled = true
        final.quoteTierPolicy = final.quoteTierPolicy.sanitized()

        if var terms = final.paymentTerms {
            terms = normalizedWizardPaymentTerms(terms) ?? terms
            if terms.paymentRail == .cashu {
                terms.acceptedMints = parsedAcceptedMints()
                if terms.settlementMode == .offlineAccepted, terms.requiresLocking == nil {
                    terms.requiresLocking = .p2pk
                }
            }
            final.paymentTerms = terms.sanitized()
        }

        viewModel.updateAgentConfig(final)
        viewModel.meshService.sendBroadcastAnnounce()
        Task { await SupportEventLog.shared.record(category: "provider", message: "provider enabled role=\(final.role) model=\(final.modelId)") }
        dismiss()
    }
}
