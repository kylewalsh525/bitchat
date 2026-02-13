import Foundation

struct X402GatewaySettleResponse: Codable, Equatable {
    let ok: Bool
    let txHash: String?
    let error: String?
    let payerAddress: String?
}

enum X402GatewayError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case decodeFailed
    case gatewayRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid x402 gateway URL"
        case .httpStatus(let code):
            return "x402 gateway HTTP \(code)"
        case .emptyResponse:
            return "x402 gateway empty response"
        case .decodeFailed:
            return "failed to decode x402 gateway response"
        case .gatewayRejected(let reason):
            return reason
        }
    }
}

protocol X402GatewayClienting: AnyObject {
    func settlePayment(
        gatewayURL: String,
        paymentID: String,
        paymentData: String,
        requestID: String,
        token: String?
    ) async throws -> X402GatewaySettleResponse
}

final class X402GatewayClient: X402GatewayClienting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func settlePayment(
        gatewayURL: String,
        paymentID: String,
        paymentData: String,
        requestID: String,
        token: String?
    ) async throws -> X402GatewaySettleResponse {
        guard let url = makeEndpointURL(base: gatewayURL, path: "/x402/settle") else {
            throw X402GatewayError.invalidURL
        }

        struct Body: Codable {
            let paymentID: String
            let paymentData: String
            let requestID: String
        }

        let body = Body(paymentID: paymentID, paymentData: paymentData, requestID: requestID)
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(5, TransportConfig.mintGatewayHTTPTimeoutSeconds)
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw X402GatewayError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else { throw X402GatewayError.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw X402GatewayError.emptyResponse }
        guard let decoded = try? JSONDecoder().decode(X402GatewaySettleResponse.self, from: data) else {
            throw X402GatewayError.decodeFailed
        }
        if decoded.ok == false {
            throw X402GatewayError.gatewayRejected(decoded.error ?? "x402 settlement rejected")
        }
        return decoded
    }

    private func makeEndpointURL(base: String, path: String) -> URL? {
        guard let baseURL = URL(string: base) else { return nil }
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = path
        return components.url
    }
}

