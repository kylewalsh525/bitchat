import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var store: OnboardingStateStore

    var onTryAgentDemo: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onLearnMore: (() -> Void)? = nil
    var onOpenWallet: (() -> Void)? = nil

    @State private var step: Step = .welcome
    @State private var showWalletSheet: Bool = false

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

    private enum Step: Int, CaseIterable {
        case welcome
        case nickname
        case permissions
        case agents
        case payments
        case wallet
        case finish

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .nickname: return "Pick a nickname"
            case .permissions: return "Permissions"
            case .agents: return "Agents (Optional)"
            case .payments: return "Payment Preference"
            case .wallet: return "Wallet (Optional)"
            case .finish: return "All set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "Private mesh chat, DMs, and optional paid agents."
            case .nickname:
                return "Choose the name peers nearby will see."
            case .permissions:
                return "Bluetooth is required. Everything else is optional."
            case .agents:
                return "Request work from nearby providers when available."
            case .payments:
                return "Choose your default payment behavior."
            case .wallet:
                return "Import Cashu ecash now or set it up later."
            case .finish:
                return "You can change any setting later."
            }
        }
    }

    var body: some View {
        NavigationStack {
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
            .background(surfaceBackground)
            .tint(accent)
        }
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showWalletSheet) {
            NavigationStack {
                WalletView()
                    .environmentObject(viewModel)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                    .minimumScaleFactor(0.85)
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(
                    value: Double(step.rawValue + 1),
                    total: Double(Step.allCases.count)
                )
                .tint(accent)
                .accessibilityLabel("Onboarding progress")
            }
            Spacer()
            Button("Skip") {
                store.markCompleted()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                bullet("antenna.radiowaves.left.and.right", "Works over nearby Bluetooth mesh, even offline.")
                bullet("lock.shield", "Private chats are encrypted. Verify fingerprints when needed.")
                bullet("cpu", "Agents are peers advertising capability; there is no central account.")
                infoCallout(
                    icon: "gearshape",
                    title: "Tip",
                    text: "Use the gear button for settings, wallet, and provider setup."
                )
            }
        case .nickname:
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick something short. You can change it later.")
                    .foregroundStyle(.secondary)
                TextField("nickname", text: Binding(
                    get: { viewModel.nickname },
                    set: { viewModel.nickname = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                infoCallout(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Identity note",
                    text: "Nicknames are local, not global accounts. Use fingerprints to verify a peer."
                )
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 14) {
                bullet("bluetooth", "Bluetooth is required for mesh discovery and messaging.")
                bullet("bell", "Notifications help you notice DMs and mentions.")
                bullet("location", "Location is optional; it enables geohash channels and internet relay policy.")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        #if os(iOS)
                        Button("Enable notifications") {
                            NotificationService.shared.requestAuthorization()
                        }
                        .buttonStyle(.bordered)
                        #endif

                        Button("Enable location channels") {
                            LocationChannelManager.shared.enableLocationChannels()
                            LocationChannelManager.shared.refreshChannels()
                        }
                        .buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        #if os(iOS)
                        Button("Enable notifications") {
                            NotificationService.shared.requestAuthorization()
                        }
                        .buttonStyle(.bordered)
                        #endif
                        Button("Enable location channels") {
                            LocationChannelManager.shared.enableLocationChannels()
                            LocationChannelManager.shared.refreshChannels()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("You can continue without enabling everything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .agents:
            VStack(alignment: .leading, spacing: 14) {
                Text("Send an agent request with:")
                    .foregroundStyle(.secondary)
                codeBlock("/agent general hello")
                infoCallout(
                    icon: "list.bullet.rectangle",
                    title: "Quote flow",
                    text: "If quotes appear, tap one option or use `/agentchoose`."
                )
                infoCallout(
                    icon: "info.circle",
                    title: "Model identity",
                    text: "`modelHash` is self-attested and identity-bound. It is not proof of compute."
                )
            }
        case .payments:
            VStack(alignment: .leading, spacing: 14) {
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
                        viewModel.agentRequesterPreferences.defaultPaymentRail = next == .none ? .cashu : next
                    }
                )) {
                    Text("Cashu (default)").tag(AgentPaymentRail.cashu)
                    Text("x402").tag(AgentPaymentRail.x402)
                }

                infoCallout(
                    icon: "shield.lefthalf.filled",
                    title: "Cashu",
                    text: "More private and works over offline BLE mesh."
                )
                infoCallout(
                    icon: "globe",
                    title: "x402",
                    text: "Online only, on-chain payments via facilitator-backed infrastructure."
                )
            }
        case .wallet:
            VStack(alignment: .leading, spacing: 14) {
                Text("Import Cashu ecash now or set up later from Settings > Wallet.")
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button("Open wallet") {
                            showWalletSheet = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Skip for now") {
                            goNext()
                        }
                        .buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Open wallet") {
                            showWalletSheet = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Skip for now") {
                            goNext()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                infoCallout(
                    icon: "shield",
                    title: "Safety",
                    text: "Unknown mints require explicit approval before import or payment."
                )
            }
        case .finish:
            VStack(alignment: .leading, spacing: 14) {
                bullet("gearshape", "Settings: agents, wallet, privacy, and support tools.")
                bullet("shield.lefthalf.filled", "Offline payments are risk-managed; locking + notaries + settlement gossip reduce risk.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button("Try an agent demo") {
                            store.markCompleted()
                            onTryAgentDemo?()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open settings") {
                            store.markCompleted()
                            onOpenSettings?()
                        }
                        .buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Try an agent demo") {
                            store.markCompleted()
                            onTryAgentDemo?()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open settings") {
                            store.markCompleted()
                            onOpenSettings?()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Button("Learn more") {
                    store.markCompleted()
                    onLearnMore?()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                goBack()
            }
            .buttonStyle(.bordered)
            .disabled(step == .welcome)

            Spacer()

            Button(step == .finish ? "Done" : "Continue") {
                if step == .nickname {
                    viewModel.validateAndSaveNickname()
                }
                if step == .finish {
                    store.markCompleted()
                } else {
                    goNext()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func goNext() {
        guard let currentIndex = Step.allCases.firstIndex(of: step) else { return }
        let nextIndex = Step.allCases.index(after: currentIndex)
        if nextIndex < Step.allCases.endIndex {
            step = Step.allCases[nextIndex]
        }
    }

    private func goBack() {
        guard let currentIndex = Step.allCases.firstIndex(of: step),
              currentIndex > Step.allCases.startIndex else { return }
        step = Step.allCases[Step.allCases.index(before: currentIndex)]
    }

    private func bullet(_ systemName: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemName)
                .foregroundStyle(accent)
        }
        .font(.body)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.10))
            )
            .accessibilityLabel(text)
    }

    private func infoCallout(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.10))
        )
    }
}
