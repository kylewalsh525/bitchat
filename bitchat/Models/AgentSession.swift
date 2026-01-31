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

struct AgentSession: Equatable {
    let sessionID: String
    let threadID: PeerID
    let peerID: PeerID
    let peerNickname: String
    let role: String
    let createdAt: Date
    let senderAlias: String
    var history: [AgentSessionMessage]

    mutating func appendMessage(role: String, content: String, limit: Int) {
        history.append(AgentSessionMessage(role: role, content: content))
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
