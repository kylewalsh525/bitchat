import XCTest
@testable import BitFoundation
@testable import bitchat

@MainActor
private func makeReliabilityTestViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )
    return (viewModel, transport)
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1.0,
    intervalNs: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNs)
    }
    return condition()
}

final class AgentMeshReliabilityTests: XCTestCase {
    @MainActor
    func testRetryAgentRequestExpiresClearsPendingState() {
        let (viewModel, _) = makeReliabilityTestViewModel()
        let peerID = PeerID(str: "peer-expired")
        let requestID = "req-expired"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        viewModel.pendingAgentRequests[requestID] = ChatViewModel.AgentRequestContext(
            role: "general",
            targetPeerID: peerID,
            targetNickname: "agent",
            sessionID: "sess-1",
            threadID: peerID,
            prompt: "hi",
            attachmentCount: nil,
            senderAlias: "anon",
            quoteID: nil,
            quoteOptionID: nil,
            draftAttachments: [],
            createdAtMs: nowMs - 10_000,
            ttlMs: 1000,
            retriesLeft: 2,
            sentAt: Date().addingTimeInterval(-10)
        )

        viewModel.retryAgentRequest(requestID: requestID)

        XCTAssertNil(viewModel.pendingAgentRequests[requestID])
        let messages = viewModel.privateChats[peerID] ?? []
        XCTAssertTrue(messages.contains(where: { $0.sender == "system" && $0.content.contains("agent request timed out") }))
    }

    @MainActor
    func testRetryAgentRequestEnqueuesWhenUnreachableThenFlushSendsOnReachable() {
        let (viewModel, transport) = makeReliabilityTestViewModel()
        let peerID = PeerID(str: "peer-retry")
        let requestID = "req-retry"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        transport.connectedPeers = []
        transport.reachablePeers = []

        viewModel.pendingAgentRequests[requestID] = ChatViewModel.AgentRequestContext(
            role: "general",
            targetPeerID: peerID,
            targetNickname: "agent",
            sessionID: "sess-1",
            threadID: peerID,
            prompt: "hi",
            attachmentCount: nil,
            senderAlias: "anon",
            quoteID: nil,
            quoteOptionID: nil,
            draftAttachments: [],
            createdAtMs: nowMs,
            ttlMs: 30_000,
            retriesLeft: 2,
            sentAt: Date()
        )

        viewModel.retryAgentRequest(requestID: requestID)
        XCTAssertTrue(transport.sentAgentRequests.isEmpty)

        // Prevent timer leakage in tests.
        viewModel.cancelAgentRequestRetry(requestID: requestID)

        transport.reachablePeers = [peerID]
        viewModel.flushAgentRetryQueue(for: peerID)

        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.requestID, requestID)
        XCTAssertEqual(viewModel.pendingAgentRequests[requestID]?.retriesLeft, 1)

        viewModel.cancelAgentRequestRetry(requestID: requestID)
    }

    @MainActor
    func testResponseIdempotencyResendsCachedResponseOnDuplicateRequestID() async {
        let (viewModel, transport) = makeReliabilityTestViewModel()
        var config = viewModel.agentConfig
        config.enabled = true
        config.role = "general"
        config.modelId = "local"
        viewModel.updateAgentConfig(config)

        let peerID = PeerID(str: "peer-requester")
        let sessionID = "sess-dup"
        let requestID = "req-dup"

        let cached = AgentResponsePacket(
            requestID: requestID,
            content: "cached answer",
            isError: false,
            sessionID: sessionID,
            chunkIndex: nil,
            chunkTotal: nil
        )
        viewModel.cacheAgentResponseIfNeeded(cached, attachments: [])

        let req = AgentRequestPacket(
            requestID: requestID,
            role: "general",
            prompt: "hi",
            sessionID: sessionID,
            attachmentCount: nil,
            senderAlias: "anon",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 30_000
        )
        guard let payload = req.encode() else {
            XCTFail("failed to encode request")
            return
        }

        viewModel.didReceiveNoisePayload(from: peerID, type: .agentRequest, payload: payload, timestamp: Date())

        let didSend = await waitUntil(timeout: 1.0) {
            transport.sentAgentResponses.contains(where: { $0.response.requestID == requestID })
        }
        XCTAssertTrue(didSend)
        XCTAssertEqual(transport.sentAgentResponses.first?.response.content, "cached answer")
    }

    @MainActor
    func testPaymentPromptExpiryClearsPendingPaymentState() {
        let (viewModel, _) = makeReliabilityTestViewModel()
        let peerID = PeerID(str: "peer-pay-expired")
        let requestID = "req-pay-expired"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let threadID = peerID

        let envelope = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-1",
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 1,
            expiresAtMs: nowMs - 1,
            settlementMode: .onlineRequired,
            sessionID: "sess-pay",
            pricingModel: .perRequest,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )

        let response = AgentResponsePacket(
            requestID: requestID,
            content: "",
            isError: false,
            sessionID: envelope.sessionID,
            chunkIndex: nil,
            chunkTotal: nil,
            paymentRequired: true,
            paymentRequest: envelope.encodeString(),
            paymentError: nil
        )

        viewModel.handlePaymentRequiredResponse(
            response: response,
            from: peerID,
            role: "general",
            agentName: "agent",
            threadID: threadID
        )

        XCTAssertNil(viewModel.pendingAgentPayments[requestID])
        let messages = viewModel.privateChats[threadID] ?? []
        XCTAssertTrue(messages.contains(where: { $0.sender == "system" && $0.content.contains("payment request expired") }))
    }
}
