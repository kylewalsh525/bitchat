//
// AgentGatewayClient.swift
// bitchat
//
// HTTP client for local/remote agent gateway.
//

import Foundation

struct AgentGatewayMessage: Codable {
    let role: String
    let content: String
}

struct AgentGatewayRequest: Codable {
    let requestID: String
    let role: String
    let prompt: String
    let modelId: String
    let timeoutMs: Int
    let sessionID: String?
    let senderAlias: String?
    let messages: [AgentGatewayMessage]?
    let attachments: [AgentGatewayAttachment]?
}

struct AgentGatewayAttachment: Codable {
    let fileName: String?
    let mimeType: String
    let dataBase64: String
}

struct AgentGatewayResponse: Codable {
    let requestID: String
    let content: String
    let isError: Bool
    let attachments: [AgentGatewayAttachment]?
}

enum AgentGatewayError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid gateway URL"
        case .httpStatus(let code):
            return "gateway HTTP \(code)"
        case .emptyResponse:
            return "empty gateway response"
        case .decodeFailed:
            return "failed to decode gateway response"
        }
    }
}

final class AgentGatewayClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(request: AgentRequestPacket, localInfo: AgentInfo?, config: AgentRuntimeConfig, session agentSession: AgentSession?, attachments: [AgentRuntimeAttachment]) async throws -> AgentGatewayResponse {
        guard let url = URL(string: config.gatewayURL) else { throw AgentGatewayError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(config.timeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.gatewayToken, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let history = agentSession?.history.map { AgentGatewayMessage(role: $0.role, content: $0.content) }
        let outgoingAttachments: [AgentGatewayAttachment]? = attachments.isEmpty ? nil : attachments.map { attachment in
            AgentGatewayAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                dataBase64: attachment.data.base64EncodedString()
            )
        }
        let body = AgentGatewayRequest(
            requestID: request.requestID,
            role: request.role,
            prompt: request.prompt,
            modelId: localInfo?.modelId ?? "local",
            timeoutMs: config.timeoutMs,
            sessionID: request.sessionID,
            senderAlias: agentSession?.senderAlias,
            messages: (history?.isEmpty == true) ? nil : history,
            attachments: outgoingAttachments
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AgentGatewayError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw AgentGatewayError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw AgentGatewayError.emptyResponse }

        guard let decoded = try? JSONDecoder().decode(AgentGatewayResponse.self, from: data) else {
            throw AgentGatewayError.decodeFailed
        }
        return decoded
    }
}
