//
// AgentPaymentBridgeTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

private final class AgentPaymentBridgeMintURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (status: Int, body: Data))?

    static func configure(handler: @escaping (URLRequest) throws -> (status: Int, body: Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
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
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://mint.example")!,
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

private struct MockX402GatewayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class MockX402GatewayClient: X402GatewayClienting {
    var callCount = 0
    var capturedGatewayURL: String?
    var capturedPaymentID: String?
    var capturedRequestID: String?
    var capturedPaymentData: String?
    var result: Result<X402GatewaySettleResponse, Error> = .success(
        X402GatewaySettleResponse(ok: true, txHash: "0xabc", error: nil, payerAddress: "0xpayer")
    )

    func settlePayment(
        gatewayURL: String,
        paymentID: String,
        paymentData: String,
        requestID: String,
        token: String?
    ) async throws -> X402GatewaySettleResponse {
        callCount += 1
        capturedGatewayURL = gatewayURL
        capturedPaymentID = paymentID
        capturedRequestID = requestID
        capturedPaymentData = paymentData
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class MockX402Wallet: X402GuestWalletPaying {
    var payCallCount = 0
    var lastGatewayURL: String?
    var lastPaymentID: String?
    var lastRequestID: String?
    var lastAmount: UInt64?
    var lastChainID: UInt64?
    var lastTokenAddress: String?
    var lastPayTo: String?
    var result: Result<X402WalletPaymentResult, Error> = .success(
        X402WalletPaymentResult(paymentData: "mock-payment-data", payerAddress: "0xpayer")
    )

    func ensureGuestWallet() async throws -> String { "0xpayer" }

    func payX402(
        gatewayURL: String,
        paymentID: String,
        requestID: String,
        amount: UInt64,
        chainID: UInt64,
        tokenAddress: String,
        payTo: String
    ) async throws -> X402WalletPaymentResult {
        payCallCount += 1
        lastGatewayURL = gatewayURL
        lastPaymentID = paymentID
        lastRequestID = requestID
        lastAmount = amount
        lastChainID = chainID
        lastTokenAddress = tokenAddress
        lastPayTo = payTo
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    func linkWallet() async throws {}
    func exportPrivateKey() async throws -> String { "unsupported" }
    func resetWallet() async {}
}

final class AgentPaymentBridgeTests: XCTestCase {
    private var tempDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPaymentBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        storeURL = tempDirectory.appendingPathComponent("payments.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        AgentPaymentBridgeMintURLProtocolStub.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    func testDuplicatePayloadResendsFinalizedReceipt() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-1",
            sessionID: "sess-1",
            paymentID: "pay-1",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        ))
        store.markReceipt(
            requestID: "req-1",
            status: .finalizedOnline,
            details: "settled with mint",
            nullifiers: ["n1"]
        )

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-1",
            sessionID: "sess-1",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-1",
                paymentID: "pay-1",
                nullifiers: ["n1"]
            ),
            sentAt: nowMs,
            clientNonce: "nonce-1"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )

        XCTAssertEqual(receipt.status, .finalizedOnline)
        XCTAssertEqual(receipt.details, "settled with mint")
        XCTAssertEqual(receipt.sessionID, "sess-1")
        XCTAssertEqual(Set(receipt.nullifiers), Set(["n1"]))
    }

    func testCreatePaymentRequestIncludesTrancheMetadata() {
        let store = AgentPaymentStore(storeURL: storeURL)
        let bridge = makeBridge(store: store)
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            priceModel: .perToken,
            pricePerRequest: 0,
            pricePerInputToken: 1,
            pricePerOutputToken: 2,
            minDeposit: 4,
            granularityTokens: 16,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )

        let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-meta",
            sessionID: "sess-meta",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            metadata: AgentPaymentRequestMetadata(
                amountOverride: 37,
                pricingModel: .perToken,
                trancheIndex: 2,
                trancheCount: 5,
                trancheTokenCount: 16,
                outputTokenPrice: 2,
                inputTokenPrice: 1,
                minimumDeposit: 4
            )
        )

        XCTAssertNotNil(paymentRequest)
        guard let paymentRequest,
              let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("expected payment request envelope")
            return
        }
        XCTAssertEqual(envelope.amount, 37)
        XCTAssertEqual(envelope.pricingModel, .perToken)
        XCTAssertEqual(envelope.trancheIndex, 2)
        XCTAssertEqual(envelope.trancheCount, 5)
        XCTAssertEqual(envelope.trancheTokenCount, 16)
        XCTAssertEqual(envelope.outputTokenPrice, 2)
        XCTAssertEqual(envelope.inputTokenPrice, 1)
        XCTAssertEqual(envelope.minimumDeposit, 4)
    }

    func testSessionMismatchIsRejected() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-2",
            sessionID: "sess-expected",
            paymentID: "pay-2",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-2",
            sessionID: "sess-other",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-2",
                paymentID: "pay-2",
                nullifiers: ["n2"]
            ),
            sentAt: nowMs,
            clientNonce: "nonce-2"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "payment session does not match request")
    }

    func testExpiredPaymentIsRejected() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-3",
            sessionID: "sess-3",
            paymentID: "pay-3",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs - 120_000,
            expiresAtMs: nowMs - 1000
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-3",
            sessionID: "sess-3",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-3",
                paymentID: "pay-3",
                nullifiers: ["n3"]
            ),
            sentAt: nowMs,
            clientNonce: "nonce-3"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "payment request expired")
    }

    func testPayloadRequestMismatchIsRejected() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-4",
            sessionID: "sess-4",
            paymentID: "pay-4",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-4",
            sessionID: "sess-4",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-other",
                paymentID: "pay-4",
                nullifiers: ["n4"]
            ),
            sentAt: nowMs,
            clientNonce: "nonce-4"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "payment request does not match original request")
    }

    func testDuplicatePayloadResendsRejectedReceiptDetails() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-5",
            sessionID: "sess-5",
            paymentID: "pay-5",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-5",
            sessionID: "sess-5",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-5",
                paymentID: "pay-5",
                nullifiers: ["n5"],
                mintURL: "https://mint.other"
            ),
            sentAt: nowMs,
            clientNonce: "nonce-5"
        )

        let first = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )
        XCTAssertEqual(first.status, .rejected)
        XCTAssertEqual(first.details, "payment does not match request terms")

        let second = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )
        XCTAssertEqual(second.status, .rejected)
        XCTAssertEqual(second.details, "payment does not match request terms")
    }

    func testOfflineAcceptedPaymentCachesPayloadForLaterFinalization() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        let offlineMint = "http://127.0.0.1:9"
        store.recordPaymentRequest(makeRecord(
            requestID: "req-offline",
            sessionID: "sess-offline",
            paymentID: "pay-offline",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            mintURL: offlineMint,
            settlementMode: .offlineAccepted
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-offline",
            sessionID: "sess-offline",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-offline",
                paymentID: "pay-offline",
                nullifiers: ["n-offline"],
                mintURL: offlineMint
            ),
            sentAt: nowMs,
            clientNonce: "nonce-offline"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: AgentPaymentTerms(
                paymentRail: .cashu,
                settlementMode: .offlineAccepted,
                unit: "sat",
                pricePerRequest: 42,
                acceptedMints: [offlineMint],
                requestTTLSeconds: 120
            )
        )

        XCTAssertEqual(receipt.status, .acceptedOffline)
        let record = store.record(for: "req-offline")
        XCTAssertEqual(record?.state, .acceptedOffline)
        XCTAssertEqual(record?.payload, packet.payload)
        XCTAssertEqual(record?.nullifiers, ["n-offline"])
    }

    func testAmountValidationUsesRecordedRequestAmount() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-amount",
            sessionID: "sess-amount",
            paymentID: "pay-amount",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            amount: 100
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-amount",
            sessionID: "sess-amount",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-amount",
                paymentID: "pay-amount",
                nullifiers: ["n-amount"],
                totalAmount: 42
            ),
            sentAt: nowMs,
            clientNonce: "nonce-amount"
        )

        let permissiveTerms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            pricePerRequest: 1,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: permissiveTerms
        )

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "payment amount is below required price")
    }

    func testMintMismatchIsRejected() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        store.recordPaymentRequest(makeRecord(
            requestID: "req-mint",
            sessionID: "sess-mint",
            paymentID: "pay-mint",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            mintURL: "https://mint.expected"
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-mint",
            sessionID: "sess-mint",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-mint",
                paymentID: "pay-mint",
                nullifiers: ["n-mint"],
                mintURL: "https://mint.other"
            ),
            sentAt: nowMs,
            clientNonce: "nonce-mint"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: makeTerms()
        )

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "payment does not match request terms")
    }

    func testOfflineAcceptedRejectsWhenNotaryThresholdNotMet() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        let offlineMint = "http://127.0.0.1:9"
        store.recordPaymentRequest(makeRecord(
            requestID: "req-notary-reject",
            sessionID: "sess-notary-reject",
            paymentID: "pay-notary-reject",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            mintURL: offlineMint,
            settlementMode: .offlineAccepted
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-notary-reject",
            sessionID: "sess-notary-reject",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-notary-reject",
                paymentID: "pay-notary-reject",
                nullifiers: ["n-notary-reject"],
                mintURL: offlineMint
            ),
            sentAt: nowMs,
            clientNonce: "nonce-notary-reject"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: AgentPaymentTerms(
                paymentRail: .cashu,
                settlementMode: .offlineAccepted,
                unit: "sat",
                pricePerRequest: 42,
                acceptedMints: [offlineMint],
                requestTTLSeconds: 120
            ),
            notaryRequirement: AgentOfflineNotaryRequirement(minimumReceipts: 2, timeoutMs: 100)
        ) { _ in
            ["anr1:only-one"]
        }

        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertTrue(receipt.details?.contains("1/2") == true)
        XCTAssertEqual(store.record(for: "req-notary-reject")?.state, .rejected)
    }

    func testOfflineAcceptedIncludesCollectedNotaryReceipts() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let nowMs = currentMs()
        let offlineMint = "http://127.0.0.1:9"
        store.recordPaymentRequest(makeRecord(
            requestID: "req-notary-ok",
            sessionID: "sess-notary-ok",
            paymentID: "pay-notary-ok",
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            mintURL: offlineMint,
            settlementMode: .offlineAccepted
        ))

        let bridge = makeBridge(store: store)
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-notary-ok",
            sessionID: "sess-notary-ok",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: "req-notary-ok",
                paymentID: "pay-notary-ok",
                nullifiers: ["n-notary-ok"],
                mintURL: offlineMint
            ),
            sentAt: nowMs,
            clientNonce: "nonce-notary-ok"
        )
        let expectedReceipts = ["anr1:notary-a", "anr1:notary-b"]

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: AgentPaymentTerms(
                paymentRail: .cashu,
                settlementMode: .offlineAccepted,
                unit: "sat",
                pricePerRequest: 42,
                acceptedMints: [offlineMint],
                requestTTLSeconds: 120
            ),
            notaryRequirement: AgentOfflineNotaryRequirement(minimumReceipts: 2, timeoutMs: 100)
        ) { _ in
            expectedReceipts
        }

        XCTAssertEqual(receipt.status, .acceptedOffline)
        XCTAssertEqual(Set(receipt.notaryReceipts), Set(expectedReceipts))
        XCTAssertEqual(store.record(for: "req-notary-ok")?.state, .acceptedOffline)
        XCTAssertEqual(Set(store.record(for: "req-notary-ok")?.notaryReceipts ?? []), Set(expectedReceipts))
    }

    func testLockRequiredRejectsMissingToken() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let bridge = makeBridge(store: store)
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            requiresLocking: .p2pk,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["http://127.0.0.1:9"],
            requestTTLSeconds: 120
        )
        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-lock-missing",
            sessionID: "sess-lock-missing",
            peerID: PeerID(str: "peer-A"),
            terms: terms
        ), let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("expected lock-required payment request")
            return
        }

        let packet = AgentPaymentPayloadPacket(
            requestID: envelope.requestID,
            sessionID: "sess-lock-missing",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: envelope.requestID,
                paymentID: envelope.paymentID,
                nullifiers: ["n-lock-missing"],
                mintURL: envelope.mintURL
            ),
            sentAt: currentMs(),
            clientNonce: "nonce-lock-missing"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertTrue((receipt.details ?? "").contains("lock"))
    }

    func testLockRequiredRejectsWrongPubkeyBinding() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let bridge = makeBridge(store: store)
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            requiresLocking: .p2pk,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["http://127.0.0.1:9"],
            requestTTLSeconds: 120
        )
        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-lock-mismatch",
            sessionID: "sess-lock-mismatch",
            peerID: PeerID(str: "peer-A"),
            terms: terms
        ), let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("expected lock-required payment request")
            return
        }

        let packet = AgentPaymentPayloadPacket(
            requestID: envelope.requestID,
            sessionID: "sess-lock-mismatch",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: envelope.requestID,
                paymentID: envelope.paymentID,
                nullifiers: ["n-lock-mismatch"],
                mintURL: envelope.mintURL,
                token: "p2pk:deadbeef",
                requiresLocking: .p2pk,
                lockPubkey: "deadbeef"
            ),
            sentAt: currentMs(),
            clientNonce: "nonce-lock-mismatch"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertTrue((receipt.details ?? "").contains("lock"))
    }

    func testLockRequiredValidPayloadAllowsOfflineAcceptance() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let bridge = makeBridge(store: store)
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            requiresLocking: .p2pk,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["http://127.0.0.1:9"],
            requestTTLSeconds: 120
        )
        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-lock-offline",
            sessionID: "sess-lock-offline",
            peerID: PeerID(str: "peer-A"),
            terms: terms
        ), let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest),
              let lockPubkey = envelope.lockPubkey else {
            XCTFail("expected lock-required payment request")
            return
        }

        let packet = AgentPaymentPayloadPacket(
            requestID: envelope.requestID,
            sessionID: "sess-lock-offline",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: envelope.requestID,
                paymentID: envelope.paymentID,
                nullifiers: ["n-lock-offline"],
                mintURL: envelope.mintURL,
                token: "p2pk:\(lockPubkey)",
                requiresLocking: .p2pk,
                lockPubkey: lockPubkey
            ),
            sentAt: currentMs(),
            clientNonce: "nonce-lock-offline"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms
        )
        XCTAssertEqual(receipt.status, .acceptedOffline)
        XCTAssertEqual(store.record(for: envelope.requestID)?.state, .acceptedOffline)
    }

    func testLockRequiredValidPayloadFinalizesOnlineWhenMintAvailable() async {
        AgentPaymentBridgeMintURLProtocolStub.configure { request in
            XCTAssertEqual(request.url?.path, "/v1/swap")
            return (200, Data("{\"ok\":true}".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentPaymentBridgeMintURLProtocolStub.self]
        let mintClient = CashuMintClient(session: URLSession(configuration: config))

        let store = AgentPaymentStore(storeURL: storeURL)
        let keychain = MockKeychain()
        let defaults = UserDefaults(suiteName: "AgentPaymentBridgeTests.allowlist.\(UUID().uuidString)")!
        let allowlist = CashuMintAllowlistStore(defaults: defaults)
        allowlist.setAllowed(["https://mint.locked"])
        let bridge = AgentPaymentBridge(
            wallet: CashuWalletService(keychain: keychain, allowlist: allowlist),
            mintClient: mintClient,
            store: store,
            lockKeyStore: AgentPaymentLockKeyStore(keychain: keychain),
            p2pkService: MockCashuP2PKService()
        )
        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            requiresLocking: .p2pk,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["https://mint.locked"],
            requestTTLSeconds: 120
        )
        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-lock-online",
            sessionID: "sess-lock-online",
            peerID: PeerID(str: "peer-A"),
            terms: terms
        ), let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest),
              let lockPubkey = envelope.lockPubkey else {
            XCTFail("expected lock-required payment request")
            return
        }

        let packet = AgentPaymentPayloadPacket(
            requestID: envelope.requestID,
            sessionID: "sess-lock-online",
            rail: "cashu",
            payload: makePayloadJSON(
                requestID: envelope.requestID,
                paymentID: envelope.paymentID,
                nullifiers: ["n-lock-online"],
                mintURL: envelope.mintURL,
                token: "p2pk:\(lockPubkey)",
                requiresLocking: .p2pk,
                lockPubkey: lockPubkey
            ),
            sentAt: currentMs(),
            clientNonce: "nonce-lock-online"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms
        )
        XCTAssertEqual(receipt.status, .finalizedOnline)
        XCTAssertEqual(store.record(for: envelope.requestID)?.state, .finalizedOnline)
    }

    func testCreateX402PaymentRequestRequiresFeatureFlag() {
        let store = AgentPaymentStore(storeURL: storeURL)
        let bridge = makeBridge(store: store)
        let terms = AgentPaymentTerms(
            paymentRail: .x402,
            settlementMode: .onlineRequired,
            unit: "usdc",
            priceModel: .perRequest,
            pricePerRequest: 250,
            acceptedMints: [],
            requestTTLSeconds: 90,
            x402ChainID: 8453,
            x402TokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            x402PayTo: "0xfeed00000000000000000000000000000000beef",
            x402GatewayURL: "https://gateway.example",
            x402FacilitatorID: "thirdweb",
            x402Scheme: .exact
        )

        let disabled = bridge.createPaymentRequest(
            requestID: "req-x402-disabled",
            sessionID: "sess-x402",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: false
        )
        XCTAssertNil(disabled)

        let enabled = bridge.createPaymentRequest(
            requestID: "req-x402-enabled",
            sessionID: "sess-x402",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        )
        guard let enabled,
              let envelope = X402PaymentRequestEnvelope.decode(from: enabled) else {
            XCTFail("expected x402 payment request")
            return
        }
        XCTAssertEqual(envelope.requestID, "req-x402-enabled")
        XCTAssertEqual(envelope.chainID, 8453)
        XCTAssertEqual(envelope.tokenAddress, "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        XCTAssertEqual(store.record(for: "req-x402-enabled")?.rail, AgentPaymentRail.x402.rawValue)
    }

    func testPrepareOutboundX402PayloadUsesWalletAndStoresHash() async throws {
        let store = AgentPaymentStore(storeURL: storeURL)
        let wallet = MockX402Wallet()
        let bridge = makeBridge(store: store, x402Wallet: wallet)

        let terms = AgentPaymentTerms(
            paymentRail: .x402,
            settlementMode: .onlineRequired,
            unit: "usdc",
            priceModel: .perRequest,
            pricePerRequest: 111,
            acceptedMints: [],
            requestTTLSeconds: 90,
            x402ChainID: 8453,
            x402TokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            x402PayTo: "0xfeed00000000000000000000000000000000beef",
            x402GatewayURL: "https://gateway.example",
            x402FacilitatorID: "thirdweb",
            x402Scheme: .exact
        )

        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-x402-outbound",
            sessionID: "sess-x402",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        ), let requestEnvelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("expected x402 payment request")
            return
        }

        let packet = try await bridge.prepareOutboundPaymentPayload(
            requestID: requestEnvelope.requestID,
            sessionID: requestEnvelope.sessionID,
            paymentRequest: paymentRequest,
            enableX402Payments: true
        )

        XCTAssertEqual(packet.rail, AgentPaymentRail.x402.rawValue)
        XCTAssertEqual(wallet.payCallCount, 1)
        XCTAssertEqual(wallet.lastGatewayURL, "https://gateway.example")
        XCTAssertEqual(wallet.lastPaymentID, requestEnvelope.paymentID)
        XCTAssertEqual(wallet.lastAmount, 111)

        guard let payloadEnvelope = X402PaymentPayloadEnvelope.decode(from: packet.payload) else {
            XCTFail("expected x402 payload envelope")
            return
        }
        XCTAssertEqual(payloadEnvelope.requestID, requestEnvelope.requestID)
        XCTAssertEqual(payloadEnvelope.paymentID, requestEnvelope.paymentID)

        let expectedHash = x402PaymentRefHash(paymentID: payloadEnvelope.paymentID, paymentData: payloadEnvelope.paymentData)
        let record = store.record(for: requestEnvelope.requestID)
        XCTAssertEqual(record?.state, .payloadSent)
        XCTAssertEqual(record?.nullifiers, [expectedHash])
    }

    func testEvaluateIncomingX402PaymentFinalizesOnlineAndDedupes() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let wallet = MockX402Wallet()
        let gateway = MockX402GatewayClient()
        let bridge = makeBridge(store: store, x402GatewayClient: gateway, x402Wallet: wallet)

        let terms = AgentPaymentTerms(
            paymentRail: .x402,
            settlementMode: .onlineRequired,
            unit: "usdc",
            priceModel: .perRequest,
            pricePerRequest: 75,
            acceptedMints: [],
            requestTTLSeconds: 90,
            x402ChainID: 8453,
            x402TokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            x402PayTo: "0xfeed00000000000000000000000000000000beef",
            x402GatewayURL: "https://gateway.example",
            x402FacilitatorID: "thirdweb",
            x402Scheme: .exact
        )

        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-x402-inbound",
            sessionID: "sess-x402",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        ), let requestEnvelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("expected x402 payment request")
            return
        }

        let payloadEnvelope = X402PaymentPayloadEnvelope(
            paymentID: requestEnvelope.paymentID,
            requestID: requestEnvelope.requestID,
            paymentData: "signed-payment-data",
            payerAddress: "0xabc",
            clientNonce: "nonce-x402",
            createdAtMs: currentMs()
        )
        guard let payload = payloadEnvelope.encodeString() else {
            XCTFail("expected x402 payload")
            return
        }
        let packet = AgentPaymentPayloadPacket(
            requestID: requestEnvelope.requestID,
            sessionID: requestEnvelope.sessionID,
            rail: AgentPaymentRail.x402.rawValue,
            payload: payload,
            sentAt: currentMs(),
            clientNonce: payloadEnvelope.clientNonce
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        )

        XCTAssertEqual(receipt.status, .finalizedOnline)
        XCTAssertTrue(receipt.details?.contains("0xabc") ?? false)
        XCTAssertEqual(gateway.callCount, 1)
        XCTAssertEqual(gateway.capturedGatewayURL, "https://gateway.example")
        XCTAssertEqual(gateway.capturedPaymentID, requestEnvelope.paymentID)

        let expectedHash = x402PaymentRefHash(paymentID: requestEnvelope.paymentID, paymentData: "signed-payment-data")
        XCTAssertEqual(store.record(for: requestEnvelope.requestID)?.state, .finalizedOnline)
        XCTAssertEqual(store.record(for: requestEnvelope.requestID)?.nullifiers, [expectedHash])

        let duplicate = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        )
        XCTAssertEqual(duplicate.status, .finalizedOnline)
        XCTAssertEqual(gateway.callCount, 1)
    }

    func testEvaluateIncomingX402PaymentRejectsGatewayFailure() async {
        let store = AgentPaymentStore(storeURL: storeURL)
        let wallet = MockX402Wallet()
        let gateway = MockX402GatewayClient()
        gateway.result = .failure(MockX402GatewayError(message: "upstream rejected"))
        let bridge = makeBridge(store: store, x402GatewayClient: gateway, x402Wallet: wallet)

        let terms = AgentPaymentTerms(
            paymentRail: .x402,
            settlementMode: .onlineRequired,
            unit: "usdc",
            priceModel: .perRequest,
            pricePerRequest: 75,
            acceptedMints: [],
            requestTTLSeconds: 90,
            x402ChainID: 8453,
            x402TokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            x402PayTo: "0xfeed00000000000000000000000000000000beef",
            x402GatewayURL: "https://gateway.example",
            x402FacilitatorID: "thirdweb",
            x402Scheme: .exact
        )

        guard let paymentRequest = bridge.createPaymentRequest(
            requestID: "req-x402-reject",
            sessionID: "sess-x402",
            peerID: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        ), let requestEnvelope = X402PaymentRequestEnvelope.decode(from: paymentRequest),
              let payload = X402PaymentPayloadEnvelope(
                paymentID: requestEnvelope.paymentID,
                requestID: requestEnvelope.requestID,
                paymentData: "rejected-data",
                payerAddress: "0xabc",
                clientNonce: "nonce-reject",
                createdAtMs: currentMs()
              ).encodeString() else {
            XCTFail("expected x402 request/payload")
            return
        }

        let packet = AgentPaymentPayloadPacket(
            requestID: requestEnvelope.requestID,
            sessionID: requestEnvelope.sessionID,
            rail: AgentPaymentRail.x402.rawValue,
            payload: payload,
            sentAt: currentMs(),
            clientNonce: "nonce-reject"
        )

        let receipt = await bridge.evaluateIncomingPayment(
            packet: packet,
            from: PeerID(str: "peer-A"),
            terms: terms,
            enableX402Payments: true
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(receipt.details, "upstream rejected")
        XCTAssertEqual(store.record(for: requestEnvelope.requestID)?.state, .rejected)
    }

    private func makeBridge(
        store: AgentPaymentStore,
        x402GatewayClient: X402GatewayClienting = X402GatewayClient(),
        x402Wallet: X402GuestWalletPaying? = nil
    ) -> AgentPaymentBridge {
        let keychain = MockKeychain()
        let defaults = UserDefaults(suiteName: "AgentPaymentBridgeTests.allowlist.\(UUID().uuidString)")!
        let allowlist = CashuMintAllowlistStore(defaults: defaults)
        allowlist.setAllowed(["https://mint.example"])
        let wallet = CashuWalletService(keychain: keychain, allowlist: allowlist)
        let mintClient = CashuMintClient()
        let lockKeyStore = AgentPaymentLockKeyStore(keychain: keychain)
        return AgentPaymentBridge(
            wallet: wallet,
            mintClient: mintClient,
            store: store,
            lockKeyStore: lockKeyStore,
            p2pkService: MockCashuP2PKService(),
            x402GatewayClient: x402GatewayClient,
            x402Wallet: x402Wallet
        )
    }

    private func makeTerms() -> AgentPaymentTerms {
        AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )
    }

    private func makeRecord(
        requestID: String,
        sessionID: String,
        paymentID: String,
        state: AgentPaymentState,
        details: String?,
        createdAtMs: UInt64,
        expiresAtMs: UInt64,
        mintURL: String = "https://mint.example",
        unit: String = "sat",
        amount: UInt64 = 42,
        settlementMode: AgentSettlementMode = .onlineRequired
    ) -> AgentPaymentRecord {
        AgentPaymentRecord(
            requestID: requestID,
            sessionID: sessionID,
            peerID: "peer-A",
            paymentID: paymentID,
            rail: "cashu",
            mintURL: mintURL,
            unit: unit,
            amount: amount,
            settlementMode: settlementMode,
            requiresLocking: AgentPaymentLockingMode.none,
            lockPubkey: nil,
            lockSigFlag: nil,
            paymentRequest: "creq:test",
            payload: nil,
            nullifiers: [],
            notaryReceipts: [],
            state: state,
            details: details,
            createdAtMs: createdAtMs,
            updatedAtMs: createdAtMs,
            expiresAtMs: expiresAtMs
        )
    }

    private func makePayloadJSON(
        requestID: String,
        paymentID: String,
        nullifiers: [String],
        mintURL: String = "https://mint.example",
        unit: String = "sat",
        totalAmount: UInt64 = 42,
        token: String? = nil,
        requiresLocking: AgentPaymentLockingMode? = nil,
        lockPubkey: String? = nil
    ) -> String {
        let payload = CashuPaymentPayloadEnvelope(
            paymentID: paymentID,
            requestID: requestID,
            mintURL: mintURL,
            unit: unit,
            totalAmount: totalAmount,
            proofs: [CashuProof(amount: 42, secret: "secret-\(paymentID)")],
            token: token,
            requiresLocking: requiresLocking,
            lockPubkey: lockPubkey,
            nullifiers: nullifiers,
            clientNonce: "nonce-\(paymentID)",
            createdAtMs: currentMs()
        )
        return payload.toJSONString()!
    }

    private func currentMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
