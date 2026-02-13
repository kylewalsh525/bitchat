//
// AgentSession.swift
// bitchat
//
// Per-session agent chat state (privacy-preserving).
//

import Foundation

struct AgentSessionMessage: Codable, Equatable {
    let role: String
    let content: String
}

enum AgentSessionPaymentState: String, Codable, CaseIterable {
    case paid
    case acceptedOffline = "accepted_offline"
    case finalized
    case failed
}

struct AgentSession: Equatable {
    let sessionID: String
    let threadID: PeerID
    let peerID: PeerID
    let peerNickname: String
    let role: String
    let createdAt: Date
    let senderAlias: String
    let recordID: String?
    var seedHistory: [AgentSessionMessage]
    var seedInjected: Bool
    var history: [AgentSessionMessage]
    var paymentState: AgentSessionPaymentState?
    var paymentUpdatedAt: Date?

    mutating func appendMessage(role: String, content: String, limit: Int) {
        history.append(AgentSessionMessage(role: role, content: content))
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
