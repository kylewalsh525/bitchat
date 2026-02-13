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
    private static var requestCounter: Int = 0

    static func configure(error: Error?) {
        lock.lock()
        responseError = error
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounter
    }

    static func reset() {
        lock.lock()
        responseError = nil
        requestCounter = 0
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
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
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

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CashuMintClientURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}
