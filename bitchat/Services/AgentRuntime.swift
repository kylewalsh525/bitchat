//
// AgentRuntime.swift
// bitchat
//
// Minimal agent runtime interface for mesh agent requests.
//

import Foundation

protocol AgentRuntime {
    func run(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?) async -> AgentResponsePacket
}

struct EchoAgentRuntime: AgentRuntime {
    func run(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?) async -> AgentResponsePacket {
        let role = localInfo?.role ?? "agent"
        let model = localInfo?.modelId ?? "local"
        let response = "[\(role)/\(model)] received: \(request.prompt)"
        return AgentResponsePacket(requestID: request.requestID, content: response, isError: false)
    }
}
