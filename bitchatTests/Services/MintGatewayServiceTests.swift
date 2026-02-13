import XCTest
@testable import bitchat

private final class MintGatewayURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (status: Int, body: Data))?
    private static var requestsSeen: Int = 0

    static func configure(handler: @escaping (URLRequest) throws -> (status: Int, body: Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestsSeen
    }

    static func reset() {
        lock.lock()
        handler = nil
        requestsSeen = 0
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
        Self.requestsSeen += 1
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: result.status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !result.body.isEmpty {
                client?.urlProtocol(self, didLoad: result.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class MintGatewayServiceTests: XCTestCase {
    override func tearDown() {
        MintGatewayURLProtocolStub.reset()
        super.tearDown()
    }

    func testHandleCachesResponseByProxyID() async {
        MintGatewayURLProtocolStub.configure { request in
            XCTAssertEqual(request.url?.path, "/v1/info")
            return (200, Data("{\"name\":\"mint\"}".utf8))
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let request = MintProxyRequestPacket(
            proxyID: "proxy-cache",
            mintURL: "https://mint.example",
            method: .info,
            body: "",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let first = await service.handle(request)
        let second = await service.handle(request)

        XCTAssertTrue(first.ok)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(first.body, second.body)
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 1)
    }

    func testHandleDedupesConcurrentInflightRequests() async {
        MintGatewayURLProtocolStub.configure { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return (200, Data("{\"name\":\"mint\"}".utf8))
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let request = MintProxyRequestPacket(
            proxyID: "proxy-inflight",
            mintURL: "https://mint.example",
            method: .info,
            body: "",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        async let first = service.handle(request)
        async let second = service.handle(request)
        let firstResult = await first
        let secondResult = await second

        XCTAssertTrue(firstResult.ok)
        XCTAssertTrue(secondResult.ok)
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 1)
    }

    func testHandleSwapFallsBackToLegacyPathAfter404() async {
        MintGatewayURLProtocolStub.configure { request in
            if request.url?.path == "/v1/swap" {
                return (404, Data("{\"error\":\"not found\"}".utf8))
            }
            XCTAssertEqual(request.url?.path, "/swap")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Data("{\"ok\":true}".utf8))
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let request = MintProxyRequestPacket(
            proxyID: "proxy-swap",
            mintURL: "https://mint.example",
            method: .swap,
            body: "{\"proofs\":[]}",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let response = await service.handle(request)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.body, "{\"ok\":true}")
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 2)
    }

    func testHandleSwapRejectsInvalidBodyWithoutNetworkCall() async {
        MintGatewayURLProtocolStub.configure { _ in
            XCTFail("network should not be called for invalid swap body")
            return (500, Data())
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let request = MintProxyRequestPacket(
            proxyID: "proxy-invalid",
            mintURL: "https://mint.example",
            method: .swap,
            body: "not-json",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let response = await service.handle(request)

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("valid JSON") == true)
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 0)
    }

    func testHandleDoesNotCacheTransientFailureForSameProxyID() async {
        var attempts = 0
        MintGatewayURLProtocolStub.configure { _ in
            attempts += 1
            if attempts <= 2 {
                throw URLError(.timedOut)
            }
            return (200, Data("{\"ok\":true}".utf8))
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let request = MintProxyRequestPacket(
            proxyID: "proxy-recover",
            mintURL: "https://mint.example",
            method: .swap,
            body: "{\"proofs\":[]}",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let first = await service.handle(request)
        XCTAssertFalse(first.ok)

        let second = await service.handle(request)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 3)
    }

    func testHandleRelockExecutesLocallyWithoutNetwork() async {
        MintGatewayURLProtocolStub.configure { _ in
            XCTFail("network should not be called for relock method")
            return (500, Data())
        }

        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let body = """
        {"requestID":"req-1","paymentID":"pay-1","mintURL":"https://mint.example","unit":"sat","lockPubkey":"abcd","lockSigFlag":1,"proofs":[{"amount":1,"secret":"s1"}]}
        """
        let request = MintProxyRequestPacket(
            proxyID: "proxy-relock",
            mintURL: "https://mint.example",
            method: .relock,
            body: body,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let response = await service.handle(request)
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.body)
        XCTAssertEqual(MintGatewayURLProtocolStub.requestCount(), 0)
    }

    func testHandleRelockFailureIsNotCachedForSameProxyID() async {
        let service = MintGatewayService(session: makeSession(), p2pkService: MockCashuP2PKService())
        let badBody = """
        {"requestID":"req-1","paymentID":"pay-1","mintURL":"https://mint.example","unit":"sat","lockPubkey":"abcd","lockSigFlag":1,"proofs":[]}
        """
        let request = MintProxyRequestPacket(
            proxyID: "proxy-relock-retry",
            mintURL: "https://mint.example",
            method: .relock,
            body: badBody,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        let first = await service.handle(request)
        XCTAssertFalse(first.ok)

        let goodBody = """
        {"requestID":"req-1","paymentID":"pay-1","mintURL":"https://mint.example","unit":"sat","lockPubkey":"abcd","lockSigFlag":1,"proofs":[{"amount":1,"secret":"s1"}]}
        """
        let retry = MintProxyRequestPacket(
            proxyID: "proxy-relock-retry",
            mintURL: "https://mint.example",
            method: .relock,
            body: goodBody,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        let second = await service.handle(retry)
        XCTAssertTrue(second.ok)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MintGatewayURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}
