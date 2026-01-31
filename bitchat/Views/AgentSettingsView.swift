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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    private var agentEnabled: Binding<Bool> {
        Binding(get: { viewModel.agentConfig.enabled }, set: { value in
            updateConfig { $0.enabled = value }
        })
    }

    private var roleBinding: Binding<String> {
        Binding(get: { viewModel.agentConfig.role }, set: { value in updateConfig { $0.role = value } })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { viewModel.agentConfig.modelId }, set: { value in updateConfig { $0.modelId = value } })
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

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Agent Setup")
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(textColor)
            }
            .padding()
            .background(backgroundColor.opacity(0.95))
            ScrollView { content }
                .background(backgroundColor)
        }
        .frame(width: 620, height: 720)
        #else
        NavigationView {
            ScrollView { content }
                .background(backgroundColor)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(textColor)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
        #endif
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
                        Text("Role")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        TextField("general", text: roleBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
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
                    if let catalog = viewModel.agentCatalog, !catalog.models.isEmpty {
                        ForEach(catalog.models) { model in
                            Button(action: {
                                updateConfig { config in
                                    config.modelId = model.id
                                    if let quality = model.qualityScore {
                                        config.qualityScore = quality
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
        }
        .padding()
        .foregroundColor(textColor)
        .background(backgroundColor)
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

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
