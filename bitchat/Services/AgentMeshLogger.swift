//
// AgentMeshLogger.swift
// bitchat
//
// Unified logging for agent mesh lifecycle events.
//

import Foundation
import BitLogger

enum AgentMeshEvent {
    case requestSent(requestID: String, role: String, peerID: PeerID)
    case requestReceived(requestID: String, role: String, peerID: PeerID)
    case responseSent(requestID: String, peerID: PeerID, isError: Bool)
    case responseReceived(requestID: String, peerID: PeerID, isError: Bool)
    case runtimeError(message: String)
}

enum AgentMeshLogger {
    static func log(_ event: AgentMeshEvent) {
        switch event {
        case let .requestSent(requestID, role, peerID):
            SecureLogger.debug("🤖 Agent request sent id=\(requestID.prefix(8))… role=\(role) to=\(peerID)", category: .session)
        case let .requestReceived(requestID, role, peerID):
            SecureLogger.debug("🤖 Agent request received id=\(requestID.prefix(8))… role=\(role) from=\(peerID)", category: .session)
        case let .responseSent(requestID, peerID, isError):
            SecureLogger.debug("🤖 Agent response sent id=\(requestID.prefix(8))… to=\(peerID) err=\(isError)", category: .session)
        case let .responseReceived(requestID, peerID, isError):
            SecureLogger.debug("🤖 Agent response received id=\(requestID.prefix(8))… from=\(peerID) err=\(isError)", category: .session)
        case let .runtimeError(message):
            SecureLogger.warning("🤖 Agent runtime error: \(message)", category: .session)
        }
    }
}
