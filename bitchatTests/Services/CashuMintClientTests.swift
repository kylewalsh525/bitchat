import XCTest
@testable import bitchat

private final class ProxyRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var proxyIDs: [String] = []

    func append(_ proxyID: String) {
        lock.lock()
        proxyIDs.append(proxyID)
        lock.unlock()
    }

    func allIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return proxyIDs
    }
}

private final class CashuMintClientURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var responseError: Error?
    private static var responseProvider: ((URLRequest) -> (status: Int, body: Data?))?
    private static var requestCounter: Int = 0
    private static var requestedPaths: [String] = []

    static func configure(error: Error?) {
        lock.lock()
        responseError = error
        responseProvider = nil
        lock.unlock()
    }

    static func configure(responseProvider: @escaping (URLRequest) -> (status: Int, body: Data?)) {
        lock.lock()
        responseError = nil
        Self.responseProvider = responseProvider
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounter
    }

    static func allRequestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedPaths
    }

    static func reset() {
        lock.lock()
        responseError = nil
        responseProvider = nil
        requestCounter = 0
        requestedPaths = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCounter += 1
        let error = Self.responseError
        let provider = Self.responseProvider
        if let path = request.url?.path {
            Self.requestedPaths.append(path)
        }
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let provider {
            let response = provider(request)
            let http = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if let body = response.body {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CashuMintClientTests: XCTestCase {
    override func tearDown() {
        CashuMintClientURLProtocolStub.reset()
        super.tearDown()
    }

    func testCheckStateFallsBackToProxyHandlerAfterTransportFailure() async throws {
        CashuMintClientURLProtocolStub.configure(error: URLError(.notConnectedToInternet))
        let client = CashuMintClient(session: makeSession())
        client.configureProxyRequestHandler { request in
            XCTAssertEqual(request.method, .checkstate)
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: true,
                body: "{\"states\":{\"n1\":\"spent\"}}",
                error: nil
            )
        }

        let result = try await client.checkState(mintURL: "https://mint.example", nullifiers: ["n1"])

        XCTAssertEqual(result.stateByNullifier["n1"], "spent")
        XCTAssertEqual(CashuMintClientURLProtocolStub.requestCount(), 1)
    }

    func testSwapThrowsWhenProxyRejectsRequest() async {
        CashuMintClientURLProtocolStub.configure(error: URLError(.notConnectedToInternet))
        let client = CashuMintClient(session: makeSession())
        client.configureProxyRequestHandler { request in
            XCTAssertEqual(request.method, .swap)
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: false,
                body: nil,
                error: "proxy denied"
            )
        }

        let payload = CashuPaymentPayloadEnvelope(
            paymentID: "pay-proxy",
            requestID: "req-proxy",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 42,
            proofs: [CashuProof(amount: 42, secret: "secret-proxy")],
            nullifiers: ["n-proxy"],
            clientNonce: "nonce-proxy",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        do {
            try await client.swap(mintURL: payload.mintURL, payload: payload)
            XCTFail("Expected swap to throw when proxy rejects request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("proxy denied"))
        }
    }

    func testCheckStateUsesStableProxyIDAcrossRetries() async throws {
        CashuMintClientURLProtocolStub.configure(error: URLError(.notConnectedToInternet))
        let client = CashuMintClient(session: makeSession())
        let recorder = ProxyRequestRecorder()
        client.configureProxyRequestHandler { request in
            recorder.append(request.proxyID)
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: true,
                body: "{\"states\":{\"n-stable\":\"spent\"}}",
                error: nil
            )
        }

        _ = try await client.checkState(mintURL: "https://mint.example", nullifiers: ["n-stable"])
        _ = try await client.checkState(mintURL: "https://mint.example", nullifiers: ["n-stable"])

        let ids = recorder.allIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
    }

    func testSwapUsesDifferentProxyIDsForDifferentPayloads() async {
        CashuMintClientURLProtocolStub.configure(error: URLError(.notConnectedToInternet))
        let client = CashuMintClient(session: makeSession())
        let recorder = ProxyRequestRecorder()
        client.configureProxyRequestHandler { request in
            recorder.append(request.proxyID)
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: true,
                body: "{\"ok\":true}",
                error: nil
            )
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let payloadOne = CashuPaymentPayloadEnvelope(
            paymentID: "pay-one",
            requestID: "req-one",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 21,
            proofs: [CashuProof(amount: 21, secret: "secret-one")],
            nullifiers: ["n-one"],
            clientNonce: "nonce-one",
            createdAtMs: nowMs
        )
        let payloadTwo = CashuPaymentPayloadEnvelope(
            paymentID: "pay-two",
            requestID: "req-two",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 34,
            proofs: [CashuProof(amount: 34, secret: "secret-two")],
            nullifiers: ["n-two"],
            clientNonce: "nonce-two",
            createdAtMs: nowMs
        )

        do {
            try await client.swap(mintURL: payloadOne.mintURL, payload: payloadOne)
            try await client.swap(mintURL: payloadTwo.mintURL, payload: payloadTwo)
        } catch {
            XCTFail("Expected proxy fallback swaps to succeed: \(error)")
            return
        }

        let ids = recorder.allIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testSwapStopsLegacyRetryAfterNUT08SchemaError() async {
        CashuMintClientURLProtocolStub.configure { request in
            let body = """
            {"detail":[{"loc":["body","inputs"],"msg":"field required","type":"value_error.missing"},{"loc":["body","outputs"],"msg":"field required","type":"value_error.missing"}]}
            """.data(using: .utf8)
            return (status: 422, body: body)
        }
        let client = CashuMintClient(session: makeSession())
        let payload = CashuPaymentPayloadEnvelope(
            paymentID: "pay-fallback",
            requestID: "req-fallback",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 10,
            // Missing keyset/signature fields forces direct CDK-first path to skip and
            // exercises legacy request fallback handling.
            proofs: [CashuProof(amount: 10, secret: "secret-fallback")],
            nullifiers: ["n-fallback"],
            clientNonce: "nonce-fallback",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        do {
            try await client.swap(mintURL: payload.mintURL, payload: payload)
            XCTFail("Expected swap to throw with malformed proof set")
        } catch {
            // Expected.
        }

        XCTAssertEqual(CashuMintClientURLProtocolStub.requestCount(), 1)
        XCTAssertEqual(CashuMintClientURLProtocolStub.allRequestedPaths(), ["/v1/swap"])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CashuMintClientURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}
