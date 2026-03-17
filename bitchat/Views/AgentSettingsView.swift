//
// AgentSettingsView.swift
// bitchat
//
// UI for configuring agent runtime + gateway discovery.
//

import SwiftUI
import Foundation

struct AgentSettingsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var memoryQuickNote: String = ""
    @State private var showMemoryWipeConfirm = false

    private var backgroundColor: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(.windowBackgroundColor)
        #endif
    }

    private var textColor: Color {
        .primary
    }

    private var secondaryTextColor: Color {
        .secondary
    }

    private var accentColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var agentEnabled: Binding<Bool> {
        Binding(get: { viewModel.agentConfig.enabled }, set: { value in
            updateConfig { $0.enabled = value }
        })
    }

    private var providerRoleBinding: Binding<AgentProviderRole> {
        Binding(
            get: { AgentProviderRole(normalizing: viewModel.agentConfig.role) },
            set: { role in
                updateConfig { $0.role = role.rawValue }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(get: { viewModel.agentConfig.modelId }, set: { value in updateConfig { $0.modelId = value } })
    }

    private var modelHashBinding: Binding<String> {
        Binding(
            get: { viewModel.agentConfig.modelHash ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                updateConfig { $0.modelHash = trimmed.isEmpty ? nil : trimmed }
            }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { Double(viewModel.agentConfig.qualityScore) }, set: { value in updateConfig { $0.qualityScore = UInt8(max(0, min(100, Int(value)))) } })
    }

    private var runtimeModeBinding: Binding<AgentRuntimeMode> {
        Binding(get: { viewModel.agentConfig.runtime.mode }, set: { value in updateConfig { $0.runtime.mode = value } })
    }

    private var streamBinding: Binding<Bool> {
        Binding(get: { viewModel.agentConfig.runtime.streamResponses }, set: { value in updateConfig { $0.runtime.streamResponses = value } })
    }

    private var timeoutBinding: Binding<UInt32> {
        Binding(get: { viewModel.agentConfig.runtime.timeoutSeconds }, set: { value in updateConfig { $0.runtime.timeoutSeconds = value } })
    }

    private var gatewayPresetBinding: Binding<AgentGatewayPreset> {
        Binding(get: { viewModel.agentConfig.runtime.gatewayPreset }, set: { value in viewModel.applyAgentGatewayPreset(value) })
    }

    private var gatewayURLBinding: Binding<String> {
        Binding(get: { viewModel.agentConfig.runtime.gatewayURL }, set: { value in updateConfig { $0.runtime.gatewayURL = value } })
    }

    private var gatewayTokenBinding: Binding<String> {
        Binding(get: { viewModel.agentConfig.runtime.gatewayToken ?? "" }, set: { value in updateConfig { $0.runtime.gatewayToken = value.isEmpty ? nil : value } })
    }

    private var paymentsEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.sanitized() != nil },
            set: { enabled in
                updateConfig { config in
                    if enabled {
                        config.paymentTerms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                            paymentRail: .cashu,
                            settlementMode: .onlineRequired,
                            unit: "sat",
                            pricePerRequest: 100,
                            acceptedMints: [],
                            requestTTLSeconds: 120
                        )
                    } else {
                        config.paymentTerms = nil
                    }
                }
            }
        )
    }

    private var settlementBinding: Binding<AgentSettlementMode> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.settlementMode ?? .onlineRequired },
            set: { mode in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.settlementMode = mode
                    if mode == .offlineAccepted {
                        terms.requiresLocking = .p2pk
                    } else {
                        terms.requiresLocking = AgentPaymentLockingMode.none
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var lockingBinding: Binding<AgentPaymentLockingMode> {
        Binding(
            get: {
                if let mode = viewModel.agentConfig.paymentTerms?.requiresLocking {
                    return mode
                }
                return settlementBinding.wrappedValue == .offlineAccepted ? .p2pk : .none
            },
            set: { mode in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.requiresLocking = mode
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.unit ?? "sat" },
            set: { value in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.unit = value
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var priceModelBinding: Binding<AgentPaymentPriceModel> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.effectivePriceModel ?? .perRequest },
            set: { value in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = value
                    switch value {
                    case .perRequest:
                        terms.pricePerInputToken = nil
                        terms.pricePerOutputToken = nil
                        terms.minDeposit = nil
                        terms.granularityTokens = nil
                        if terms.pricePerRequest == 0 {
                            terms.pricePerRequest = 100
                        }
                    case .perToken:
                        terms.pricePerRequest = 0
                        if (terms.pricePerInputToken ?? 0) == 0 && (terms.pricePerOutputToken ?? 0) == 0 {
                            terms.pricePerOutputToken = 1
                        }
                        if terms.granularityTokens == nil || terms.granularityTokens == 0 {
                            terms.granularityTokens = 64
                        }
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var requestPriceBinding: Binding<String> {
        Binding(
            get: { String(viewModel.agentConfig.paymentTerms?.pricePerRequest ?? 100) },
            set: { value in
                updateConfig { config in
                    guard let price = UInt64(value), price > 0 else { return }
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = .perRequest
                    terms.pricePerRequest = price
                    terms.pricePerInputToken = nil
                    terms.pricePerOutputToken = nil
                    terms.minDeposit = nil
                    terms.granularityTokens = nil
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var outputTokenPriceBinding: Binding<String> {
        Binding(
            get: { String(viewModel.agentConfig.paymentTerms?.pricePerOutputToken ?? 1) },
            set: { value in
                updateConfig { config in
                    guard let price = UInt64(value), price > 0 else { return }
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = .perToken
                    terms.pricePerRequest = 0
                    terms.pricePerOutputToken = price
                    if terms.granularityTokens == nil || terms.granularityTokens == 0 {
                        terms.granularityTokens = 64
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var inputTokenPriceBinding: Binding<String> {
        Binding(
            get: { String(viewModel.agentConfig.paymentTerms?.pricePerInputToken ?? 0) },
            set: { value in
                updateConfig { config in
                    guard let price = UInt64(value) else { return }
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = .perToken
                    terms.pricePerRequest = 0
                    terms.pricePerInputToken = price > 0 ? price : nil
                    if terms.granularityTokens == nil || terms.granularityTokens == 0 {
                        terms.granularityTokens = 64
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var minDepositBinding: Binding<String> {
        Binding(
            get: { String(viewModel.agentConfig.paymentTerms?.minDeposit ?? 0) },
            set: { value in
                updateConfig { config in
                    guard let deposit = UInt64(value) else { return }
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = .perToken
                    terms.pricePerRequest = 0
                    terms.minDeposit = deposit > 0 ? deposit : nil
                    if terms.granularityTokens == nil || terms.granularityTokens == 0 {
                        terms.granularityTokens = 64
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var granularityBinding: Binding<UInt32> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.granularityTokens ?? 64 },
            set: { value in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.priceModel = .perToken
                    terms.pricePerRequest = 0
                    terms.granularityTokens = max(1, min(4096, value))
                    if (terms.pricePerOutputToken ?? 0) == 0 && (terms.pricePerInputToken ?? 0) == 0 {
                        terms.pricePerOutputToken = 1
                    }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var mintListBinding: Binding<String> {
        Binding(
            get: { (viewModel.agentConfig.paymentTerms?.acceptedMints ?? []).joined(separator: ",") },
            set: { value in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.acceptedMints = value
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var ttlBinding: Binding<UInt32> {
        Binding(
            get: { viewModel.agentConfig.paymentTerms?.requestTTLSeconds ?? 120 },
            set: { value in
                updateConfig { config in
                    var terms = config.paymentTerms?.sanitized() ?? AgentPaymentTerms(
                        paymentRail: .cashu,
                        settlementMode: .onlineRequired,
                        unit: "sat",
                        pricePerRequest: 100,
                        acceptedMints: [],
                        requestTTLSeconds: 120
                    )
                    terms.requestTTLSeconds = max(30, min(600, value))
                    config.paymentTerms = terms
                }
            }
        )
    }

    private var notaryNodeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.agentConfig.notaryPolicy.isNotaryCapable },
            set: { enabled in
                updateConfig { config in
                    config.notaryPolicy.isNotaryCapable = enabled
                }
            }
        )
    }

    private var requiredNotaryReceiptsBinding: Binding<Int> {
        Binding(
            get: { viewModel.agentConfig.notaryPolicy.effectiveRequiredOfflineSignatures },
            set: { value in
                updateConfig { config in
                    let clamped = max(0, min(8, value))
                    config.notaryPolicy.requiredOfflineSignatures = UInt8(clamped)
                }
            }
        )
    }

    private var notaryCollectTimeoutBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.notaryPolicy.effectiveCollectTimeoutMs) },
            set: { value in
                updateConfig { config in
                    let clamped = max(300, min(15_000, value))
                    config.notaryPolicy.collectTimeoutMs = UInt64(clamped)
                }
            }
        )
    }

    private var quoteImmediateDiscountBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.quoteTierPolicy.sanitized().immediateDiscountBps) },
            set: { value in
                updateQuoteTierPolicy { policy in
                    policy.immediateDiscountBps = UInt16(max(0, min(9_500, value)))
                }
            }
        )
    }

    private var quoteStandardWaitBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.quoteTierPolicy.sanitized().standardWaitSeconds) },
            set: { value in
                updateQuoteTierPolicy { policy in
                    policy.standardWaitSeconds = UInt16(max(5, min(300, value)))
                }
            }
        )
    }

    private var quoteStandardDiscountBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.quoteTierPolicy.sanitized().standardDiscountBps) },
            set: { value in
                updateQuoteTierPolicy { policy in
                    policy.standardDiscountBps = UInt16(max(0, min(9_500, value)))
                }
            }
        )
    }

    private var quoteEconomyWaitBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.quoteTierPolicy.sanitized().economyWaitSeconds) },
            set: { value in
                updateQuoteTierPolicy { policy in
                    policy.economyWaitSeconds = UInt16(max(10, min(900, value)))
                }
            }
        )
    }

    private var quoteEconomyDiscountBinding: Binding<Int> {
        Binding(
            get: { Int(viewModel.agentConfig.quoteTierPolicy.sanitized().economyDiscountBps) },
            set: { value in
                updateQuoteTierPolicy { policy in
                    policy.economyDiscountBps = UInt16(max(0, min(9_500, value)))
                }
            }
        )
    }

    private var autoMemoryRecallBinding: Binding<Bool> {
        Binding(
            get: { viewModel.agentMemoryAutoRecallEnabled },
            set: { viewModel.setAgentMemoryAutoRecall(enabled: $0) }
        )
    }

    private var memoryContentBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedAgentMemoryContent },
            set: { viewModel.selectedAgentMemoryContent = $0 }
        )
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(backgroundColor.ignoresSafeArea())
        .navigationTitle("Advanced Provider Setup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(accentColor)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Enable agent", isOn: agentEnabled)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(textColor)

            GroupBox(label: Text("Agent Identity").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Model type")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Picker("Model type", selection: providerRoleBinding) {
                            ForEach(AgentProviderRole.allCases, id: \.self) { role in
                                Text(role.title).tag(role)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quality \(Int(qualityBinding.wrappedValue))")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Slider(value: qualityBinding, in: 0...100, step: 1)
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Model").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("model id", text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                    TextField("model hash (optional)", text: modelHashBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                    if let catalog = viewModel.agentCatalog, !catalog.models.isEmpty {
                        ForEach(catalog.models) { model in
                            Button(action: {
                                updateConfig { config in
                                    config.modelId = model.id
                                    if let quality = model.qualityScore {
                                        config.qualityScore = quality
                                    }
                                    if let modelHash = model.modelHash?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !modelHash.isEmpty {
                                        config.modelHash = modelHash
                                    }
                                }
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.name ?? model.id)
                                            .font(.bitchatSystem(size: 12, design: .monospaced))
                                            .foregroundColor(textColor)
                                        Text([model.provider, model.quant].compactMap { $0 }.joined(separator: " • "))
                                            .font(.bitchatSystem(size: 10, design: .monospaced))
                                            .foregroundColor(secondaryTextColor)
                                    }
                                    Spacer()
                                    if let sizeBytes = model.sizeBytes {
                                        Text(formatBytes(sizeBytes))
                                            .font(.bitchatSystem(size: 10, design: .monospaced))
                                            .foregroundColor(secondaryTextColor)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("Fetch models to see local catalog")
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Runtime").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: runtimeModeBinding) {
                        Text("echo").tag(AgentRuntimeMode.echo)
                        Text("gateway").tag(AgentRuntimeMode.gateway)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Stream responses", isOn: streamBinding)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)

                    Stepper(value: timeoutBinding, in: 5...120, step: 5) {
                        Text("Timeout: \(timeoutBinding.wrappedValue)s")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Gateway").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preset", selection: gatewayPresetBinding) {
                        Text("Ollama (local)").tag(AgentGatewayPreset.localOllama)
                        Text("LM Studio (local)").tag(AgentGatewayPreset.localLMStudio)
                        Text("Custom").tag(AgentGatewayPreset.custom)
                    }
                    .pickerStyle(.segmented)

                    TextField("http://127.0.0.1:8080/agent/run", text: gatewayURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.bitchatSystem(size: 12, design: .monospaced))

                    SecureField("Gateway token (optional)", text: gatewayTokenBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.bitchatSystem(size: 12, design: .monospaced))

                    HStack(spacing: 12) {
                        Button("Test connection") { viewModel.testAgentGatewayHealth() }
                            .buttonStyle(.bordered)
                        Button("Fetch models") { viewModel.fetchAgentCatalog() }
                            .buttonStyle(.bordered)
                    }

                    Text(healthCopy)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)

                    Text(catalogCopy)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)

                    Text("Run your local gateway to bridge Ollama/LM Studio.")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Payments").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Require payment before response", isOn: paymentsEnabledBinding)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)

                    Toggle("Act as notary signer", isOn: notaryNodeBinding)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)

                    if paymentsEnabledBinding.wrappedValue {
                        Picker("Settlement", selection: settlementBinding) {
                            Text("online required").tag(AgentSettlementMode.onlineRequired)
                            Text("offline accepted").tag(AgentSettlementMode.offlineAccepted)
                        }
                        .pickerStyle(.segmented)

                        Picker("Locking", selection: lockingBinding) {
                            Text("p2pk").tag(AgentPaymentLockingMode.p2pk)
                            Text("none").tag(AgentPaymentLockingMode.none)
                        }
                        .pickerStyle(.segmented)

                        if settlementBinding.wrappedValue == .offlineAccepted && lockingBinding.wrappedValue == .none {
                            Text("Unsafe: offline acceptance without p2pk lock increases relay interception/double-spend risk.")
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(.red.opacity(0.9))
                        }

                        Picker("Pricing", selection: priceModelBinding) {
                            Text("per request").tag(AgentPaymentPriceModel.perRequest)
                            Text("per token").tag(AgentPaymentPriceModel.perToken)
                        }
                        .pickerStyle(.segmented)

                        TextField("unit (sat/usd/usdc)", text: unitBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.bitchatSystem(size: 12, design: .monospaced))

                        if priceModelBinding.wrappedValue == .perRequest {
                            TextField("price per request", text: requestPriceBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.bitchatSystem(size: 12, design: .monospaced))

                            Text("Quote tiers")
                                .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)

                            Stepper(value: quoteImmediateDiscountBinding, in: 0...9_500, step: 100) {
                                Text("Immediate discount: \(quoteImmediateDiscountBinding.wrappedValue / 100)%")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }

                            Stepper(value: quoteStandardWaitBinding, in: 5...300, step: 5) {
                                Text("Standard wait: ~\(quoteStandardWaitBinding.wrappedValue)s")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }

                            Stepper(value: quoteStandardDiscountBinding, in: 0...9_500, step: 100) {
                                Text("Standard discount: \(quoteStandardDiscountBinding.wrappedValue / 100)%")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }

                            Stepper(value: quoteEconomyWaitBinding, in: 10...900, step: 10) {
                                Text("Economy wait: ~\(quoteEconomyWaitBinding.wrappedValue)s")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }

                            Stepper(value: quoteEconomyDiscountBinding, in: 0...9_500, step: 100) {
                                Text("Economy discount: \(quoteEconomyDiscountBinding.wrappedValue / 100)%")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                        } else {
                            TextField("price per output token", text: outputTokenPriceBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.bitchatSystem(size: 12, design: .monospaced))

                            TextField("price per input token (optional)", text: inputTokenPriceBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.bitchatSystem(size: 12, design: .monospaced))

                            TextField("minimum first-tranche deposit (optional)", text: minDepositBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.bitchatSystem(size: 12, design: .monospaced))

                            Stepper(value: granularityBinding, in: 1...4096, step: 8) {
                                Text("Tranche token granularity: \(granularityBinding.wrappedValue)")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                        }

                        TextField("accepted mints (comma-separated URLs)", text: mintListBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.bitchatSystem(size: 12, design: .monospaced))

                        Stepper(value: ttlBinding, in: 30...600, step: 15) {
                            Text("Request TTL: \(ttlBinding.wrappedValue)s")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }

                        if settlementBinding.wrappedValue == .offlineAccepted {
                            Stepper(value: requiredNotaryReceiptsBinding, in: 0...8, step: 1) {
                                Text("Offline notary receipts required: \(requiredNotaryReceiptsBinding.wrappedValue)")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }

                            Stepper(value: notaryCollectTimeoutBinding, in: 300...15_000, step: 100) {
                                Text("Notary collect timeout: \(notaryCollectTimeoutBinding.wrappedValue) ms")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Memory").font(.bitchatSystem(size: 12, design: .monospaced))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Auto-recall relevant memory", isOn: autoMemoryRecallBinding)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(textColor)

                    Text("Memory snippets are local-only and prepended to outgoing agent prompts.")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)

                    HStack(spacing: 12) {
                        Button("Refresh") { viewModel.refreshAgentMemoryEntries() }
                            .buttonStyle(.bordered)
                        Button("Today log") {
                            _ = viewModel.ensureTodayMemoryEntrySelected()
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(viewModel.agentMemoryEntries) { entry in
                        HStack {
                            Button(action: {
                                viewModel.selectAgentMemoryEntry(entry.id)
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.bitchatSystem(size: 12, design: .monospaced))
                                        .foregroundColor(textColor)
                                    Text(viewModel.memoryEntryLabel(for: entry))
                                        .font(.bitchatSystem(size: 10, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                }
                                Spacer()
                            }
                            .buttonStyle(.plain)

                            Button(viewModel.isAgentMemoryEntryAttached(entry.id) ? "Detach" : "Attach") {
                                viewModel.toggleAttachedAgentMemoryEntry(entryID: entry.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 3)
                    }

                    if viewModel.selectedAgentMemoryEntryID != nil {
                        TextEditor(text: memoryContentBinding)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .frame(minHeight: 150)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        HStack(spacing: 12) {
                            Button("Save memory file") {
                                _ = viewModel.saveSelectedAgentMemoryEntry()
                            }
                            .buttonStyle(.borderedProminent)

                            if let lastSavedAt = viewModel.agentMemoryLastSavedAt {
                                Text("saved \(relativeTime(lastSavedAt))")
                                    .font(.bitchatSystem(size: 10, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Quick daily note", text: $memoryQuickNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                        Button("Append") {
                            _ = viewModel.appendAgentDailyMemoryNote(memoryQuickNote)
                            memoryQuickNote = ""
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Wipe memory + sessions") {
                        showMemoryWipeConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .foregroundColor(.red)
                }
                .padding(.vertical, 6)
            }
        }
        .padding()
        .foregroundColor(textColor)
        .background(backgroundColor)
        .onAppear {
            viewModel.refreshAgentMemoryEntries()
            if viewModel.selectedAgentMemoryEntryID == nil,
               let first = viewModel.agentMemoryEntries.first {
                viewModel.selectAgentMemoryEntry(first.id)
            }
        }
        .alert("Wipe memory and sessions?", isPresented: $showMemoryWipeConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Wipe", role: .destructive) {
                viewModel.wipeAgentMemoryAndSessions()
            }
        } message: {
            Text("This deletes MEMORY.md, daily logs, and all saved agent sessions on this device.")
        }
    }

    private var healthCopy: String {
        switch viewModel.agentGatewayHealth {
        case .idle:
            return "Gateway status: idle"
        case .checking:
            return "Gateway status: checking…"
        case .ok:
            return "Gateway status: connected"
        case .failed(let message):
            return "Gateway status: \(message)"
        }
    }

    private var catalogCopy: String {
        switch viewModel.agentCatalogStatus {
        case .idle:
            return "Catalog status: idle"
        case .loading:
            return "Catalog status: fetching…"
        case .loaded:
            let count = viewModel.agentCatalog?.models.count ?? 0
            return "Catalog status: \(count) models"
        case .failed(let message):
            return "Catalog status: \(message)"
        }
    }

    private func updateConfig(_ mutate: (inout AgentConfig) -> Void) {
        var next = viewModel.agentConfig
        mutate(&next)
        viewModel.updateAgentConfig(next)
    }

    private func updateQuoteTierPolicy(_ mutate: (inout AgentQuoteTierPolicy) -> Void) {
        updateConfig { config in
            var policy = config.quoteTierPolicy.sanitized()
            mutate(&policy)
            config.quoteTierPolicy = policy.sanitized()
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
