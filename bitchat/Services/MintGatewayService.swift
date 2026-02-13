import Foundation
import BitLogger

actor MintGatewayService {
    private enum CachePolicy {
        case cacheable
        case nonCacheable
    }

    private struct ExecutionOutcome {
        let response: MintProxyResponsePacket
        let cachePolicy: CachePolicy
    }

    enum GatewayError: LocalizedError {
        case invalidProxyID
        case invalidMintURL
        case bodyTooLarge
        case invalidBody
        case responseTooLarge
        case invalidResponseEncoding
        case transport(Error)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidProxyID:
                return "invalid proxy id"
            case .invalidMintURL:
                return "invalid mint url"
            case .bodyTooLarge:
                return "proxy request body exceeds size limit"
            case .invalidBody:
                return "proxy request body must be valid JSON"
            case .responseTooLarge:
                return "mint response body exceeds size limit"
            case .invalidResponseEncoding:
                return "mint response is not valid UTF-8"
            case .transport(let error):
                return error.localizedDescription
            case .malformedResponse:
                return "malformed mint response"
            }
        }
    }

    private struct CacheEntry {
        let response: MintProxyResponsePacket
        let storedAtMs: UInt64
    }

    private let session: URLSession
    private let p2pkService: CashuP2PKServicing
    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []
    private var inflight: [String: Task<ExecutionOutcome, Never>] = [:]

    private let cacheCapacity = TransportConfig.mintGatewayResponseCacheCapacity
    private let cacheTTLms = UInt64(TransportConfig.mintGatewayResponseCacheTTLSeconds * 1000)
    private let timeoutSeconds = TransportConfig.mintGatewayHTTPTimeoutSeconds
    private let maxBodyBytes = TransportConfig.mintGatewayMaxBodyBytes

    init(
        session: URLSession = .shared,
        p2pkService: CashuP2PKServicing = CashuP2PKService()
    ) {
        self.session = session
        self.p2pkService = p2pkService
    }

    func handle(_ request: MintProxyRequestPacket) async -> MintProxyResponsePacket {
        let proxyID = request.proxyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxyID.isEmpty else {
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: false,
                body: nil,
                error: GatewayError.invalidProxyID.localizedDescription
            )
        }

        let nowMs = currentMs()
        prune(nowMs: nowMs)

        if let cached = cache[proxyID] {
            return cached.response
        }
        if let task = inflight[proxyID] {
            return await task.value.response
        }

        let task = Task { [session, p2pkService, timeoutSeconds, maxBodyBytes] in
            if request.method == .relock {
                return await Self.executeRelockRequest(
                    request,
                    p2pkService: p2pkService,
                    timeoutSeconds: timeoutSeconds,
                    maxBodyBytes: maxBodyBytes
                )
            }
            return await Self.executeRequest(
                request,
                session: session,
                timeoutSeconds: timeoutSeconds,
                maxBodyBytes: maxBodyBytes
            )
        }
        inflight[proxyID] = task

        let outcome = await task.value
        inflight.removeValue(forKey: proxyID)
        if outcome.cachePolicy == .cacheable {
            cacheResponse(outcome.response, proxyID: proxyID, nowMs: currentMs())
        }
        return outcome.response
    }

    private func cacheResponse(_ response: MintProxyResponsePacket, proxyID: String, nowMs: UInt64) {
        if cache[proxyID] != nil {
            cacheOrder.removeAll { $0 == proxyID }
        }
        cache[proxyID] = CacheEntry(response: response, storedAtMs: nowMs)
        cacheOrder.append(proxyID)
        trimCache()
    }

    private func trimCache() {
        if cacheOrder.count <= cacheCapacity {
            return
        }
        let overflow = cacheOrder.count - cacheCapacity
        for _ in 0..<overflow {
            guard !cacheOrder.isEmpty else { break }
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func prune(nowMs: UInt64) {
        if cache.isEmpty {
            cacheOrder.removeAll()
            return
        }
        let cutoff = nowMs > cacheTTLms ? (nowMs - cacheTTLms) : 0
        cache = cache.filter { _, entry in entry.storedAtMs >= cutoff }
        var seen = Set<String>()
        cacheOrder = cacheOrder.filter { key in
            guard cache[key] != nil else { return false }
            return seen.insert(key).inserted
        }
        if cacheOrder.count > cacheCapacity {
            trimCache()
        }
    }

    private func currentMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private static func executeRequest(
        _ request: MintProxyRequestPacket,
        session: URLSession,
        timeoutSeconds: TimeInterval,
        maxBodyBytes: Int
    ) async -> ExecutionOutcome {
        let proxyID = request.proxyID
        let mintURLString = request.mintURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: mintURLString) else {
            return failure(proxyID: proxyID, error: GatewayError.invalidMintURL, cachePolicy: .cacheable)
        }

        let route = route(for: request.method)
        let bodyText = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var bodyData: Data?
        if route.requiresBody {
            guard !bodyText.isEmpty else {
                return failure(proxyID: proxyID, error: GatewayError.invalidBody, cachePolicy: .cacheable)
            }
            guard let parsedBody = bodyText.data(using: .utf8), parsedBody.count <= maxBodyBytes else {
                return failure(proxyID: proxyID, error: GatewayError.bodyTooLarge, cachePolicy: .cacheable)
            }
            guard (try? JSONSerialization.jsonObject(with: parsedBody)) != nil else {
                return failure(proxyID: proxyID, error: GatewayError.invalidBody, cachePolicy: .cacheable)
            }
            bodyData = parsedBody
        }

        var errors: [String] = []
        for path in route.paths {
            guard let url = URL(string: path, relativeTo: baseURL) else {
                continue
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = route.httpMethod
            urlRequest.timeoutInterval = timeoutSeconds
            if let bodyData {
                urlRequest.httpBody = bodyData
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw GatewayError.malformedResponse
                }
                guard data.count <= maxBodyBytes else {
                    throw GatewayError.responseTooLarge
                }
                let responseBody: String
                if data.isEmpty {
                    responseBody = ""
                } else if let decoded = String(data: data, encoding: .utf8) {
                    responseBody = decoded
                } else {
                    throw GatewayError.invalidResponseEncoding
                }

                if (200..<300).contains(http.statusCode) {
                    return ExecutionOutcome(
                        response: MintProxyResponsePacket(proxyID: proxyID, ok: true, body: responseBody, error: nil),
                        cachePolicy: .cacheable
                    )
                }
                let compactBody = responseBody.isEmpty ? "" : " \(responseBody)"
                errors.append("\(path) -> HTTP \(http.statusCode)\(compactBody)")
            } catch {
                let errorMessage = (error as? GatewayError)?.localizedDescription ?? error.localizedDescription
                errors.append("\(path) -> \(errorMessage)")
            }
        }

        let joined = errors.joined(separator: " | ")
        let details = joined.isEmpty ? "gateway mint request failed" : joined
        return ExecutionOutcome(
            response: MintProxyResponsePacket(proxyID: proxyID, ok: false, body: nil, error: details),
            cachePolicy: .nonCacheable
        )
    }

    private static func executeRelockRequest(
        _ request: MintProxyRequestPacket,
        p2pkService: CashuP2PKServicing,
        timeoutSeconds: TimeInterval,
        maxBodyBytes: Int
    ) async -> ExecutionOutcome {
        let bodyText = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyText.isEmpty else {
            return failure(proxyID: request.proxyID, error: GatewayError.invalidBody, cachePolicy: .cacheable)
        }
        guard let bodyData = bodyText.data(using: .utf8) else {
            return failure(proxyID: request.proxyID, error: GatewayError.invalidBody, cachePolicy: .cacheable)
        }
        guard bodyData.count <= maxBodyBytes else {
            return failure(proxyID: request.proxyID, error: GatewayError.bodyTooLarge, cachePolicy: .cacheable)
        }
        guard (try? JSONSerialization.jsonObject(with: bodyData)) != nil else {
            return failure(proxyID: request.proxyID, error: GatewayError.invalidBody, cachePolicy: .cacheable)
        }

        let timeoutNs = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
        do {
            let response = try await withThrowingTaskGroup(of: MintProxyResponsePacket.self) { group in
                group.addTask {
                    await p2pkService.executeRelockGatewayRequest(request)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw GatewayError.transport(URLError(.timedOut))
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            return ExecutionOutcome(
                response: response,
                cachePolicy: response.ok ? .cacheable : .nonCacheable
            )
        } catch {
            let errorMessage = (error as? GatewayError)?.localizedDescription ?? error.localizedDescription
            return ExecutionOutcome(
                response: MintProxyResponsePacket(
                    proxyID: request.proxyID,
                    ok: false,
                    body: nil,
                    error: errorMessage
                ),
                cachePolicy: .nonCacheable
            )
        }
    }

    private static func route(for method: MintProxyMethod) -> (httpMethod: String, paths: [String], requiresBody: Bool) {
        switch method {
        case .info:
            return ("GET", ["/v1/info", "/info"], false)
        case .keysets:
            return ("GET", ["/v1/keysets", "/keysets"], false)
        case .swap:
            return ("POST", ["/v1/swap", "/swap"], true)
        case .checkstate:
            return ("POST", ["/v1/checkstate", "/checkstate"], true)
        case .relock:
            return ("POST", ["/v1/swap", "/swap"], true)
        }
    }

    private static func failure(
        proxyID: String,
        error: GatewayError,
        cachePolicy: CachePolicy
    ) -> ExecutionOutcome {
        SecureLogger.warning("MintGatewayService failure: \(error.localizedDescription)", category: .session)
        return ExecutionOutcome(
            response: MintProxyResponsePacket(proxyID: proxyID, ok: false, body: nil, error: error.localizedDescription),
            cachePolicy: cachePolicy
        )
    }
}
