//
// AgentRuntime.swift
// bitchat
//
// Minimal agent runtime interface for mesh agent requests.
//

import Foundation

struct AgentRuntimeAttachment {
    let data: Data
    let fileName: String
    let mimeType: String
}

struct AgentRuntimeResult {
    let response: AgentResponsePacket
    let attachments: [AgentRuntimeAttachment]
}

protocol AgentRuntime {
    func run(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?, session: AgentSession?, attachments: [AgentRuntimeAttachment]) async -> AgentRuntimeResult
}

enum AgentRuntimeMode: String, Codable {
    case echo
    case gateway
}

struct AgentRuntimeConfig: Codable, Equatable {
    var mode: AgentRuntimeMode
    var gatewayURL: String
    var gatewayToken: String?
    var timeoutSeconds: UInt32

    var timeoutMs: Int {
        Int(timeoutSeconds) * 1000
    }

    static let `default` = AgentRuntimeConfig(
        mode: .echo,
        gatewayURL: "http://127.0.0.1:8080/agent/run",
        gatewayToken: nil,
        timeoutSeconds: 30
    )
}

struct EchoAgentRuntime: AgentRuntime {
    func run(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?, session: AgentSession?, attachments: [AgentRuntimeAttachment]) async -> AgentRuntimeResult {
        let role = localInfo?.role ?? "agent"
        let model = localInfo?.modelId ?? "local"
        let response = "[\(role)/\(model)] received: \(request.prompt)"
        let packet = AgentResponsePacket(
            requestID: request.requestID,
            content: response,
            isError: false,
            sessionID: request.sessionID,
            chunkIndex: nil,
            chunkTotal: nil
        )
        return AgentRuntimeResult(response: packet, attachments: [])
    }
}
