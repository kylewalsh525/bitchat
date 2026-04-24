//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import BitLogger
import BitFoundation

/// On macOS 14+, disables the default system focus ring on TextFields.
/// On earlier macOS versions and on iOS this is a no-op.
private struct FocusEffectDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private enum SidebarTab: String {
    case people
    case sessions
}

// MARK: - Main Content View

struct ContentView: View {
    // MARK: - Properties
    
    @EnvironmentObject var viewModel: ChatViewModel
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @ObservedObject private var locationManager = LocationChannelManager.shared
    @ObservedObject private var bookmarks = GeohashBookmarksStore.shared
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSidebar = false
    @State private var sidebarTab: SidebarTab = .people
    @State private var showAppInfo = false
    @State private var showSettings = false
    @State private var settingsDestination: SettingsDestination? = nil
    @StateObject private var onboardingStore = OnboardingStateStore()
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var isAtBottomPublic: Bool = true
    @State private var isAtBottomPrivate: Bool = true
    @State private var autocompleteDebounceTimer: Timer?
    @State private var showLocationChannelsSheet = false
    @State private var showVerifySheet = false
    @State private var showLocationNotes = false
    @State private var notesGeohash: String? = nil
    @State private var imagePreviewURL: URL? = nil
    @State private var exportMediaURL: URL? = nil
    @State private var expandedMessageIDs: Set<String> = []
#if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
#else
    @State private var showMacImagePicker = false
#endif
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerCountFontSize: CGFloat = 12
    // Timer-based refresh removed; use LocationChannelManager live updates instead
    // Window sizes for rendering (infinite scroll up)
    @State private var windowCountPublic: Int = 300
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    
    // MARK: - Computed Properties
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    private var headerLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    private var peopleSheetTitle: String {
        switch sidebarTab {
        case .people:
            return String(localized: "content.header.people", comment: "Title for the people list sheet").lowercased()
        case .sessions:
            return "sessions"
        }
    }

    private var peopleSheetSubtitle: String? {
        guard sidebarTab == .people else { return nil }
        switch locationManager.selectedChannel {
        case .mesh:
            return "#mesh"
        case .location(let channel):
            return "#\(channel.geohash.lowercased())"
        }
    }

    private var peopleSheetActiveCount: Int {
        if sidebarTab == .sessions {
            return viewModel.agentSessionHistory.count
        }
        switch locationManager.selectedChannel {
        case .mesh:
            return viewModel.allPeers.filter { $0.peerID != viewModel.meshService.myPeerID }.count
        case .location:
            return viewModel.visibleGeohashPeople().count
        }
    }

    private var sidebarCountText: String {
        if sidebarTab == .sessions {
            return "\(peopleSheetActiveCount) sessions"
        }
        return String.localizedStringWithFormat(
            String(localized: "%@ active", comment: "Count of active users in the people sheet"),
            "\(peopleSheetActiveCount)"
        )
    }
    
    
    private struct PrivateHeaderContext {
        let headerPeerID: PeerID
        let peer: BitchatPeer?
        let displayName: String
        let isNostrAvailable: Bool
    }

// MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            mainHeaderView
                .onAppear {
                    viewModel.currentColorScheme = colorScheme
                    #if os(macOS)
                    // Focus message input on macOS launch, not nickname field
                    DispatchQueue.main.async {
                        isNicknameFieldFocused = false
                        isTextFieldFocused = true
                    }
                    #endif
                }
                .onChange(of: colorScheme) { newValue in
                    viewModel.currentColorScheme = newValue
                }

            Divider()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    MessageListView(
                        privatePeer: nil,
                        isAtBottom: $isAtBottomPublic,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        exportMediaURL: $exportMediaURL,
                        expandedMessageIDs: $expandedMessageIDs,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        showSidebar: $showSidebar,
                        isTextFieldFocused: $isTextFieldFocused
                    )
                    .background(backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Divider()

            if viewModel.selectedPrivateChatPeer == nil {
                inputView
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: viewModel.selectedPrivateChatPeer) { newValue in
            if newValue != nil {
                showSidebar = true
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showSidebar || viewModel.selectedPrivateChatPeer != nil },
                set: { isPresented in
                    if !isPresented {
                        showSidebar = false
                        viewModel.endPrivateChat()
                    }
                }
            )
        ) {
            peopleSheetView
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAppInfo) {
            NavigationStack {
                AppInfoView(onOpenSettings: {
                    showAppInfo = false
                    openSettings()
                })
                    .environmentObject(viewModel)
                    .onAppear { viewModel.isAppInfoPresented = true }
                    .onDisappear { viewModel.isAppInfoPresented = false }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showSettings, onDismiss: {
            settingsDestination = nil
        }) {
            SettingsRootView(initialDestination: settingsDestination)
                .environmentObject(viewModel)
                .ignoresSafeArea(.keyboard)
        }
        #else
        .sheet(isPresented: $showSettings, onDismiss: {
            settingsDestination = nil
        }) {
            SettingsRootView(initialDestination: settingsDestination)
                .environmentObject(viewModel)
                .frame(minWidth: 760, minHeight: 620)
        }
        #endif
        .sheet(isPresented: Binding(
            get: { viewModel.showingFingerprintFor != nil && !showSidebar && viewModel.selectedPrivateChatPeer == nil },
            set: { _ in viewModel.showingFingerprintFor = nil }
        )) {
            if let peerID = viewModel.showingFingerprintFor {
                FingerprintView(viewModel: viewModel, peerID: peerID)
                    .environmentObject(viewModel)
            }
        }
#if os(iOS)
        // Only present image picker from main view when NOT in a sheet
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && !showSidebar && viewModel.selectedPrivateChatPeer == nil },
            set: { newValue in
                if !newValue {
                    showImagePicker = false
                }
            }
        )) {
            ImagePickerView(sourceType: imagePickerSourceType) { image in
                showImagePicker = false
                queuePickedImage(image)
            }
            .environmentObject(viewModel)
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: Binding(
            get: { !onboardingStore.isCompleted },
            set: { _ in }
        )) {
            OnboardingFlowView(
                store: onboardingStore,
                onTryAgentDemo: {
                    messageText = "/agent general hello"
                    isTextFieldFocused = true
                },
                onOpenSettings: {
                    openSettings()
                },
                onLearnMore: {
                    showAppInfo = true
                },
                onOpenWallet: {
                    openSettings(destination: .wallet)
                }
            )
            .environmentObject(viewModel)
        }
#endif
#if os(macOS)
        // Only present Mac image picker from main view when NOT in a sheet
        .sheet(isPresented: Binding(
            get: { showMacImagePicker && !showSidebar && viewModel.selectedPrivateChatPeer == nil },
            set: { newValue in
                if !newValue {
                    showMacImagePicker = false
                }
            }
        )) {
            MacImagePickerView { url in
                showMacImagePicker = false
                queuePickedImage(url: url)
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: Binding(
            get: { !onboardingStore.isCompleted },
            set: { _ in }
        )) {
            OnboardingFlowView(
                store: onboardingStore,
                onTryAgentDemo: {
                    messageText = "/agent general hello"
                    isTextFieldFocused = true
                },
                onOpenSettings: {
                    openSettings()
                },
                onLearnMore: {
                    showAppInfo = true
                },
                onOpenWallet: {
                    openSettings(destination: .wallet)
                }
            )
            .environmentObject(viewModel)
            .frame(minWidth: 720, minHeight: 520)
        }
#endif
        .sheet(isPresented: Binding(
            get: { imagePreviewURL != nil },
            set: { presenting in if !presenting { imagePreviewURL = nil } }
        )) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
                    .environmentObject(viewModel)
            }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { exportMediaURL != nil },
            set: { presenting in
                if !presenting { exportMediaURL = nil }
            }
        )) {
            if let url = exportMediaURL {
                MediaFileExportWrapper(url: url)
            }
        }
        #endif
        .alert("Recording Error", isPresented: $voiceRecordingVM.showAlert, actions: {
            Button("common.ok", role: .cancel) {}
            if voiceRecordingVM.state == .permissionDenied {
                Button("location_channels.action.open_settings") {
                    SystemSettings.microphone.open()
                }
            }
        }, message: {
            Text(voiceRecordingVM.state.alertMessage)
        })
        .alert("content.alert.bluetooth_required.title", isPresented: $viewModel.showBluetoothAlert) {
            Button("content.alert.bluetooth_required.settings") {
                SystemSettings.bluetooth.open()
            }
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(viewModel.bluetoothAlertMessage)
        }
        .onChange(of: viewModel.isWalletPresented) { isPresented in
            guard isPresented else { return }
            openSettings(destination: .wallet)
            viewModel.isWalletPresented = false
        }
        .onDisappear {
            autocompleteDebounceTimer?.invalidate()
        }
    }
    
    // MARK: - Input View

    @ViewBuilder
    private var inputView: some View {
        let isReadOnly = viewModel.isAgentSessionReadOnly
        let draftAttachments = viewModel.draftAttachments(for: viewModel.selectedPrivateChatPeer)

        VStack(alignment: .leading, spacing: 6) {
            // @mentions autocomplete
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.autocompleteSuggestions.prefix(4)), id: \.self) { suggestion in
                        Button(action: {
                            _ = viewModel.completeNickname(suggestion, in: &messageText)
                        }) {
                            HStack {
                                Text(suggestion)
                                    .font(.bitchatSystem(size: 11, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .background(Color.gray.opacity(0.1))
                    }
                }
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }

            CommandSuggestionsView(
                messageText: $messageText,
                textColor: textColor,
                backgroundColor: backgroundColor,
                secondaryTextColor: secondaryTextColor
            )

            if voiceRecordingVM.state.isActive {
                recordingIndicator
            }

            if !isReadOnly && !draftAttachments.isEmpty {
                draftAttachmentStrip(draftAttachments)
                    .padding(.horizontal, 6)
            }

            if !viewModel.activeAgentQuoteSelections.isEmpty {
                agentQuoteSelectionStrip
                    .padding(.horizontal, 6)
            }

            if let pendingStatus = viewModel.pendingAgentStatusText(for: viewModel.selectedPrivateChatPeer) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pendingStatus)
                        .font(.bitchatSystem(size: 12, design: .rounded))
                        .foregroundColor(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.gray.opacity(colorScheme == .dark ? 0.18 : 0.12))
                )
                .padding(.horizontal, 6)
            }

            HStack(alignment: .center, spacing: 4) {
                TextField(
                    "",
                    text: $messageText,
                    prompt: Text(
                        isReadOnly
                        ? "Agent DM is read-only"
                        : String(localized: "content.input.message_placeholder", comment: "Placeholder shown in the chat composer")
                    )
                    .foregroundColor(secondaryTextColor.opacity(0.6))
                )
                .textFieldStyle(.plain)
                .font(.bitchatSystem(size: 15, design: .monospaced))
                .foregroundColor(textColor)
                .focused($isTextFieldFocused)
                .autocorrectionDisabled(true)
#if os(iOS)
                .textInputAutocapitalization(.sentences)
#endif
                .submitLabel(.send)
                .onSubmit { sendMessage() }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.7))
                )
                .modifier(FocusEffectDisabledModifier())
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: messageText) { newValue in
                    autocompleteDebounceTimer?.invalidate()
                    autocompleteDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak viewModel] _ in
                        let cursorPosition = newValue.count
                        Task { @MainActor in
                            viewModel?.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                        }
                    }
                }
                .disabled(isReadOnly)

                HStack(alignment: .center, spacing: 4) {
                    if shouldShowMediaControls {
                        attachmentButton
                    }

                    sendOrMicButton
                }
                .disabled(isReadOnly)
                .opacity(isReadOnly ? 0.6 : 1.0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(backgroundColor.opacity(0.95))
    }

    @ViewBuilder
    private func draftAttachmentStrip(_ attachments: [ChatViewModel.DraftAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    DraftAttachmentThumbnailView(
                        attachment: attachment,
                        onRemove: {
                            viewModel.removeDraftAttachment(at: index, for: viewModel.selectedPrivateChatPeer)
                        },
                        onPreview: {
                            imagePreviewURL = attachment.url
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 72)
    }

    @ViewBuilder
    private var agentQuoteSelectionStrip: some View {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let activeSelections = Array(viewModel.activeAgentQuoteSelections.prefix(2))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(activeSelections, id: \.quoteID) { selection in
                agentQuoteSelectionCard(selection, nowMs: nowMs)
            }
        }
    }

    private func agentQuoteSelectionCard(
        _ selection: ChatViewModel.AgentQuoteSelectionSummary,
        nowMs: UInt64
    ) -> some View {
        let remainingMs = selection.expiresAtMs > nowMs ? (selection.expiresAtMs - nowMs) : 0
        let expiresIn = max(0, Int(remainingMs / 1_000))
        let headerText = "Quotes for '\(selection.role)' - \(selection.quoteID.prefix(8)) - \(expiresIn)s left"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(headerText)
                    .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Dismiss") {
                    viewModel.dismissPendingAgentQuote(quoteID: selection.quoteID)
                }
                .buttonStyle(.borderless)
                .font(.bitchatSystem(size: 10, design: .monospaced))
                .foregroundColor(secondaryTextColor)
            }

            if selection.options.isEmpty {
                Text("No quotes yet. Waiting for providers...")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            } else {
                ForEach(Array(selection.options.enumerated()), id: \.offset) { index, option in
                    agentQuoteSelectionOption(selection: selection, index: index, option: option)
                }
            }

            Text("/agentchoose \(selection.quoteID) <1-\(selection.options.count)>")
                .font(.bitchatSystem(size: 10, design: .monospaced))
                .foregroundColor(secondaryTextColor)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.04))
        )
    }

    private func agentQuoteSelectionOption(
        selection: ChatViewModel.AgentQuoteSelectionSummary,
        index: Int,
        option: ChatViewModel.AgentQuoteSelectionOption
    ) -> some View {
        let waitLabel = option.waitSeconds == 0 ? "now" : "wait ~\(option.waitSeconds)s"
        let optionText = "\(option.peerNickname) q\(option.qualityScore) \(waitLabel) \(option.estimatedPrice) \(option.unit)"

        return Button {
            let result = viewModel.selectAgentQuoteOptionFromUI(
                quoteID: selection.quoteID,
                optionID: option.optionID
            )
            applyQuoteSelectionResult(result)
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.bitchatSystem(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                    .frame(width: 14)
                Text(optionText)
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose quote option \(index + 1)")
        .accessibilityHint("Selects \(option.peerNickname) at \(option.estimatedPrice) \(option.unit)")
    }

    private func applyQuoteSelectionResult(_ result: CommandResult) {
        switch result {
        case .success(let message):
            if let message {
                viewModel.addSystemMessage(message)
            }
        case .error(let message):
            viewModel.addSystemMessage(message)
        case .handled:
            break
        }
    }

    private func openSettings(destination: SettingsDestination? = nil) {
        settingsDestination = destination
        showSettings = true
    }

    // MARK: - Actions

    private var trimmedMessageText: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func sendMessage() {
        if viewModel.isAgentSessionReadOnly {
            return
        }
        let trimmed = trimmedMessageText
        guard !trimmed.isEmpty else { return }

        // Clear input immediately for instant feedback
        messageText = ""

        // Defer actual send to next runloop to avoid blocking
        DispatchQueue.main.async {
            self.viewModel.sendMessage(trimmed)
        }
    }
    
    // MARK: - Sheet Content
    
    private var peopleSheetView: some View {
        NavigationStack {
            Group {
                if viewModel.selectedPrivateChatPeer != nil {
                    privateChatSheetView
                } else {
                    peopleListSheetView
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { viewModel.showingFingerprintFor != nil && (showSidebar || viewModel.selectedPrivateChatPeer != nil) },
                set: { isPresented in
                    if !isPresented {
                        viewModel.showingFingerprintFor = nil
                    }
                }
            )) {
                if let peerID = viewModel.showingFingerprintFor {
                    FingerprintView(viewModel: viewModel, peerID: peerID)
                        .environmentObject(viewModel)
                }
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        // Present image picker from sheet context when IN a sheet (parent-child pattern)
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && (showSidebar || viewModel.selectedPrivateChatPeer != nil) },
            set: { newValue in
                if !newValue {
                    showImagePicker = false
                }
            }
        )) {
            ImagePickerView(sourceType: imagePickerSourceType) { image in
                showImagePicker = false
                queuePickedImage(image)
            }
            .environmentObject(viewModel)
            .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showMacImagePicker) {
            MacImagePickerView { url in
                showMacImagePicker = false
                queuePickedImage(url: url)
            }
            .environmentObject(viewModel)
        }
        #endif
    }
    
    // MARK: - People Sheet Views
    
    private var peopleListSheetView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .font(.bitchatSystem(size: 18, design: .monospaced))
                        .foregroundColor(textColor)
                    Spacer()
                    if sidebarTab == .people, case .mesh = locationManager.selectedChannel {
                        Button(action: { showVerifySheet = true }) {
                            Image(systemName: "qrcode")
                                .font(.bitchatSystem(size: 14))
                        }
                        .buttonStyle(.plain)
                        .help(
                            String(localized: "content.help.verification", comment: "Help text for verification button")
                        )
                    }
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            dismiss()
                            showSidebar = false
                            showVerifySheet = false
                            viewModel.endPrivateChat()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                Picker("", selection: $sidebarTab) {
                    Text("people").tag(SidebarTab.people)
                    Text("sessions").tag(SidebarTab.sessions)
                }
                .pickerStyle(.segmented)

                if sidebarTab == .sessions {
                    Text("Resumes start a brand-new, private agent chat with your history.")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else if let subtitle = peopleSheetSubtitle {
                    let subtitleColor: Color = {
                        switch locationManager.selectedChannel {
                        case .mesh:
                            return Color.blue
                        case .location:
                            return Color.green
                        }
                    }()
                    HStack(spacing: 6) {
                        Text(subtitle)
                            .foregroundColor(subtitleColor)
                        Text(sidebarCountText)
                            .foregroundColor(.secondary)
                    }
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                } else {
                    Text(sidebarCountText)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(backgroundColor)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if sidebarTab == .sessions {
                        SidebarSessionsView(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onSelectSession: {
                                showSidebar = true
                            }
                        )
                    } else if case .location = locationManager.selectedChannel {
                        GeohashPeopleList(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPerson: {
                                showSidebar = true
                            }
                        )
                    } else {
                        MeshPeerList(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPeer: { peerID in
                                viewModel.startPrivateChat(with: peerID)
                                showSidebar = true
                            },
                            onToggleFavorite: { peerID in
                                viewModel.toggleFavorite(peerID: peerID)
                            },
                            onShowFingerprint: { peerID in
                                viewModel.showFingerprint(for: peerID)
                            }
                        )
                    }
                }
                .padding(.top, 4)
                .id(viewModel.allPeers.map { "\($0.peerID)-\($0.isConnected)" }.joined())
            }
        }
    }
    
    // MARK: - View Components

    private var privateChatSheetView: some View {
        VStack(spacing: 0) {
            if let privatePeerID = viewModel.selectedPrivateChatPeer {
                let headerContext = makePrivateHeaderContext(for: privatePeerID)

                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar = false
                            viewModel.endPrivateChat()
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(textColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.back_to_main_chat", comment: "Accessibility label for returning to main chat")
                    )

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        privateHeaderInfo(context: headerContext, privatePeerID: privatePeerID)
                        let isFavorite = viewModel.isFavorite(peerID: headerContext.headerPeerID)

                        if !privatePeerID.isGeoDM {
                            Button(action: {
                                viewModel.toggleFavorite(peerID: headerContext.headerPeerID)
                            }) {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 14))
                                    .foregroundColor(isFavorite ? Color.yellow : textColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isFavorite
                                ? String(localized: "content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                                : String(localized: "content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)

                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            viewModel.endPrivateChat()
                            showSidebar = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .frame(height: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(backgroundColor)
            }

            MessageListView(
                privatePeer: viewModel.selectedPrivateChatPeer,
                isAtBottom: $isAtBottomPrivate,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                exportMediaURL: $exportMediaURL,
                expandedMessageIDs: $expandedMessageIDs,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: $showSidebar,
                isTextFieldFocused: $isTextFieldFocused
            )
            .background(backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            inputView
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .highPriorityGesture(
            DragGesture(minimumDistance: 25, coordinateSpace: .local)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    guard horizontal > 80, vertical < 60 else { return }
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar = false
                        viewModel.endPrivateChat()
                    }
                }
        )
    }

    private func privateHeaderInfo(context: PrivateHeaderContext, privatePeerID: PeerID) -> some View {
        Button(action: {
            viewModel.showFingerprint(for: context.headerPeerID)
        }) {
            HStack(spacing: 6) {
                if let connectionState = context.peer?.connectionState {
                    switch connectionState {
                    case .bluetoothConnected:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(textColor)
                            .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                    case .meshReachable:
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(textColor)
                            .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                    case .nostrAvailable:
                        Image(systemName: "globe")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(.purple)
                            .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                    case .offline:
                        EmptyView()
                    }
                } else if viewModel.meshService.isPeerReachable(context.headerPeerID) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                } else if context.isNostrAvailable {
                    Image(systemName: "globe")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(.purple)
                        .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                } else if viewModel.meshService.isPeerConnected(context.headerPeerID) || viewModel.connectedPeers.contains(context.headerPeerID) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                }

                Text(context.displayName)
                    .font(.bitchatSystem(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)

                if !privatePeerID.isGeoDM {
                    let statusPeerID = viewModel.getShortIDForNoiseKey(privatePeerID)
                    let encryptionStatus = viewModel.getEncryptionStatus(for: statusPeerID)
                    if let icon = encryptionStatus.icon {
                        Image(systemName: icon)
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(encryptionStatus == .noiseVerified ? textColor :
                                             encryptionStatus == .noiseSecured ? textColor :
                                             Color.red)
                            .accessibilityLabel(
                                String(
                                    format: String(localized: "content.accessibility.encryption_status", comment: "Accessibility label announcing encryption status"),
                                    locale: .current,
                                    encryptionStatus.accessibilityDescription
                                )
                            )
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(localized: "content.accessibility.private_chat_header", comment: "Accessibility label describing the private chat header"),
                locale: .current,
                context.displayName
            )
        )
        .accessibilityHint(
            String(localized: "content.accessibility.view_fingerprint_hint", comment: "Accessibility hint for viewing encryption fingerprint")
        )
        .frame(height: headerHeight)
    }

    private func makePrivateHeaderContext(for privatePeerID: PeerID) -> PrivateHeaderContext {
        let headerPeerID = viewModel.getShortIDForNoiseKey(privatePeerID)
        let peer = viewModel.getPeer(byID: headerPeerID)

        let displayName: String = {
            if privatePeerID.isGeoDM, case .location(let ch) = locationManager.selectedChannel {
                let disp = viewModel.geohashDisplayName(for: privatePeerID)
                return "#\(ch.geohash)/@\(disp)"
            }
            if let name = peer?.displayName { return name }
            if let name = viewModel.meshService.peerNickname(peerID: headerPeerID) { return name }
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: Data(hexString: headerPeerID.id) ?? Data()),
               !fav.peerNickname.isEmpty { return fav.peerNickname }
            if headerPeerID.id.count == 16 {
                let candidates = viewModel.identityManager.getCryptoIdentitiesByPeerIDPrefix(headerPeerID)
                if let id = candidates.first,
                   let social = viewModel.identityManager.getSocialIdentity(for: id.fingerprint) {
                    if let pet = social.localPetname, !pet.isEmpty { return pet }
                    if !social.claimedNickname.isEmpty { return social.claimedNickname }
                }
            } else if let keyData = headerPeerID.noiseKey {
                let fp = keyData.sha256Fingerprint()
                if let social = viewModel.identityManager.getSocialIdentity(for: fp) {
                    if let pet = social.localPetname, !pet.isEmpty { return pet }
                    if !social.claimedNickname.isEmpty { return social.claimedNickname }
                }
            }
            return String(localized: "common.unknown", comment: "Fallback label for unknown peer")
        }()

        let isNostrAvailable: Bool = {
            guard let connectionState = peer?.connectionState else {
                if let noiseKey = Data(hexString: headerPeerID.id),
                   let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                   favoriteStatus.isMutual {
                    return true
                }
                return false
            }
            return connectionState == .nostrAvailable
        }()

        return PrivateHeaderContext(
            headerPeerID: headerPeerID,
            peer: peer,
            displayName: displayName,
            isNostrAvailable: isNostrAvailable
        )
    }

    // Compute channel-aware people count and color for toolbar (cross-platform)
    private func channelPeopleCountAndColor() -> (Int, Color) {
        switch locationManager.selectedChannel {
        case .location:
            let n = viewModel.geohashPeople.count
            let standardGreen = (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
            return (n, n > 0 ? standardGreen : Color.secondary)
        case .mesh:
            let counts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
                guard peer.peerID != viewModel.meshService.myPeerID else { return }
                if peer.isConnected { counts.mesh += 1; counts.others += 1 }
                else if peer.isReachable { counts.others += 1 }
            }
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let color: Color = counts.mesh > 0 ? meshBlue : Color.secondary
            return (counts.others, color)
        }
    }

    
    private var mainHeaderView: some View {
        HStack(spacing: 0) {
            Text(verbatim: "bitchat/")
                .font(.bitchatSystem(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
                .onTapGesture(count: 3) {
                    // PANIC: Triple-tap to clear all data
                    viewModel.panicClearAllData()
                }
                .onTapGesture(count: 1) {
                    // Single tap for app info
                    showAppInfo = true
                }
            
            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                
                TextField("content.input.nickname_placeholder", text: $viewModel.nickname)
                    .textFieldStyle(.plain)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .frame(maxWidth: 80)
                    .foregroundColor(textColor)
                    .focused($isNicknameFieldFocused)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .modifier(FocusEffectDisabledModifier())
                    .onChange(of: isNicknameFieldFocused) { isFocused in
                        if !isFocused {
                            // Only validate when losing focus
                            viewModel.validateAndSaveNickname()
                        }
                    }
                    .onSubmit {
                        viewModel.validateAndSaveNickname()
                    }
            }
            
            Spacer()
            
            // Channel badge + dynamic spacing + people counter
            // Precompute header count and color outside the ViewBuilder expressions
            let cc = channelPeopleCountAndColor()
            let headerCountColor: Color = cc.1
            let headerOtherPeersCount: Int = {
                if case .location = locationManager.selectedChannel {
                    return viewModel.visibleGeohashPeople().count
                }
                return cc.0
            }()

            HStack(spacing: 10) {
                // Unread icon immediately to the left of the channel badge (independent from channel button)
                
                // Unread indicator (now shown on iOS and macOS)
                if viewModel.hasAnyUnreadMessages {
                    Button(action: { viewModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.open_unread_private_chat", comment: "Accessibility label for the unread private chat button")
                    )
                }
                // Notes icon (mesh only and when location is authorized), to the left of #mesh
                if case .mesh = locationManager.selectedChannel, locationManager.permissionState == .authorized {
                    Button(action: {
                        // Kick a one-shot refresh and show the sheet immediately.
                        LocationChannelManager.shared.enableLocationChannels()
                        LocationChannelManager.shared.refreshChannels()
                        // If we already have a block geohash, pass it; otherwise wait in the sheet.
                        notesGeohash = LocationChannelManager.shared.availableChannels.first(where: { $0.level == .building })?.geohash
                        showLocationNotes = true
                    }) {
                        HStack(alignment: .center, spacing: 4) {
                            Image(systemName: "note.text")
                                .font(.bitchatSystem(size: 12))
                                .foregroundColor(Color.orange.opacity(0.8))
                                .padding(.top, 1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.location_notes", comment: "Accessibility label for location notes button")
                    )
                }

                // Bookmark toggle (geochats): to the left of #geohash
                if case .location(let ch) = locationManager.selectedChannel {
                    Button(action: { bookmarks.toggle(ch.geohash) }) {
                        Image(systemName: bookmarks.isBookmarked(ch.geohash) ? "bookmark.fill" : "bookmark")
                            .font(.bitchatSystem(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "content.accessibility.toggle_bookmark", comment: "Accessibility label for toggling a geohash bookmark"),
                            locale: .current,
                            ch.geohash
                        )
                    )
                }

                // Location channels button '#'
                Button(action: { showLocationChannelsSheet = true }) {
                    let badgeText: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "#mesh"
                        case .location(let ch): return "#\(ch.geohash)"
                        }
                    }()
                    let badgeColor: Color = {
                        switch locationManager.selectedChannel {
                        case .mesh:
                            return Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
                        case .location:
                            return (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
                        }
                    }()
                    Text(badgeText)
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .lineLimit(headerLineLimit)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.location_channels", comment: "Accessibility label for the location channels button")
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .padding(.trailing, 2)

                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: headerPeerIconSize, weight: .regular))
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                                locale: .current,
                                headerOtherPeersCount
                            )
                        )
                    Text("\(headerOtherPeersCount)")
                        .font(.system(size: headerPeerCountFontSize, weight: .regular, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(headerCountColor)
                .padding(.leading, 2)
                .lineLimit(headerLineLimit)
                .fixedSize(horizontal: true, vertical: false)

                // QR moved to the PEOPLE header in the sidebar when on mesh channel
            }
            .layoutPriority(3)
            .onTapGesture {
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar.toggle()
                }
            }
            .sheet(isPresented: $showVerifySheet) {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(viewModel)
            }

            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.bitchatSystem(size: 12))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showLocationChannelsSheet) {
            LocationChannelsSheet(isPresented: $showLocationChannelsSheet)
                .environmentObject(viewModel)
                .onAppear { viewModel.isLocationChannelsSheetPresented = true }
                .onDisappear { viewModel.isLocationChannelsSheetPresented = false }
        }
        .sheet(isPresented: $showLocationNotes, onDismiss: {
            notesGeohash = nil
        }) {
            Group {
                if let gh = notesGeohash ?? LocationChannelManager.shared.availableChannels.first(where: { $0.level == .building })?.geohash {
                    LocationNotesView(geohash: gh)
                        .environmentObject(viewModel)
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Text("content.notes.title")
                                .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                            Spacer()
                            Button(action: { showLocationNotes = false }) {
                                Image(systemName: "xmark")
                                    .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "common.close", comment: "Accessibility label for close buttons"))
                        }
                        .frame(height: headerHeight)
                        .padding(.horizontal, 12)
                        .background(backgroundColor.opacity(0.95))
                        Text("content.notes.location_unavailable")
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Button("content.location.enable") {
                            LocationChannelManager.shared.enableLocationChannels()
                            LocationChannelManager.shared.refreshChannels()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    // per-sheet global onChange added below
                }
            }
            .onAppear {
                // Ensure we are authorized and start live location updates (distance-filtered)
                LocationChannelManager.shared.enableLocationChannels()
                LocationChannelManager.shared.beginLiveRefresh()
            }
            .onDisappear {
                LocationChannelManager.shared.endLiveRefresh()
            }
            .onChange(of: locationManager.availableChannels) { channels in
                if let current = channels.first(where: { $0.level == .building })?.geohash,
                    notesGeohash != current {
                    notesGeohash = current
                    #if os(iOS)
                    // Light taptic when geohash changes while the sheet is open
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred()
                    #endif
                }
            }
        }
        .onAppear {
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .onChange(of: locationManager.selectedChannel) { _ in
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .onChange(of: locationManager.permissionState) { _ in
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .alert("content.alert.screenshot.title", isPresented: $viewModel.showScreenshotPrivacyWarning) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("content.alert.screenshot.message")
        }
        .background(backgroundColor.opacity(0.95))
    }

}

// MARK: - Helper Views

private extension ContentView {
    #if os(iOS)
    func queuePickedImage(_ image: UIImage?) {
        guard let image else { return }
        Task {
            do {
                let processedURL = try ImageUtils.processImage(image)
                await MainActor.run {
                    viewModel.queueDraftImage(url: processedURL, for: viewModel.selectedPrivateChatPeer)
                }
            } catch {
                SecureLogger.error("Image processing failed: \(error)", category: .session)
            }
        }
    }
    #else
    func queuePickedImage(url: URL?) {
        guard let url else { return }
        Task {
            do {
                let processedURL = try ImageUtils.processImage(at: url)
                await MainActor.run {
                    viewModel.queueDraftImage(url: processedURL, for: viewModel.selectedPrivateChatPeer)
                }
            } catch {
                SecureLogger.error("Image processing failed: \(error)", category: .session)
            }
        }
    }
    #endif

    var recordingIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .foregroundColor(.red)
                .font(.bitchatSystem(size: 20))
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                Text(
                    "recording \(voiceRecordingVM.formattedDuration(for: context.date))",
                    comment: "Voice note recording duration indicator"
                )
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .foregroundColor(.red)
            }
            Spacer()
            Button(action: voiceRecordingVM.cancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
                    .font(.bitchatSystem(size: 18))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.15))
        )
    }

    private var shouldShowMediaControls: Bool {
        if let peer = viewModel.selectedPrivateChatPeer, !(peer.isGeoDM || peer.isGeoChat) {
            return true
        }
        switch locationManager.selectedChannel {
        case .mesh:
            return true
        case .location:
            return false
        }
    }

    private var shouldShowVoiceControl: Bool {
        if let peer = viewModel.selectedPrivateChatPeer, !(peer.isGeoDM || peer.isGeoChat) {
            return true
        }
        switch locationManager.selectedChannel {
        case .mesh:
            return true
        case .location:
            return false
        }
    }

    private var composerAccentColor: Color {
        viewModel.selectedPrivateChatPeer != nil ? Color.orange : textColor
    }

    var attachmentButton: some View {
        #if os(iOS)
        Image(systemName: "camera.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(composerAccentColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .onTapGesture {
                // Tap = Photo Library
                imagePickerSourceType = .photoLibrary
                showImagePicker = true
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                // Long press = Camera
                imagePickerSourceType = .camera
                showImagePicker = true
            }
            .accessibilityLabel("Tap for library, long press for camera")
        #else
        Button(action: { showMacImagePicker = true }) {
            Image(systemName: "photo.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(composerAccentColor)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose photo")
        #endif
    }

    @ViewBuilder
    var sendOrMicButton: some View {
        let hasText = !trimmedMessageText.isEmpty
        if shouldShowVoiceControl {
            ZStack {
                micButtonView
                    .opacity(hasText ? 0 : 1)
                    .allowsHitTesting(!hasText)
                sendButtonView(enabled: hasText)
                    .opacity(hasText ? 1 : 0)
                    .allowsHitTesting(hasText)
            }
            .frame(width: 36, height: 36)
        } else {
            sendButtonView(enabled: hasText)
                .frame(width: 36, height: 36)
        }
    }

    private var micButtonView: some View {
        Image(systemName: "mic.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(voiceRecordingVM.state.isActive ? Color.red : composerAccentColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .overlay(
                Color.clear
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in voiceRecordingVM.start(shouldShow: shouldShowVoiceControl) }
                            .onEnded { _ in voiceRecordingVM.finish(completion: viewModel.sendVoiceNote) }
                    )
            )
            .accessibilityLabel("Hold to record a voice note")
    }

    private func sendButtonView(enabled: Bool) -> some View {
        let activeColor = composerAccentColor
        return Button(action: sendMessage) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(enabled ? activeColor : Color.gray)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            String(localized: "content.accessibility.send_message", comment: "Accessibility label for the send message button")
        )
        .accessibilityHint(
            enabled
            ? String(localized: "content.accessibility.send_hint_ready", comment: "Hint prompting the user to send the message")
            : String(localized: "content.accessibility.send_hint_empty", comment: "Hint prompting the user to enter a message")
        )
    }
}

private struct DraftAttachmentThumbnailView: View {
    let attachment: ChatViewModel.DraftAttachment
    let onRemove: () -> Void
    let onPreview: () -> Void

    #if os(iOS)
    @State private var platformImage: UIImage?
    #else
    @State private var platformImage: NSImage?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == "image", let image = platformImage {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else {
                    ZStack {
                        Color.gray.opacity(0.2)
                        Image(systemName: attachment.kind == "image" ? "photo" : "doc")
                            .font(.bitchatSystem(size: 16))
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                if attachment.kind == "image" {
                    onPreview()
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.65)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        guard attachment.kind == "image" else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            #if os(iOS)
            guard let image = UIImage(contentsOfFile: attachment.url.path) else { return }
            #else
            guard let image = NSImage(contentsOf: attachment.url) else { return }
            #endif
            DispatchQueue.main.async {
                platformImage = image
            }
        }
    }
}

#if os(iOS)
private struct MediaFileExportWrapper: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url])
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
#endif
