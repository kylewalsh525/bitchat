//
// SidebarSessionsView.swift
// bitchat
//
// Session history navigator for agent chats.
//

import SwiftUI

struct SidebarSessionsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    var onSelectSession: (() -> Void)? = nil

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        if viewModel.agentSessionHistory.isEmpty {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.bitchatSystem(size: 22))
                    .foregroundColor(secondaryTextColor)
                Text("No sessions yet")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(.top, 20)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.agentSessionHistory) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title.isEmpty ? "New session" : record.title)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(record.role)
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            Text("•")
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            Text(relativeFormatter.localizedString(for: record.lastUsedAt, relativeTo: Date()))
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            if let paymentState = record.paymentState {
                                Text(paymentLabel(for: paymentState))
                                    .font(.bitchatSystem(size: 10, design: .monospaced))
                                    .foregroundColor(paymentColor(for: paymentState))
                            }
                        }
                        if let modelText = modelIdentityText(for: record) {
                            Text(modelText)
                                .font(.bitchatSystem(size: 10, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .lineLimit(1)
                        }
                        HStack {
                            Spacer()
                            Button(action: {
                                resume(record)
                            }) {
                                Text("Resume")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(textColor.opacity(0.6), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.12))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        resume(record)
                    }
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)
            Divider()
                .padding(.top, 8)
            HStack {
                Spacer()
                Button(action: {
                    viewModel.wipeAllAgentSessions()
                }) {
                    Text("Delete all sessions")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.7), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func resume(_ record: AgentSessionRecord) {
        let result = viewModel.resumeAgentSession(recordID: record.id)
        if case .error(let message) = result {
            viewModel.addSystemMessage(message)
        }
        onSelectSession?()
    }

    private func paymentLabel(for state: AgentSessionPaymentState) -> String {
        switch state {
        case .paid:
            return "paid"
        case .acceptedOffline:
            return "offline"
        case .finalized:
            return "finalized"
        case .failed:
            return "failed"
        }
    }

    private func paymentColor(for state: AgentSessionPaymentState) -> Color {
        switch state {
        case .paid:
            return .yellow
        case .acceptedOffline:
            return .orange
        case .finalized:
            return .green
        case .failed:
            return .red
        }
    }

    private func modelIdentityText(for record: AgentSessionRecord) -> String? {
        guard let raw = record.modelHash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let match = viewModel.knownModelCatalog.resolve(modelId: nil, modelHash: raw)
        let prefixLen = 24
        let prefix = raw.count > prefixLen ? String(raw.prefix(prefixLen)) + "…" : raw
        if let match {
            return "model: \(match.model.name) (\(prefix))"
        }
        return "model: \(prefix)"
    }
}
