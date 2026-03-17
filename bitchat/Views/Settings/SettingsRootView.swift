import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SettingsDestination: Hashable {
    case requesterPreferences
    case wallet
    case providerSetup
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
            List {
                Section("Profile") {
                    LabeledContent {
                        TextField("nickname", text: nicknameBinding)
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { viewModel.validateAndSaveNickname() }
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    } label: {
                        SettingsIconRow(
                            icon: "person",
                            title: "Nickname",
                            subtitle: "Shown to nearby peers on this device."
                        )
                    }
                    Button {
                        showVerificationSheet = true
                    } label: {
                        SettingsIconRow(
                            icon: "person.crop.circle.badge.checkmark",
                            title: "Verify identity",
                            subtitle: "Compare fingerprints to confirm who you are chatting with."
                        )
                    }
                }

                Section("Agents & Payments") {
                    NavigationLink(value: SettingsDestination.requesterPreferences) {
                        SettingsIconRow(
                            icon: "slider.horizontal.3",
                            title: "Requester preferences",
                            subtitle: "Routing quality, quote behavior, and payment rail preference."
                        )
                    }
                    NavigationLink(value: SettingsDestination.wallet) {
                        SettingsIconRow(
                            icon: "wallet.pass",
                            title: "Wallet setup",
                            subtitle: "Import Cashu, approve mints, and configure x402."
                        )
                    }
                    if viewModel.agentConfig.enabled {
                        NavigationLink(value: SettingsDestination.providerSetup) {
                            SettingsIconRow(
                                icon: "dot.radiowaves.left.and.right",
                                title: "Provider setup",
                                subtitle: "Wizard for runtime, model, and payment defaults."
                            )
                        }
                        Button(role: .destructive) {
                            showDisableProviderConfirm = true
                        } label: {
                            SettingsIconRow(
                                icon: "xmark.circle",
                                title: "Disable provider mode",
                                subtitle: "Stop advertising as an agent."
                            )
                        }
                    } else {
                        NavigationLink(value: SettingsDestination.providerSetup) {
                            SettingsIconRow(
                                icon: "plus.circle",
                                title: "Enable provider mode",
                                subtitle: "Guide setup for provider runtime and payments."
                            )
                        }
                    }
                }

                Section("Network & Privacy") {
                    Toggle(isOn: torEnabledBinding) {
                        SettingsIconRow(
                            icon: "shield.lefthalf.filled",
                            title: "Enable Tor + internet relays",
                            subtitle: "Allow internet relay transport when policy permits."
                        )
                    }
                    let allowed = networkActivation.activationAllowed
                    SettingsIconRow(
                        icon: allowed ? "checkmark.circle" : "pause.circle",
                        title: "Internet features \(allowed ? "available" : "paused")",
                        subtitle: "Availability follows your privacy activation policy."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    SettingsIconRow(
                        icon: "network",
                        title: "Internet policy",
                        subtitle: "Usage unlocks from location permission or mutual favorites."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showPanicConfirm = true
                    } label: {
                        SettingsIconRow(
                            icon: "trash",
                            title: "Panic wipe (delete all data)",
                            subtitle: "Remove chats, keys, sessions, wallet data, and settings."
                        )
                    }
                }

                Section("Support") {
                    NavigationLink(value: SettingsDestination.support) {
                        SettingsIconRow(
                            icon: "square.and.arrow.up",
                            title: "Export debug bundle",
                            subtitle: "Create a redacted support package."
                        )
                    }
                }

                Section("About") {
                    NavigationLink(value: SettingsDestination.about) {
                        SettingsIconRow(
                            icon: "info.circle",
                            title: "About BitChat",
                            subtitle: "Core features, privacy model, and quick-start help."
                        )
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { destination in
            destinationView(for: destination)
        }
        .toolbar {
            if path.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        path.removeAll()
                        dismiss()
                    }
                }
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .support:
            SupportExportView()
        case .about:
            AppInfoView()
        }
    }
}

struct SettingsIconRow<Accessory: View>: View {
    let icon: String
    let title: Text
    let subtitle: Text?
    @ViewBuilder let accessory: () -> Accessory

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.icon = icon
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory
    }

    init(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.icon = icon
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SafeSystemImage(name: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                title
                    .foregroundStyle(.primary)
                if let subtitle {
                    subtitle
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            accessory()
        }
    }
}

private struct SafeSystemImage: View {
    let name: String

    var body: some View {
        #if os(iOS)
        if UIImage(systemName: name) != nil {
            Image(systemName: name)
        } else {
            Image(systemName: "questionmark.circle")
        }
        #elseif os(macOS)
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            Image(systemName: name)
        } else {
            Image(systemName: "questionmark.circle")
        }
        #else
        Image(systemName: name)
        #endif
    }
}
