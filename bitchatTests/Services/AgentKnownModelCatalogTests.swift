import XCTest
@testable import bitchat

private final class AgentKnownModelURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (status: Int, body: Data))?

    static func configure(handler: @escaping (URLRequest) throws -> (status: Int, body: Data)) {
        lock.lock()
        Self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
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

final class AgentKnownModelCatalogTests: XCTestCase {
    override func tearDown() {
        AgentKnownModelURLProtocolStub.reset()
        super.tearDown()
    }

    func testResolvePrefersHashOverMatcher() {
        let hexA = String(repeating: "a", count: 64)
        let hexB = String(repeating: "b", count: 64)
        let modelA = AgentKnownModel(id: "m1", name: "Model One", matchers: ["alpha"], hashes: ["sha256:\(hexA)"])
        let modelB = AgentKnownModel(id: "m2", name: "Model Two", matchers: ["beta"], hashes: ["sha256:\(hexB)"])

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overlayURL = tmp.appendingPathComponent("known_models.json")
        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [modelA, modelB])

        let match = catalog.resolve(modelId: "alpha-model", modelHash: "ollama:sha256:\(hexB)")
        XCTAssertEqual(match?.model.id, "m2")
        XCTAssertEqual(match?.kind, .hash)
    }

    func testResolveMatcherWhenNoHashMatch() {
        let modelA = AgentKnownModel(id: "m1", name: "Model One", matchers: ["alpha"], hashes: [])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overlayURL = tmp.appendingPathComponent("known_models.json")
        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [modelA])

        let match = catalog.resolve(modelId: "alpha-model:latest", modelHash: nil)
        XCTAssertEqual(match?.model.id, "m1")
        XCTAssertEqual(match?.kind, .matcher)
    }

    func testResolveReturnsNilWhenUnknown() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overlayURL = tmp.appendingPathComponent("known_models.json")
        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [])
        XCTAssertNil(catalog.resolve(modelId: "mystery", modelHash: nil))
    }

    func testUpdateServiceWritesOverlayAndCatalogLoadsOffline() async throws {
        let hex = String(repeating: "c", count: 64)
        let payload = AgentKnownModelOverlay(
            version: 1,
            models: [
                AgentKnownModel(
                    id: "test",
                    name: "Test Model",
                    matchers: ["test"],
                    hashes: ["ollama:sha256:\(hex)"]
                )
            ]
        )
        let json = try JSONEncoder().encode(payload)

        AgentKnownModelURLProtocolStub.configure { request in
            XCTAssertEqual(request.url?.scheme, "https")
            return (200, json)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentKnownModelURLProtocolStub.self]
        let session = URLSession(configuration: config)

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let overlayURL = tmpDir.appendingPathComponent("known_models.json")

        let defaults = UserDefaults(suiteName: "AgentKnownModelCatalogTests.\(UUID().uuidString)")!
        let updater = AgentKnownModelUpdateService(session: session, overlayURL: overlayURL, defaults: defaults, sizeLimitBytes: 64 * 1024)

        let result = await updater.update(from: "https://example.com/known_models.json")
        guard case .success(let meta) = result else {
            XCTFail("expected update success")
            return
        }
        XCTAssertEqual(meta.modelCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayURL.path))

        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [])
        let match = catalog.resolve(modelId: nil, modelHash: "sha256:\(hex)")
        XCTAssertEqual(match?.model.id, "test")
    }

    func testUpdateServiceRejectsTooLargeResponses() async throws {
        let bigBody = Data(repeating: 0x61, count: 2048)
        AgentKnownModelURLProtocolStub.configure { _ in (200, bigBody) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentKnownModelURLProtocolStub.self]
        let session = URLSession(configuration: config)

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let overlayURL = tmpDir.appendingPathComponent("known_models.json")

        let defaults = UserDefaults(suiteName: "AgentKnownModelCatalogTests.\(UUID().uuidString)")!
        let updater = AgentKnownModelUpdateService(session: session, overlayURL: overlayURL, defaults: defaults, sizeLimitBytes: 32)

        let result = await updater.update(from: "https://example.com/known_models.json")
        if case .success = result {
            XCTFail("expected update failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayURL.path))
    }
}

