//
// TextMessageView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct TextMessageView: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @EnvironmentObject private var viewModel: ChatViewModel
    
    let message: BitchatMessage
    let showStreamingIndicator: Bool
    @Binding var expandedMessageIDs: Set<String>

    @State private var showMintApprovalSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Precompute heavy token scans once per row
            let cashuLinks = message.content.extractCashuLinks()
            let lightningLinks = message.content.extractLightningLinks()
            HStack(alignment: .top, spacing: 0) {
                let isLong = (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty
                let isExpanded = expandedMessageIDs.contains(message.id)
                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isLong && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showStreamingIndicator {
                    StreamingDotsView()
                        .padding(.leading, 6)
                        .padding(.top, 2)
                }
                
                // Delivery status indicator for private messages
                if message.isPrivate && viewModel.isSelfMessage(message),
                   let status = message.deliveryStatus {
                    DeliveryStatusView(status: status)
                        .padding(.leading, 4)
                }
            }
            
            // Expand/Collapse for very long messages
            if (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty {
                let isExpanded = expandedMessageIDs.contains(message.id)
                let labelKey = isExpanded ? LocalizedStringKey("content.message.show_less") : LocalizedStringKey("content.message.show_more")
                Button(labelKey) {
                    if isExpanded { expandedMessageIDs.remove(message.id) }
                    else { expandedMessageIDs.insert(message.id) }
                }
                .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color.blue)
                .padding(.top, 4)
            }

            // Render payment chips (Lightning / Cashu) with rounded background
            if !lightningLinks.isEmpty || !cashuLinks.isEmpty {
                HStack(spacing: 8) {
                    ForEach(lightningLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .lightning(link))
                    }
                    ForEach(cashuLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .cashu(link))
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 2)
            }

            if let requestID = viewModel.requestIDForAgentMessage(message),
               let prompt = viewModel.paymentPrompt(for: requestID) {
                let trancheLabel: String = {
                    guard let trancheIndex = prompt.trancheIndex, let trancheCount = prompt.trancheCount else {
                        return ""
                    }
                    return " (\(trancheIndex)/\(trancheCount))"
                }()
                let isCashu = prompt.rail == .cashu
                let normalizedMint = isCashu ? CashuMintAllowlistStore.normalizeMintURL(prompt.mintURL) : ""
                let mintApproved = isCashu ? viewModel.cashuMintAllowlistStore.isAllowed(mintURL: normalizedMint) : true
                let mintHost = URL(string: normalizedMint)?.host ?? normalizedMint
                let gatewayHost = URL(string: prompt.x402GatewayURL ?? prompt.mintURL)?.host ?? (prompt.x402GatewayURL ?? prompt.mintURL)
                let expiresLabel = formatExpiresInLabel(expiresAtMs: prompt.expiresAtMs)
                let settlementLabel = prompt.rail == .x402 ? "Online required" : (prompt.settlementMode == .offlineAccepted ? "Offline accepted" : "Online required")
                let lockLabel: String = {
                    switch prompt.requiresLocking ?? AgentPaymentLockingMode.none {
                    case .p2pk:
                        return "P2PK"
                    case .none:
                        return "None"
                    }
                }()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Payment required", systemImage: "creditcard")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(expiresLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("\(prompt.amount) \(prompt.unit)\(trancheLabel)")
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button("Pay now") {
                                viewModel.payPendingAgentRequestFromUI(requestID: requestID)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!mintApproved)

                            Button("Wallet") {
                                viewModel.isWalletPresented = true
                            }
                            .buttonStyle(.bordered)

                            if isCashu && !mintApproved {
                                Button("Approve mint") {
                                    showMintApprovalSheet = true
                                }
                                .buttonStyle(.bordered)
                            }

                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Pay now") {
                                viewModel.payPendingAgentRequestFromUI(requestID: requestID)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!mintApproved)

                            HStack(spacing: 10) {
                                Button("Wallet") {
                                    viewModel.isWalletPresented = true
                                }
                                .buttonStyle(.bordered)

                                if isCashu && !mintApproved {
                                    Button("Approve mint") {
                                        showMintApprovalSheet = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if isCashu {
                            Text("Mint: \(mintHost) (\(mintApproved ? "approved" : "approval required"))")
                        } else {
                            Text("Gateway: \(gatewayHost)")
                            if let chain = prompt.x402ChainID {
                                Text("Chain: eip155:\(chain)")
                            }
                            if let token = prompt.x402TokenAddress, !token.isEmpty {
                                Text("Token: \(token)")
                            }
                            if let payTo = prompt.x402PayTo, !payTo.isEmpty {
                                Text("Pay to: \(payTo)")
                            }
                        }
                        Text("Settlement: \(settlementLabel)")
                        if isCashu {
                            Text("Locking: \(lockLabel)")
                        } else {
                            Text("Rail: x402")
                        }
                        if let pricingModel = prompt.pricingModel {
                            Text("Pricing: \(pricingModel.rawValue)")
                        }
                        if isCashu && !mintApproved {
                            Text("Payment is blocked until you approve this mint.")
                        } else if isCashu && prompt.settlementMode == .offlineAccepted {
                            Text("Offline acceptance can delay final settlement until mint finality.")
                        }
                        if isCashu && (prompt.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk {
                            Text("P2PK ties proofs to this request and reduces interception risk.")
                        }
                        if !isCashu {
                            Text("x402 payments are online-only and less private than Cashu.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
                )
                .sheet(isPresented: $showMintApprovalSheet) {
                    MintApprovalSheet(
                        mints: [normalizedMint],
                        onCancel: {
                            showMintApprovalSheet = false
                        },
                        onApprove: {
                            viewModel.cashuMintAllowlistStore.allow(mintURL: normalizedMint)
                            showMintApprovalSheet = false
                        }
                    )
                }
            }
        }
    }

    private func formatExpiresInLabel(expiresAtMs: UInt64) -> String {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if expiresAtMs <= nowMs {
            return "expired"
        }
        let remaining = Int((expiresAtMs - nowMs) / 1000)
        if remaining < 60 {
            return "expires in \(remaining)s"
        }
        let minutes = remaining / 60
        let seconds = remaining % 60
        if minutes < 60 {
            return "expires in \(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let minutesLeft = minutes % 60
        return "expires in \(hours)h \(minutesLeft)m"
    }
}

private struct StreamingDotsView: View {
    @State private var phase: Int = 0

    var body: some View {
        Text(dots(for: phase))
            .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .onAppear {
                phase = 0
            }
            .task {
                while true {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    phase = (phase + 1) % 4
                }
            }
    }

    private func dots(for phase: Int) -> String {
        switch phase {
        case 1: return "·"
        case 2: return "··"
        case 3: return "···"
        default: return ""
        }
    }
}

@available(macOS 14, iOS 17, *)
#Preview {
    @Previewable @State var ids: Set<String> = []
    let keychain = PreviewKeychainManager()
    
    Group {
        List {
            TextMessageView(message: .preview, showStreamingIndicator: false, expandedMessageIDs: $ids)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .light)
        
        List {
            TextMessageView(message: .preview, showStreamingIndicator: true, expandedMessageIDs: $ids)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .dark)
    }
    .environmentObject(
        ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(),
            identityManager: SecureIdentityStateManager(keychain)
        )
    )
}
