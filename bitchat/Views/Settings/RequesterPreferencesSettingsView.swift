import SwiftUI

struct RequesterPreferencesSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var knownModels: [AgentKnownModel] = []
    @State private var overlayURLString: String = ""
    @State private var updateStatusText: String = ""
    @State private var isUpdating: Bool = false
    @State private var quoteBudgetText: String = ""

    private var minQualityBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.agentRequesterPreferences.minQualityScore) },
            set: { value in
                let clamped = UInt8(max(0, min(100, Int(value))))
                viewModel.agentRequesterPreferences.minQualityScore = clamped
            }
        )
    }

    private var quoteAutoPickPolicyBinding: Binding<AgentQuoteAutoPickPolicy> {
        Binding(
            get: { viewModel.agentRequesterPreferences.quoteAutoPickPolicy },
            set: { viewModel.agentRequesterPreferences.quoteAutoPickPolicy = $0 }
        )
    }

    var body: some View {
        content
        .navigationTitle("Requester Preferences")
        .onAppear {
            reloadKnownModels()
            overlayURLString = viewModel.knownModelUpdateService.storedSourceURL() ?? ""
            updateStatusText = lastUpdateText()
            quoteBudgetText = viewModel.agentRequesterPreferences.quoteAutoPickBudget > 0
                ? String(viewModel.agentRequesterPreferences.quoteAutoPickBudget)
                : ""
        }
        .onChange(of: viewModel.agentRequesterPreferences.quoteAutoPickBudget) { newValue in
            let normalized = newValue > 0 ? String(newValue) : ""
            if quoteBudgetText != normalized {
                quoteBudgetText = normalized
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        Form {
            Section("Routing") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Min quality: \(Int(minQualityBinding.wrappedValue))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Slider(value: minQualityBinding, in: 0...100, step: 1)
                }

                Toggle("Prefer known open-source models", isOn: Binding(
                    get: { viewModel.agentRequesterPreferences.preferKnownModels },
                    set: { viewModel.agentRequesterPreferences.preferKnownModels = $0 }
                ))

                Toggle("Penalize unknown models", isOn: Binding(
                    get: { viewModel.agentRequesterPreferences.penalizeUnknownModels },
                    set: { viewModel.agentRequesterPreferences.penalizeUnknownModels = $0 }
                ))

                Toggle("Enable x402 payments (online only)", isOn: Binding(
                    get: { viewModel.agentRequesterPreferences.allowX402Payments },
                    set: { enabled in
                        viewModel.agentRequesterPreferences.allowX402Payments = enabled
                        if !enabled && viewModel.agentRequesterPreferences.defaultPaymentRail == .x402 {
                            viewModel.agentRequesterPreferences.defaultPaymentRail = .cashu
                        }
                    }
                ))

                Picker("Preferred payment rail", selection: Binding(
                    get: {
                        let preferred = viewModel.agentRequesterPreferences.defaultPaymentRail
                        if preferred == .x402 && !viewModel.agentRequesterPreferences.allowX402Payments {
                            return AgentPaymentRail.cashu
                        }
                        return preferred
                    },
                    set: { next in
                        if next == .x402 && !viewModel.agentRequesterPreferences.allowX402Payments {
                            viewModel.agentRequesterPreferences.allowX402Payments = true
                        }
                        viewModel.agentRequesterPreferences.defaultPaymentRail = (next == .none) ? .cashu : next
                    }
                )) {
                    Text("Cashu (private + offline-capable)").tag(AgentPaymentRail.cashu)
                    Text("x402 (online, less private)").tag(AgentPaymentRail.x402)
                }

                Text("Cashu works across BLE mesh and offers stronger privacy. x402 is online-only and uses on-chain/facilitator infrastructure.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Quote Selection") {
                Picker("Auto-pick policy", selection: quoteAutoPickPolicyBinding) {
                    Text("manual").tag(AgentQuoteAutoPickPolicy.manual)
                    Text("cheapest").tag(AgentQuoteAutoPickPolicy.cheapest)
                    Text("fastest").tag(AgentQuoteAutoPickPolicy.fastest)
                    Text("best quality <= budget").tag(AgentQuoteAutoPickPolicy.bestQualityUnderBudget)
                }

                if quoteAutoPickPolicyBinding.wrappedValue == .bestQualityUnderBudget {
                    TextField("Max quote price (0 = unlimited)", text: $quoteBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: quoteBudgetText) { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                viewModel.agentRequesterPreferences.quoteAutoPickBudget = 0
                                return
                            }
                            guard let parsed = UInt64(trimmed) else { return }
                            viewModel.agentRequesterPreferences.quoteAutoPickBudget = min(parsed, 100_000_000)
                        }
                }

                Text("Auto-pick applies as soon as quote collection closes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Preferred Known Models") {
                if knownModels.isEmpty {
                    Text("No known models loaded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownModels) { model in
                        Button {
                            togglePreferred(modelID: model.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: viewModel.agentRequesterPreferences.preferredKnownModelIDs.contains(model.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(viewModel.agentRequesterPreferences.preferredKnownModelIDs.contains(model.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                    Text(model.id)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(model.name))
                    }
                }

                Text(viewModel.agentRequesterPreferences.preferredKnownModelIDs.isEmpty
                     ? "Tip: leave empty to prefer any known model."
                     : "Only selected IDs receive the full preference bonus.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Known Hash List Update") {
                TextField("https://example.com/known_models.json", text: $overlayURLString)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                HStack(spacing: 12) {
                    Button(isUpdating ? "Fetching..." : "Fetch update") {
                        Task { await fetchUpdate() }
                    }
                    .disabled(isUpdating)

                    Button("Reload") {
                        reloadKnownModels()
                        updateStatusText = lastUpdateText()
                    }
                }

                Text(updateStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                Text("Model hash claims are self-attested by providers (identity-bound, not proof of compute).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Routing") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Min quality: \(Int(minQualityBinding.wrappedValue))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Slider(value: minQualityBinding, in: 0...100, step: 1)
                        }

                        Toggle("Prefer known open-source models", isOn: Binding(
                            get: { viewModel.agentRequesterPreferences.preferKnownModels },
                            set: { viewModel.agentRequesterPreferences.preferKnownModels = $0 }
                        ))

                        Toggle("Penalize unknown models", isOn: Binding(
                            get: { viewModel.agentRequesterPreferences.penalizeUnknownModels },
                            set: { viewModel.agentRequesterPreferences.penalizeUnknownModels = $0 }
                        ))

                        Toggle("Enable x402 payments (online only)", isOn: Binding(
                            get: { viewModel.agentRequesterPreferences.allowX402Payments },
                            set: { enabled in
                                viewModel.agentRequesterPreferences.allowX402Payments = enabled
                                if !enabled && viewModel.agentRequesterPreferences.defaultPaymentRail == .x402 {
                                    viewModel.agentRequesterPreferences.defaultPaymentRail = .cashu
                                }
                            }
                        ))

                        Picker("Preferred payment rail", selection: Binding(
                            get: {
                                let preferred = viewModel.agentRequesterPreferences.defaultPaymentRail
                                if preferred == .x402 && !viewModel.agentRequesterPreferences.allowX402Payments {
                                    return AgentPaymentRail.cashu
                                }
                                return preferred
                            },
                            set: { next in
                                if next == .x402 && !viewModel.agentRequesterPreferences.allowX402Payments {
                                    viewModel.agentRequesterPreferences.allowX402Payments = true
                                }
                                viewModel.agentRequesterPreferences.defaultPaymentRail = (next == .none) ? .cashu : next
                            }
                        )) {
                            Text("Cashu (private + offline-capable)").tag(AgentPaymentRail.cashu)
                            Text("x402 (online, less private)").tag(AgentPaymentRail.x402)
                        }
                        .pickerStyle(.menu)

                        Text("Cashu works across BLE mesh and offers stronger privacy. x402 is online-only and uses on-chain/facilitator infrastructure.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Quote Selection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Auto-pick policy", selection: quoteAutoPickPolicyBinding) {
                            Text("manual").tag(AgentQuoteAutoPickPolicy.manual)
                            Text("cheapest").tag(AgentQuoteAutoPickPolicy.cheapest)
                            Text("fastest").tag(AgentQuoteAutoPickPolicy.fastest)
                            Text("best quality <= budget").tag(AgentQuoteAutoPickPolicy.bestQualityUnderBudget)
                        }
                        .pickerStyle(.menu)

                        if quoteAutoPickPolicyBinding.wrappedValue == .bestQualityUnderBudget {
                            TextField("Max quote price (0 = unlimited)", text: $quoteBudgetText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: quoteBudgetText) { value in
                                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else {
                                        viewModel.agentRequesterPreferences.quoteAutoPickBudget = 0
                                        return
                                    }
                                    guard let parsed = UInt64(trimmed) else { return }
                                    viewModel.agentRequesterPreferences.quoteAutoPickBudget = min(parsed, 100_000_000)
                                }
                        }

                        Text("Auto-pick applies as soon as quote collection closes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Preferred Known Models") {
                    VStack(alignment: .leading, spacing: 8) {
                        if knownModels.isEmpty {
                            Text("No known models loaded.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(knownModels) { model in
                                Button {
                                    togglePreferred(modelID: model.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: viewModel.agentRequesterPreferences.preferredKnownModelIDs.contains(model.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(viewModel.agentRequesterPreferences.preferredKnownModelIDs.contains(model.id) ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.name)
                                            Text(model.id)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }

                        Text(viewModel.agentRequesterPreferences.preferredKnownModelIDs.isEmpty
                             ? "Tip: leave empty to prefer any known model."
                             : "Only selected IDs receive the full preference bonus.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Known Hash List Update") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://example.com/known_models.json", text: $overlayURLString)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)

                        HStack(spacing: 12) {
                            Button(isUpdating ? "Fetching..." : "Fetch update") {
                                Task { await fetchUpdate() }
                            }
                            .disabled(isUpdating)

                            Button("Reload") {
                                reloadKnownModels()
                                updateStatusText = lastUpdateText()
                            }
                        }

                        Text(updateStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Notes") {
                    Text("Model hash claims are self-attested by providers (identity-bound, not proof of compute).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        #endif
    }
}

private extension RequesterPreferencesSettingsView {
    func togglePreferred(modelID: String) {
        var next = viewModel.agentRequesterPreferences.preferredKnownModelIDs
        if next.contains(modelID) {
            next.remove(modelID)
        } else {
            next.insert(modelID)
        }
        viewModel.agentRequesterPreferences.preferredKnownModelIDs = next
    }

    func reloadKnownModels() {
        knownModels = viewModel.knownModelCatalog.allModels()
    }

    func lastUpdateText() -> String {
        let meta = viewModel.knownModelUpdateService.storedMetadata()
        let err = viewModel.knownModelUpdateService.storedLastError()
        if let meta {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let dateString = formatter.string(from: meta.fetchedAt)
            let suffix = err.map { " (last error: \($0))" } ?? ""
            return "Last updated: \(dateString) • models: \(meta.modelCount)\(suffix)"
        }
        if let err {
            return "Last update failed: \(err)"
        }
        return "No updates fetched yet."
    }

    func fetchUpdate() async {
        let url = overlayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            updateStatusText = "Enter a URL to fetch."
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        let result = await viewModel.knownModelUpdateService.update(from: url)
        switch result {
        case .success:
            reloadKnownModels()
            updateStatusText = lastUpdateText()
        case .failure(let error):
            updateStatusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
