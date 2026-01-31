//
// GatewayAgentRuntime.swift
// bitchat
//
// Agent runtime backed by a local/remote HTTP gateway.
//

import Foundation

enum AgentRuntimeHealthEvent {
    case success(Date)
    case failure(String, Date)
}

final class GatewayAgentRuntime: StreamingAgentRuntime {
    private let client: AgentGatewayClient
    private let config: AgentRuntimeConfig
    private let onHealthUpdate: ((AgentRuntimeHealthEvent) -> Void)?

    init(config: AgentRuntimeConfig,
         client: AgentGatewayClient = AgentGatewayClient(),
         onHealthUpdate: ((AgentRuntimeHealthEvent) -> Void)? = nil) {
        self.config = config
        self.client = client
        self.onHealthUpdate = onHealthUpdate
    }

    func run(request: AgentRequestPacket, from peerID: PeerID, localInfo: AgentInfo?, session: AgentSession?, attachments: [AgentRuntimeAttachment]) async -> AgentRuntimeResult {
        do {
            let response = try await client.run(request: request, localInfo: localInfo, config: config, session: session, attachments: attachments)
            onHealthUpdate?(.success(Date()))
            let responseID = response.requestID.isEmpty ? request.requestID : response.requestID
            let packet = AgentResponsePacket(
                requestID: responseID,
                content: response.content,
                isError: response.isError,
                sessionID: request.sessionID,
                chunkIndex: nil,
                chunkTotal: nil
            )
            let attachments: [AgentRuntimeAttachment] = response.attachments?.compactMap { item in
                guard let data = Data(base64Encoded: item.dataBase64) else { return nil }
                let fileName = item.fileName ?? "attachment"
                return AgentRuntimeAttachment(data: data, fileName: fileName, mimeType: item.mimeType)
            } ?? []
            return AgentRuntimeResult(response: packet, attachments: attachments)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onHealthUpdate?(.failure(message, Date()))
            let packet = AgentResponsePacket(
                requestID: request.requestID,
                content: "gateway error: \(message)",
                isError: true,
                sessionID: request.sessionID,
                chunkIndex: nil,
                chunkTotal: nil
            )
            return AgentRuntimeResult(response: packet, attachments: [])
        }
    }
}
