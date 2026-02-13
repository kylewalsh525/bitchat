import Foundation

final class CashuMintClient {
    typealias ProxyRequestHandler = @Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket

    enum MintError: LocalizedError {
        case invalidURL
        case transport(Error)
        case badStatus(Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "invalid mint url"
            case .transport(let error):
                return error.localizedDescription
            case .badStatus(let status, let body):
                if body.isEmpty { return "mint request failed with status \(status)" }
                return "mint request failed (\(status)): \(body)"
            case .malformedResponse:
                return "malformed mint response"
            }
        }
    }

    struct MintInfo: Codable, Equatable {
        let name: String?
        let pubkey: String?
        let version: String?
    }

    struct CheckStateResult: Codable, Equatable {
        let stateByNullifier: [String: String]
    }

    private let session: URLSession
    private let proxyHandlerLock = NSLock()
    private var proxyRequestHandler: ProxyRequestHandler?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configureProxyRequestHandler(_ handler: ProxyRequestHandler?) {
        proxyHandlerLock.lock()
        proxyRequestHandler = handler
        proxyHandlerLock.unlock()
    }

    func info(mintURL: String) async throws -> MintInfo {
        let response = try await performRequest(
            mintURL: mintURL,
            method: "GET",
            candidatePaths: ["/v1/info", "/info"],
            body: nil
        )
        return (try? JSONDecoder().decode(MintInfo.self, from: response.data)) ?? MintInfo(name: nil, pubkey: nil, version: nil)
    }

    func swap(mintURL: String, payload: CashuPaymentPayloadEnvelope) async throws {
        let body = [
            "payment_id": payload.paymentID,
            "request_id": payload.requestID,
            "unit": payload.unit,
            "amount": payload.totalAmount,
            "proofs": payload.proofs.map {
                [
                    "id": $0.id as Any,
                    "amount": $0.amount,
                    "secret": $0.secret,
                    "C": $0.C as Any,
                    "witness": $0.witness as Any
                ]
            }
        ] as [String: Any]
        _ = try await performRequest(
            mintURL: mintURL,
            method: "POST",
            candidatePaths: ["/v1/swap", "/swap"],
            body: body
        )
    }

    func checkState(mintURL: String, nullifiers: [String]) async throws -> CheckStateResult {
        let response = try await performRequest(
            mintURL: mintURL,
            method: "POST",
            candidatePaths: ["/v1/checkstate", "/checkstate"],
            body: ["nullifiers": nullifiers]
        )

        if let parsed = try? JSONDecoder().decode(CheckStateResult.self, from: response.data) {
            return parsed
        }

        if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
           let states = object["states"] as? [String: String] {
            return CheckStateResult(stateByNullifier: states)
        }

        throw MintError.malformedResponse
    }

    private func performRequest(
        mintURL: String,
        method: String,
        candidatePaths: [String],
        body: [String: Any]?
    ) async throws -> (data: Data, status: Int) {
        guard let baseURL = URL(string: mintURL) else { throw MintError.invalidURL }

        let proxyHandler = currentProxyRequestHandler()
        let proxyMethod = mintProxyMethod(for: method, candidatePaths: candidatePaths)
        let bodyJSON = try bodyJSONString(from: body)

        var lastError: Error?
        for path in candidatePaths {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            if body != nil {
                request.httpBody = bodyJSON
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw MintError.malformedResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    throw MintError.badStatus(http.statusCode, body: bodyText)
                }
                return (data, http.statusCode)
            } catch {
                lastError = error
                if proxyHandler != nil {
                    if let mintError = error as? MintError {
                        if case .badStatus = mintError {
                            continue
                        }
                        break
                    } else {
                        break
                    }
                }
                continue
            }
        }

        if let proxyHandler, let proxyMethod {
            do {
                let proxyID = stableProxyID(
                    mintURL: mintURL,
                    method: proxyMethod,
                    candidatePaths: candidatePaths,
                    bodyJSON: bodyJSON
                )
                let proxyRequest = MintProxyRequestPacket(
                    proxyID: proxyID,
                    mintURL: mintURL,
                    method: proxyMethod,
                    body: bodyJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                    sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
                )
                let proxyResponse = try await proxyHandler(proxyRequest)
                guard proxyResponse.ok else {
                    throw MintError.badStatus(502, body: proxyResponse.error ?? "mint gateway rejected request")
                }
                let responseBody = proxyResponse.body ?? ""
                if responseBody.utf8.count > TransportConfig.mintGatewayMaxBodyBytes {
                    throw MintError.badStatus(502, body: "mint gateway response too large")
                }
                let data = Data(responseBody.utf8)
                return (data, 200)
            } catch {
                lastError = error
            }
        }

        if let mintError = lastError as? MintError {
            throw mintError
        }
        if let lastError {
            throw MintError.transport(lastError)
        }
        throw MintError.invalidURL
    }

    private func currentProxyRequestHandler() -> ProxyRequestHandler? {
        proxyHandlerLock.lock()
        let handler = proxyRequestHandler
        proxyHandlerLock.unlock()
        return handler
    }

    private func bodyJSONString(from body: [String: Any]?) throws -> Data? {
        guard let body else { return nil }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func mintProxyMethod(for method: String, candidatePaths: [String]) -> MintProxyMethod? {
        let lowerMethod = method.lowercased()
        let joined = candidatePaths.joined(separator: "|").lowercased()
        if joined.contains("checkstate") {
            return .checkstate
        }
        if joined.contains("keysets") {
            return .keysets
        }
        if joined.contains("info") && lowerMethod == "get" {
            return .info
        }
        if lowerMethod == "post" {
            return .swap
        }
        return nil
    }

    private func stableProxyID(
        mintURL: String,
        method: MintProxyMethod,
        candidatePaths: [String],
        bodyJSON: Data?
    ) -> String {
        let canonicalMint = mintURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonicalPaths = candidatePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        let bodyDigest = bodyJSON?.sha256Fingerprint() ?? "none"
        let canonical = "mintProxy:v1|\(method.rawValue)|\(canonicalMint)|\(canonicalPaths)|\(bodyDigest)"
        let digest = Data(canonical.utf8).sha256Fingerprint()
        return "proxy-\(method.rawValue)-\(String(digest.prefix(24)))"
    }
}
