//
// AgentMeshLogger.swift
// bitchat
//
// Unified logging for agent mesh lifecycle events.
//

import Foundation
import BitFoundation
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
            Task { await SupportEventLog.shared.record(category: "agent", message: "request sent id=\(requestID.prefix(8)) role=\(role) to=\(peerID.id)") }
        case let .requestReceived(requestID, role, peerID):
            SecureLogger.debug("🤖 Agent request received id=\(requestID.prefix(8))… role=\(role) from=\(peerID)", category: .session)
            Task { await SupportEventLog.shared.record(category: "agent", message: "request received id=\(requestID.prefix(8)) role=\(role) from=\(peerID.id)") }
        case let .responseSent(requestID, peerID, isError):
            SecureLogger.debug("🤖 Agent response sent id=\(requestID.prefix(8))… to=\(peerID) err=\(isError)", category: .session)
            Task { await SupportEventLog.shared.record(category: "agent", message: "response sent id=\(requestID.prefix(8)) to=\(peerID.id) err=\(isError)") }
        case let .responseReceived(requestID, peerID, isError):
            SecureLogger.debug("🤖 Agent response received id=\(requestID.prefix(8))… from=\(peerID) err=\(isError)", category: .session)
            Task { await SupportEventLog.shared.record(category: "agent", message: "response received id=\(requestID.prefix(8)) from=\(peerID.id) err=\(isError)") }
        case let .runtimeError(message):
            SecureLogger.warning("🤖 Agent runtime error: \(message)", category: .session)
            Task { await SupportEventLog.shared.record(category: "agent", message: "runtime error: \(message)") }
        }
    }
}
