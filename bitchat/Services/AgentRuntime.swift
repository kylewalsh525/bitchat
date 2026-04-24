//
// AgentRuntime.swift
// bitchat
//
// Minimal agent runtime interface for mesh agent requests.
//

import Foundation
import BitFoundation

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

protocol StreamingAgentRuntime: AgentRuntime {
    func runStream(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?, session: AgentSession?, attachments: [AgentRuntimeAttachment]) -> AsyncStream<AgentResponseChunkPacket>
}

extension StreamingAgentRuntime {
    func runStream(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?, session: AgentSession?, attachments: [AgentRuntimeAttachment]) -> AsyncStream<AgentResponseChunkPacket> {
        AsyncStream { continuation in
            Task {
                let result = await run(request: request, from: peerID, localInfo: localInfo, session: session, attachments: attachments)
                let chunks = AgentMeshChunker.chunk(text: result.response.content, maxBytes: AgentMeshConstants.maxTLVStringBytes)
                let total = chunks.count
                for (index, chunk) in chunks.enumerated() {
                    let packet = AgentResponseChunkPacket(
                        requestID: result.response.requestID,
                        index: UInt16(index + 1),
                        isFinal: index + 1 == total,
                        content: chunk,
                        isError: result.response.isError,
                        sessionID: result.response.sessionID
                    )
                    continuation.yield(packet)
                }
                continuation.finish()
            }
        }
    }
}

enum AgentRuntimeMode: String, Codable {
    case echo
    case gateway
}

enum AgentGatewayPreset: String, Codable {
    case localOllama
    case localLMStudio
    case custom

    var defaultURL: String {
        switch self {
        case .localOllama, .localLMStudio:
            return "http://127.0.0.1:8080/agent/run"
        case .custom:
            return "http://127.0.0.1:8080/agent/run"
        }
    }
}

struct AgentRuntimeConfig: Codable, Equatable {
    var mode: AgentRuntimeMode
    var gatewayPreset: AgentGatewayPreset
    var gatewayURL: String
    var gatewayToken: String?
    var timeoutSeconds: UInt32
    var streamResponses: Bool

    var timeoutMs: Int {
        Int(timeoutSeconds) * 1000
    }

    static let `default` = AgentRuntimeConfig(
        mode: .echo,
        gatewayPreset: .localOllama,
        gatewayURL: "http://127.0.0.1:8080/agent/run",
        gatewayToken: nil,
        timeoutSeconds: 30,
        streamResponses: true
    )

    private enum CodingKeys: String, CodingKey {
        case mode
        case gatewayPreset
        case gatewayURL
        case gatewayToken
        case timeoutSeconds
        case streamResponses
    }

    init(mode: AgentRuntimeMode, gatewayPreset: AgentGatewayPreset, gatewayURL: String, gatewayToken: String?, timeoutSeconds: UInt32, streamResponses: Bool) {
        self.mode = mode
        self.gatewayPreset = gatewayPreset
        self.gatewayURL = gatewayURL
        self.gatewayToken = gatewayToken
        self.timeoutSeconds = timeoutSeconds
        self.streamResponses = streamResponses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AgentRuntimeMode.self, forKey: .mode) ?? .echo
        gatewayPreset = try container.decodeIfPresent(AgentGatewayPreset.self, forKey: .gatewayPreset) ?? .localOllama
        gatewayURL = try container.decodeIfPresent(String.self, forKey: .gatewayURL) ?? "http://127.0.0.1:8080/agent/run"
        gatewayToken = try container.decodeIfPresent(String.self, forKey: .gatewayToken)
        timeoutSeconds = try container.decodeIfPresent(UInt32.self, forKey: .timeoutSeconds) ?? 30
        streamResponses = try container.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(gatewayPreset, forKey: .gatewayPreset)
        try container.encode(gatewayURL, forKey: .gatewayURL)
        try container.encodeIfPresent(gatewayToken, forKey: .gatewayToken)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(streamResponses, forKey: .streamResponses)
    }
}

struct EchoAgentRuntime: StreamingAgentRuntime {
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
