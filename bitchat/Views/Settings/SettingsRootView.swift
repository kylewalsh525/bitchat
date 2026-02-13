import SwiftUI

enum SettingsDestination: Hashable {
    case requesterPreferences
    case wallet
    case providerSetup
    case advancedProviderSetup
    case support
    case about
}

struct SettingsRootView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject private var networkActivation = NetworkActivationService.shared

    let initialDestination: SettingsDestination?

    @State private var path: [SettingsDestination] = []
    @State private var showVerificationSheet = false
    @State private var showPanicConfirm = false
    @State private var showDisableProviderConfirm = false

    private var accent: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var nicknameBinding: Binding<String> {
        Binding(
            get: { viewModel.nickname },
            set: { viewModel.nickname = $0 }
        )
    }

    private var torEnabledBinding: Binding<Bool> {
        Binding(
            get: { networkActivation.userTorEnabled },
            set: { networkActivation.setUserTorEnabled($0) }
        )
    }

    init(initialDestination: SettingsDestination? = nil) {
        self.initialDestination = initialDestination
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Profile") {
                    LabeledContent("Nickname") {
                        TextField("nickname", text: nicknameBinding)
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                viewModel.validateAndSaveNickname()
                            }
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    Button("Verify identity") {
                        showVerificationSheet = true
                    }
                }

                Section("Agents") {
                    NavigationLink("Requester preferences", value: SettingsDestination.requesterPreferences)
                    NavigationLink("Wallet", value: SettingsDestination.wallet)
                    if viewModel.agentConfig.enabled {
                        NavigationLink("Provider settings", value: SettingsDestination.providerSetup)
                        Button(role: .destructive) {
                            showDisableProviderConfirm = true
                        } label: {
                            Text("Disable provider mode")
                        }
                    } else {
                        NavigationLink("Enable provider mode", value: SettingsDestination.providerSetup)
                    }
                    NavigationLink("Advanced provider setup", value: SettingsDestination.advancedProviderSetup)
                    .foregroundStyle(.secondary)
                }

                Section("Network & Privacy") {
                    Toggle("Enable Tor + internet relays", isOn: torEnabledBinding)

                    VStack(alignment: .leading, spacing: 6) {
                        let allowed = networkActivation.activationAllowed
                        Text("Internet features: \(allowed ? "available" : "paused")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Availability is gated by location permission or mutual favorites.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showPanicConfirm = true
                    } label: {
                        Text("Panic wipe (delete all data)")
                    }
                }

                Section("Support") {
                    NavigationLink("Export debug bundle", value: SettingsDestination.support)
                }

                Section("About") {
                    NavigationLink("About BitChat", value: SettingsDestination.about)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                destinationView(for: destination)
            }
            .onAppear {
                guard let initialDestination else { return }
                guard path.isEmpty else { return }
                path = [initialDestination]
            }
        }
        .tint(accent)
        .sheet(isPresented: $showVerificationSheet) {
            VerificationSheetView(isPresented: $showVerificationSheet)
                .environmentObject(viewModel)
        }
        .alert("Delete all data?", isPresented: $showPanicConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.panicClearAllData()
            }
        } message: {
            Text("This clears chat history, keys, sessions, wallet proofs, and all local settings.")
        }
        .alert("Disable provider mode?", isPresented: $showDisableProviderConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Disable", role: .destructive) {
                var next = viewModel.agentConfig
                next.enabled = false
                viewModel.updateAgentConfig(next)
                Task { await SupportEventLog.shared.record(category: "provider", message: "provider disabled") }
            }
        } message: {
            Text("This stops advertising as an agent to nearby peers.")
        }
    }

    @ViewBuilder
    private func destinationView(for destination: SettingsDestination) -> some View {
        switch destination {
        case .requesterPreferences:
            RequesterPreferencesSettingsView()
        case .wallet:
            WalletView()
        case .providerSetup:
            ProviderSetupWizardView()
        case .advancedProviderSetup:
            AgentSettingsView()
        case .support:
            SupportExportView()
        case .about:
            AppInfoView()
        }
    }
}
