//
// ChatViewModelPaymentsTests.swift
// bitchatTests
//

import XCTest
@testable import BitFoundation
@testable import bitchat

@MainActor
private func makePaymentTestViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
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
    viewModel.cashuMintAllowlistStore.setAllowed(["https://mint.example"])
    return (viewModel, transport)
}

private func makeGatewayCandidate(peerID: String, connected: Bool = true, reachable: Bool = true) -> BitchatPeer {
    BitchatPeer(
        peerID: PeerID(str: peerID),
        noisePublicKey: Data(repeating: 0x01, count: 32),
        nickname: peerID,
        lastSeen: Date(),
        isConnected: connected,
        isReachable: reachable,
        agentInfo: nil
    )
}

private func makePerRequestPaymentTerms(price: UInt64) -> AgentPaymentTerms {
    AgentPaymentTerms(
        paymentRail: .cashu,
        settlementMode: .offlineAccepted,
        unit: "sat",
        priceModel: .perRequest,
        pricePerRequest: price,
        acceptedMints: ["https://mint.example"],
        requestTTLSeconds: 90
    )
}

private func makeQuoteProviderPeer(
    peerID: String,
    role: String = "general",
    modelId: String = "llama3",
    qualityScore: UInt8 = 75,
    perRequestPrice: UInt64 = 100
) -> BitchatPeer {
    let seed = peerID.utf8.reduce(0) { partial, byte in
        partial + Int(byte)
    }
    let noiseByte = UInt8((seed % 250) + 1)
    let hash = String(repeating: "a", count: 64)
    let info = AgentInfo(
        role: role,
        modelId: modelId,
        qualityScore: qualityScore,
        modelHash: "ollama:sha256:\(hash)",
        paymentTerms: makePerRequestPaymentTerms(price: perRequestPrice)
    )
    return BitchatPeer(
        peerID: PeerID(str: peerID),
        noisePublicKey: Data(repeating: noiseByte, count: 32),
        nickname: peerID,
        lastSeen: Date(),
        isConnected: true,
        isReachable: true,
        agentInfo: info
    )
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

private func makePaymentPayloadPacket(
    envelope: CashuPaymentRequestEnvelope,
    sessionID: String,
    nullifierSuffix: String
) -> AgentPaymentPayloadPacket {
    let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
    let nullifier = "n-\(nullifierSuffix)-\(envelope.paymentID)"
    let payload = CashuPaymentPayloadEnvelope(
        paymentID: envelope.paymentID,
        requestID: envelope.requestID,
        mintURL: envelope.mintURL,
        unit: envelope.unit,
        totalAmount: envelope.amount,
        proofs: [CashuProof(amount: envelope.amount, secret: "secret-\(envelope.paymentID)")],
        nullifiers: [nullifier],
        clientNonce: "nonce-\(nullifierSuffix)",
        createdAtMs: nowMs
    )

    return AgentPaymentPayloadPacket(
        requestID: envelope.requestID,
        sessionID: sessionID,
        rail: "cashu",
        payload: payload.toJSONString() ?? "{}",
        sentAt: nowMs,
        clientNonce: "nonce-\(nullifierSuffix)"
    )
}

final class ChatViewModelPaymentsTests: XCTestCase {
    @MainActor
    func testDispatchAgentRequestUsesQuoteDiscoveryForPerRequestProviders() {
        let (viewModel, transport) = makePaymentTestViewModel()
        let providerA = makeQuoteProviderPeer(peerID: "quote-provider-a", perRequestPrice: 100)
        let providerB = makeQuoteProviderPeer(peerID: "quote-provider-b", perRequestPrice: 140)
        viewModel.allPeers = [providerA, providerB]

        let result = viewModel.dispatchAgentRequest(role: "general", prompt: "hello")

        switch result {
        case .success(let message):
            XCTAssertTrue(message?.localizedCaseInsensitiveContains("collecting quotes") == true)
        case .error(let message):
            XCTFail("unexpected dispatch error: \(message)")
        case .handled:
            XCTFail("unexpected handled result")
        }
        XCTAssertEqual(transport.sentAgentQuoteRequests.count, 2)
        XCTAssertEqual(transport.sentAgentRequests.count, 0)
    }

    @MainActor
    func testAgentChooseSendsQuotedRequestWithSelectedOption() {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.agentRequesterPreferences.quoteAutoPickPolicy = .manual
        let provider = makeQuoteProviderPeer(peerID: "quote-provider")
        viewModel.allPeers = [provider]

        let dispatchResult = viewModel.dispatchAgentRequest(role: "general", prompt: "hello")
        if case .error(let message) = dispatchResult {
            XCTFail("unexpected dispatch error: \(message)")
            return
        }
        XCTAssertEqual(transport.sentAgentQuoteRequests.count, 1)
        guard let sentQuote = transport.sentAgentQuoteRequests.first?.request else {
            XCTFail("expected one quote request")
            return
        }

        let option = AgentQuoteOption(
            optionID: "\(sentQuote.quoteID)-immediate-\(provider.peerID.id.prefix(6))",
            label: "immediate",
            waitSeconds: 0,
            discountBps: 0,
            estimatedPrice: 99,
            unit: "sat",
            settlementMode: .offlineAccepted,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 90,
            qualityScore: 80,
            modelId: "llama3",
            modelHash: "ollama:sha256:\(String(repeating: "b", count: 64))"
        )
        viewModel.handleAgentQuoteResponse(
            AgentQuoteResponsePacket(
                quoteID: sentQuote.quoteID,
                role: "general",
                options: [option],
                expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) + 20_000,
                error: nil
            ),
            from: provider.peerID
        )

        let chooseResult = viewModel.handleAgentChooseCommand("/agentchoose \(sentQuote.quoteID) 1")
        if case .error(let message) = chooseResult {
            XCTFail("unexpected choose error: \(message)")
            return
        }

        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.peerID, provider.peerID)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteID, sentQuote.quoteID)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteOptionID, option.optionID)
    }

    @MainActor
    func testAgentChooseDelayedTierDefersSendUntilWaitWindow() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.agentRequesterPreferences.quoteAutoPickPolicy = .manual
        let provider = makeQuoteProviderPeer(peerID: "quote-provider-delay")
        viewModel.allPeers = [provider]

        let dispatchResult = viewModel.dispatchAgentRequest(role: "general", prompt: "hello")
        if case .error(let message) = dispatchResult {
            XCTFail("unexpected dispatch error: \(message)")
            return
        }
        guard let sentQuote = transport.sentAgentQuoteRequests.first?.request else {
            XCTFail("expected one quote request")
            return
        }

        let delayedOption = AgentQuoteOption(
            optionID: "\(sentQuote.quoteID)-delayed-\(provider.peerID.id.prefix(6))",
            label: "wait ~1s",
            waitSeconds: 1,
            discountBps: 1000,
            estimatedPrice: 70,
            unit: "sat",
            settlementMode: .offlineAccepted,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 90,
            qualityScore: 80,
            modelId: "llama3",
            modelHash: "ollama:sha256:\(String(repeating: "c", count: 64))"
        )
        viewModel.handleAgentQuoteResponse(
            AgentQuoteResponsePacket(
                quoteID: sentQuote.quoteID,
                role: "general",
                options: [delayedOption],
                expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) + 20_000,
                error: nil
            ),
            from: provider.peerID
        )

        let chooseResult = viewModel.handleAgentChooseCommand("/agentchoose \(sentQuote.quoteID) 1")
        if case .error(let message) = chooseResult {
            XCTFail("unexpected choose error: \(message)")
            return
        }

        XCTAssertEqual(transport.sentAgentRequests.count, 0)
        let sentAfterDelay = await waitUntil(timeout: 1.6, intervalNs: 20_000_000) {
            transport.sentAgentRequests.count == 1
        }
        XCTAssertTrue(sentAfterDelay)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteOptionID, delayedOption.optionID)
    }

    @MainActor
    func testTapQuoteSelectionSendsQuotedRequest() {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.agentRequesterPreferences.quoteAutoPickPolicy = .manual
        let provider = makeQuoteProviderPeer(peerID: "quote-provider-tap")
        viewModel.allPeers = [provider]

        _ = viewModel.dispatchAgentRequest(role: "general", prompt: "hello")
        guard let sentQuote = transport.sentAgentQuoteRequests.first?.request else {
            XCTFail("expected one quote request")
            return
        }

        let option = AgentQuoteOption(
            optionID: "\(sentQuote.quoteID)-immediate-\(provider.peerID.id.prefix(6))",
            label: "immediate",
            waitSeconds: 0,
            discountBps: 0,
            estimatedPrice: 105,
            unit: "sat",
            settlementMode: .offlineAccepted,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 90,
            qualityScore: 82,
            modelId: "llama3",
            modelHash: "ollama:sha256:\(String(repeating: "d", count: 64))"
        )
        viewModel.handleAgentQuoteResponse(
            AgentQuoteResponsePacket(
                quoteID: sentQuote.quoteID,
                role: "general",
                options: [option],
                expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) + 20_000,
                error: nil
            ),
            from: provider.peerID
        )

        let result = viewModel.selectAgentQuoteOptionFromUI(quoteID: sentQuote.quoteID, optionID: option.optionID)
        if case .error(let message) = result {
            XCTFail("unexpected tap select error: \(message)")
            return
        }

        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.peerID, provider.peerID)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteID, sentQuote.quoteID)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteOptionID, option.optionID)
    }

    @MainActor
    func testQuoteAutoPickCheapestSendsWithoutChooseCommand() {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.agentRequesterPreferences.quoteAutoPickPolicy = .cheapest
        let provider = makeQuoteProviderPeer(peerID: "quote-provider-autopick")
        viewModel.allPeers = [provider]

        _ = viewModel.dispatchAgentRequest(role: "general", prompt: "hello")
        guard let sentQuote = transport.sentAgentQuoteRequests.first?.request else {
            XCTFail("expected one quote request")
            return
        }

        let expensive = AgentQuoteOption(
            optionID: "\(sentQuote.quoteID)-expensive-\(provider.peerID.id.prefix(6))",
            label: "immediate",
            waitSeconds: 0,
            discountBps: 0,
            estimatedPrice: 180,
            unit: "sat",
            settlementMode: .offlineAccepted,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 90,
            qualityScore: 90,
            modelId: "llama3",
            modelHash: nil
        )
        let cheap = AgentQuoteOption(
            optionID: "\(sentQuote.quoteID)-cheap-\(provider.peerID.id.prefix(6))",
            label: "wait ~15s",
            waitSeconds: 0,
            discountBps: 2500,
            estimatedPrice: 80,
            unit: "sat",
            settlementMode: .offlineAccepted,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 90,
            qualityScore: 70,
            modelId: "llama3",
            modelHash: nil
        )

        viewModel.handleAgentQuoteResponse(
            AgentQuoteResponsePacket(
                quoteID: sentQuote.quoteID,
                role: "general",
                options: [expensive, cheap],
                expiresAt: UInt64(Date().timeIntervalSince1970 * 1000) + 20_000,
                error: nil
            ),
            from: provider.peerID
        )

        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.request.quoteOptionID, cheap.optionID)
        XCTAssertTrue(viewModel.pendingAgentQuoteSelections[sentQuote.quoteID] == nil)
        XCTAssertTrue(viewModel.activeAgentQuoteSelections.isEmpty)
    }

    @MainActor
    func testQuoteSelectionExpiresAndRestoresDraftAttachments() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        _ = transport
        let provider = makeQuoteProviderPeer(peerID: "quote-provider-expiry")
        viewModel.allPeers = [provider]

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quote-expiry-\(UUID().uuidString).jpg")
        try? Data([0x01, 0x02]).write(to: tempURL)
        viewModel.queueDraftImage(url: tempURL, for: nil)
        XCTAssertEqual(viewModel.draftAttachments(for: nil).count, 1)

        viewModel.stashPendingAgentDraftAttachmentsForCommand()
        let result = viewModel.beginAgentQuoteSelectionIfNeeded(
            role: "general",
            prompt: "hello",
            promptWithMemory: "hello",
            allowAnyRole: true,
            ttlOverrideMs: 80
        )
        if case .error(let message) = result {
            XCTFail("unexpected quote begin error: \(message)")
            return
        }

        XCTAssertTrue(viewModel.draftAttachments(for: nil).isEmpty)
        XCTAssertEqual(viewModel.pendingAgentQuoteSelections.count, 1)

        let expired = await waitUntil(timeout: 0.8) {
            viewModel.pendingAgentQuoteSelections.isEmpty
        }
        XCTAssertTrue(expired)
        XCTAssertEqual(viewModel.draftAttachments(for: nil).count, 1)
    }

    @MainActor
    func testProviderQuoteRequestUsesConfiguredTierPolicy() {
        let (viewModel, transport) = makePaymentTestViewModel()
        var config = viewModel.agentConfig
        config.enabled = true
        config.role = "general"
        config.modelId = "llama3"
        config.qualityScore = 80
        config.paymentTerms = makePerRequestPaymentTerms(price: 200)
        config.quoteTierPolicy = AgentQuoteTierPolicy(
            immediateDiscountBps: 500,
            standardWaitSeconds: 25,
            standardDiscountBps: 2_000,
            economyWaitSeconds: 90,
            economyDiscountBps: 4_000
        )
        viewModel.updateAgentConfig(config)

        viewModel.handleAgentQuoteRequest(
            AgentQuoteRequestPacket(
                quoteID: "quote-custom-tier",
                role: "general",
                prompt: "quote please",
                estimatedInputTokens: 32,
                estimatedOutputTokens: 64,
                sentAt: UInt64(Date().timeIntervalSince1970 * 1000),
                maxOptions: 3
            ),
            from: PeerID(str: "peer-requester")
        )

        guard let response = transport.sentAgentQuoteResponses.first?.response else {
            XCTFail("expected quote response")
            return
        }
        XCTAssertEqual(response.options.count, 3)
        XCTAssertEqual(response.options[0].waitSeconds, 0)
        XCTAssertEqual(response.options[0].estimatedPrice, 190)
        XCTAssertEqual(response.options[1].waitSeconds, 25)
        XCTAssertEqual(response.options[1].estimatedPrice, 160)
        XCTAssertEqual(response.options[2].waitSeconds, 90)
        XCTAssertEqual(response.options[2].estimatedPrice, 120)
    }

    @MainActor
    func testProviderQuoteValidationAcceptsKnownOptionAndRejectsUnknownOption() {
        let (viewModel, transport) = makePaymentTestViewModel()
        var config = viewModel.agentConfig
        config.enabled = true
        config.role = "general"
        config.modelId = "llama3"
        config.qualityScore = 80
        config.paymentTerms = makePerRequestPaymentTerms(price: 200)
        viewModel.updateAgentConfig(config)

        let requester = PeerID(str: "peer-requester")
        let quoteRequest = AgentQuoteRequestPacket(
            quoteID: "quote-validation",
            role: "general",
            prompt: "please quote",
            estimatedInputTokens: 32,
            estimatedOutputTokens: 64,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000),
            maxOptions: 3
        )
        viewModel.handleAgentQuoteRequest(quoteRequest, from: requester)

        XCTAssertEqual(transport.sentAgentQuoteResponses.count, 1)
        guard let response = transport.sentAgentQuoteResponses.first?.response,
              let optionID = response.options.first?.optionID,
              let expectedAmount = response.options.first?.estimatedPrice else {
            XCTFail("expected quote response with at least one option")
            return
        }

        let validRequest = AgentRequestPacket(
            requestID: "req-valid-quote",
            role: "general",
            prompt: "run this",
            sessionID: "sess-quote",
            attachmentCount: nil,
            senderAlias: "anon-test",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 30_000,
            quoteID: quoteRequest.quoteID,
            quoteOptionID: optionID
        )
        let valid = viewModel.quotedAmountOverrideValidation(request: validRequest, from: requester)
        XCTAssertEqual(valid.amount, expectedAmount)
        XCTAssertNil(valid.error)

        let invalidRequest = AgentRequestPacket(
            requestID: "req-invalid-quote",
            role: "general",
            prompt: "run this",
            sessionID: "sess-quote",
            attachmentCount: nil,
            senderAlias: "anon-test",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 30_000,
            quoteID: quoteRequest.quoteID,
            quoteOptionID: "missing-option"
        )
        let invalid = viewModel.quotedAmountOverrideValidation(request: invalidRequest, from: requester)
        XCTAssertNil(invalid.amount)
        XCTAssertEqual(invalid.error, "quote option not found")

        if let delayedOption = response.options.first(where: { $0.waitSeconds > 0 }) {
            let delayedRequest = AgentRequestPacket(
                requestID: "req-delayed-quote",
                role: "general",
                prompt: "run this",
                sessionID: "sess-quote",
                attachmentCount: nil,
                senderAlias: "anon-test",
                createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
                ttlMs: 30_000,
                quoteID: quoteRequest.quoteID,
                quoteOptionID: delayedOption.optionID
            )
            let delayedValidation = viewModel.quotedAmountOverrideValidation(request: delayedRequest, from: requester)
            XCTAssertNil(delayedValidation.amount)
            XCTAssertEqual(delayedValidation.error, "quote wait window not reached")
            XCTAssertEqual(delayedValidation.waitSeconds, delayedOption.waitSeconds)
        }
    }

    @MainActor
    func testMintProxyMeshRequestResolvesWhenMatchingResponseArrives() async throws {
        let (viewModel, transport) = makePaymentTestViewModel()
        let gatewayPeer = makeGatewayCandidate(peerID: "gateway-a")
        viewModel.agentMeshFlags.enableGateway = true
        transport.connectedPeers = [gatewayPeer.peerID]
        transport.reachablePeers = [gatewayPeer.peerID]
        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: gatewayPeer.peerID,
                nickname: gatewayPeer.nickname,
                isConnected: true,
                noisePublicKey: gatewayPeer.noisePublicKey,
                lastSeen: gatewayPeer.lastSeen,
                agentInfo: gatewayPeer.agentInfo
            )
        ])
        _ = await waitUntil {
            viewModel.allPeers.contains(where: { $0.peerID == gatewayPeer.peerID })
        }

        let request = MintProxyRequestPacket(
            proxyID: "proxy-success",
            mintURL: "https://mint.example",
            method: .info,
            body: "",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let pending = Task {
            try await viewModel.requestMintProxyViaMesh(request)
        }
        let didSendRequest = await waitUntil { transport.sentMintProxyRequests.count == 1 }
        if !didSendRequest {
            do {
                _ = try await pending.value
                XCTFail("expected mint proxy request to remain pending")
            } catch {
                XCTFail("mint proxy request failed before send: \(error)")
            }
            return
        }

        XCTAssertEqual(transport.sentMintProxyRequests.count, 1)
        guard transport.sentMintProxyRequests.count == 1 else {
            XCTFail("expected one mint proxy request to be sent")
            pending.cancel()
            return
        }
        XCTAssertEqual(transport.sentMintProxyRequests[0].request.proxyID, "proxy-success")
        XCTAssertEqual(transport.sentMintProxyRequests[0].peerID, gatewayPeer.peerID)

        viewModel.handleMintProxyResponse(
            MintProxyResponsePacket(
                proxyID: "proxy-success",
                ok: true,
                body: "{\"name\":\"mint\"}",
                error: nil
            ),
            from: gatewayPeer.peerID
        )

        let result = try await pending.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.body, "{\"name\":\"mint\"}")
    }

    @MainActor
    func testMintProxyMeshRequestRetriesNextPeerAfterRejection() async throws {
        let (viewModel, transport) = makePaymentTestViewModel()
        let firstGateway = makeGatewayCandidate(peerID: "gateway-a")
        let secondGateway = makeGatewayCandidate(peerID: "gateway-b")
        viewModel.agentMeshFlags.enableGateway = true
        transport.connectedPeers = [firstGateway.peerID, secondGateway.peerID]
        transport.reachablePeers = [firstGateway.peerID, secondGateway.peerID]
        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: firstGateway.peerID,
                nickname: firstGateway.nickname,
                isConnected: true,
                noisePublicKey: firstGateway.noisePublicKey,
                lastSeen: firstGateway.lastSeen,
                agentInfo: firstGateway.agentInfo
            ),
            TransportPeerSnapshot(
                peerID: secondGateway.peerID,
                nickname: secondGateway.nickname,
                isConnected: true,
                noisePublicKey: secondGateway.noisePublicKey,
                lastSeen: secondGateway.lastSeen,
                agentInfo: secondGateway.agentInfo
            )
        ])
        _ = await waitUntil { viewModel.allPeers.count >= 2 }

        let request = MintProxyRequestPacket(
            proxyID: "proxy-retry",
            mintURL: "https://mint.example",
            method: .checkstate,
            body: "{\"nullifiers\":[]}",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let pending = Task {
            try await viewModel.requestMintProxyViaMesh(request)
        }
        let didSendFirstRequest = await waitUntil { transport.sentMintProxyRequests.count == 1 }
        if !didSendFirstRequest {
            do {
                _ = try await pending.value
                XCTFail("expected first mint proxy request to remain pending")
            } catch {
                XCTFail("mint proxy retry sequence failed before first send: \(error)")
            }
            return
        }
        XCTAssertEqual(transport.sentMintProxyRequests.count, 1)
        guard transport.sentMintProxyRequests.count == 1 else {
            XCTFail("expected first mint proxy request to be sent")
            pending.cancel()
            return
        }
        XCTAssertEqual(transport.sentMintProxyRequests[0].peerID, firstGateway.peerID)

        viewModel.handleMintProxyResponse(
            MintProxyResponsePacket(
                proxyID: "proxy-retry",
                ok: false,
                body: nil,
                error: "gateway temporary failure"
            ),
            from: firstGateway.peerID
        )

        let didSendRetry = await waitUntil { transport.sentMintProxyRequests.count == 2 }
        XCTAssertTrue(didSendRetry)
        XCTAssertEqual(transport.sentMintProxyRequests.count, 2)
        guard transport.sentMintProxyRequests.count == 2 else {
            XCTFail("expected second mint proxy request retry to be sent")
            pending.cancel()
            return
        }
        XCTAssertEqual(transport.sentMintProxyRequests[1].peerID, secondGateway.peerID)

        viewModel.handleMintProxyResponse(
            MintProxyResponsePacket(
                proxyID: "proxy-retry",
                ok: true,
                body: "{\"states\":{}}",
                error: nil
            ),
            from: secondGateway.peerID
        )

        let result = try await pending.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.body, "{\"states\":{}}")
    }

    @MainActor
    func testIncomingMintProxyRequestWithInvalidBodyReturnsErrorResponse() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.agentMeshFlags.enableGateway = true
        let requester = PeerID(str: "peer-gateway-requester")
        let request = MintProxyRequestPacket(
            proxyID: "proxy-invalid-body",
            mintURL: "https://mint.example",
            method: .swap,
            body: "not-json",
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        viewModel.handleMintProxyRequest(request, from: requester)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(transport.sentMintProxyResponses.count, 1)
        let response = transport.sentMintProxyResponses[0].response
        XCTAssertEqual(response.proxyID, "proxy-invalid-body")
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("valid JSON") == true)
    }

    @MainActor
    func testSettlementGlobalSubscriptionIDIsUniquePerViewModel() {
        let (first, _) = makePaymentTestViewModel()
        let (second, _) = makePaymentTestViewModel()

        XCTAssertNotNil(first.settlementGlobalSubscriptionID)
        XCTAssertNotNil(second.settlementGlobalSubscriptionID)
        XCTAssertNotEqual(first.settlementGlobalSubscriptionID, second.settlementGlobalSubscriptionID)
    }

    @MainActor
    func testNotaryCapableNodeAttestsIncomingNotaryRequest() {
        let (viewModel, transport) = makePaymentTestViewModel()
        var config = viewModel.agentConfig
        config.notaryPolicy.isNotaryCapable = true
        viewModel.updateAgentConfig(config)
        transport.resetRecordings()

        let requester = AgentPaymentNotaryService()
        let requestContent = requester.makeNotaryRequestContent(
            requestID: "req-notary-attest",
            paymentID: "pay-notary-attest",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-attest"],
            requesterPeerID: "peer-requester"
        )
        XCTAssertNotNil(requestContent)
        guard let requestContent else { return }

        let handled = viewModel.handleNotaryMeshPublicMessageIfNeeded(
            content: requestContent,
            from: PeerID(str: "peer-requester")
        )
        XCTAssertTrue(handled)

        let outboundNotaryMessages = transport.sentMessages
            .map(\.content)
            .filter { $0.hasPrefix(AgentPaymentNotaryService.payloadPrefix) }
        XCTAssertEqual(outboundNotaryMessages.count, 1)

        let verifier = AgentPaymentNotaryService()
        let result = verifier.ingest(
            content: outboundNotaryMessages[0],
            source: .mesh,
            senderID: viewModel.meshService.myPeerID.id
        )
        XCTAssertEqual(result.status, .accepted)
        XCTAssertNotNil(result.receipt)
    }

    @MainActor
    func testNotaryDisabledNodeDoesNotAttestIncomingNotaryRequest() {
        let (viewModel, transport) = makePaymentTestViewModel()
        var config = viewModel.agentConfig
        config.notaryPolicy.isNotaryCapable = false
        viewModel.updateAgentConfig(config)
        transport.resetRecordings()
        let requester = AgentPaymentNotaryService()
        let requestContent = requester.makeNotaryRequestContent(
            requestID: "req-notary-disabled",
            paymentID: "pay-notary-disabled",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-disabled"],
            requesterPeerID: "peer-requester"
        )
        XCTAssertNotNil(requestContent)
        guard let requestContent else { return }

        let handled = viewModel.handleNotaryMeshPublicMessageIfNeeded(
            content: requestContent,
            from: PeerID(str: "peer-requester")
        )
        XCTAssertTrue(handled)
        let outboundNotaryMessages = transport.sentMessages
            .map(\.content)
            .filter { $0.hasPrefix(AgentPaymentNotaryService.payloadPrefix) }
        XCTAssertTrue(outboundNotaryMessages.isEmpty)
    }

    @MainActor
    func testNotaryNodeDoesNotAttestOwnRequesterID() {
        let (viewModel, transport) = makePaymentTestViewModel()
        var config = viewModel.agentConfig
        config.notaryPolicy.isNotaryCapable = true
        viewModel.updateAgentConfig(config)
        transport.resetRecordings()

        let requester = AgentPaymentNotaryService()
        let myPeerID = viewModel.meshService.myPeerID.id
        let requestContent = requester.makeNotaryRequestContent(
            requestID: "req-notary-self",
            paymentID: "pay-notary-self",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-self"],
            requesterPeerID: myPeerID
        )
        XCTAssertNotNil(requestContent)
        guard let requestContent else { return }

        let handled = viewModel.handleNotaryMeshPublicMessageIfNeeded(
            content: requestContent,
            from: PeerID(str: "peer-requester")
        )
        XCTAssertTrue(handled)
        let outboundNotaryMessages = transport.sentMessages
            .map(\.content)
            .filter { $0.hasPrefix(AgentPaymentNotaryService.payloadPrefix) }
        XCTAssertTrue(outboundNotaryMessages.isEmpty)
    }

    @MainActor
    func testPerTokenTrancheFlowRequestsSequentialPaymentsAndStreamsFinalChunk() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.cashuMintClient.configureProxyRequestHandler { request in
            MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: true,
                body: "{\"ok\":true}",
                error: nil
            )
        }

        var config = viewModel.agentConfig
        config.enabled = true
        config.role = "general"
        config.modelId = "local"
        config.qualityScore = 80
        config.paymentTerms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            priceModel: .perToken,
            pricePerRequest: 0,
            pricePerInputToken: 1,
            pricePerOutputToken: 2,
            minDeposit: 4,
            granularityTokens: 6,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )
        viewModel.updateAgentConfig(config)

        let peerID = PeerID(str: "peer-tranche")
        let sessionID = "sess-tranche"
        let requestID = "req-tranche"
        let request = AgentRequestPacket(
            requestID: requestID,
            role: "general",
            prompt: "alpha beta gamma delta epsilon zeta eta theta iota kappa",
            sessionID: sessionID,
            attachmentCount: nil,
            senderAlias: "payer",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 30_000
        )

        guard let requestPayload = request.encode() else {
            XCTFail("failed to encode test request")
            return
        }
        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .agentRequest,
            payload: requestPayload,
            timestamp: Date()
        )

        let gotFirstPaymentRequest = await waitUntil(timeout: 2.0) {
            transport.sentAgentResponses.contains(where: { $0.response.requestID == requestID && $0.response.paymentRequired })
        }
        XCTAssertTrue(gotFirstPaymentRequest)

        var safety = 0
        while safety < 6 {
            safety += 1
            let paymentResponses = transport.sentAgentResponses.filter {
                $0.response.requestID == requestID && $0.response.paymentRequired
            }
            guard let latest = paymentResponses.last,
                  let paymentRequest = latest.response.paymentRequest,
                  let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
                XCTFail("missing payment request envelope")
                return
            }

            let payload = makePaymentPayloadPacket(
                envelope: envelope,
                sessionID: sessionID,
                nullifierSuffix: "tranche-\(safety)"
            )
            viewModel.handleAgentPaymentPayload(payload, from: peerID)

            let receiptCount = safety
            let gotReceipt = await waitUntil(timeout: 2.0) {
                transport.sentAgentPaymentReceipts.filter { $0.receipt.requestID == requestID }.count >= receiptCount
            }
            XCTAssertTrue(gotReceipt)

            if let trancheCount = envelope.trancheCount, Int(trancheCount) == safety {
                break
            }

            let gotNextPaymentRequest = await waitUntil(timeout: 2.0) {
                transport.sentAgentResponses.filter {
                    $0.response.requestID == requestID && $0.response.paymentRequired
                }.count >= safety + 1
            }
            XCTAssertTrue(gotNextPaymentRequest)
        }

        let chunkPackets = transport.sentAgentResponseChunks.filter { $0.chunk.requestID == requestID }
        XCTAssertFalse(chunkPackets.isEmpty)
        XCTAssertEqual(chunkPackets.last?.chunk.isFinal, true)

        let paymentResponses = transport.sentAgentResponses.filter {
            $0.response.requestID == requestID && $0.response.paymentRequired
        }
        XCTAssertGreaterThanOrEqual(paymentResponses.count, 2)
    }

    @MainActor
    func testPerRequestFairExchangeSendsEncryptedOfferAndUnlockReceipt() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        viewModel.cashuMintClient.configureProxyRequestHandler { request in
            MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: true,
                body: "{\"ok\":true}",
                error: nil
            )
        }

        var config = viewModel.agentConfig
        config.enabled = true
        config.role = "general"
        config.modelId = "local"
        config.qualityScore = 80
        config.paymentTerms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .onlineRequired,
            unit: "sat",
            priceModel: .perRequest,
            pricePerRequest: 42,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )
        viewModel.updateAgentConfig(config)

        let peerID = PeerID(str: "peer-fair-provider")
        let sessionID = "sess-fair-provider"
        let requestID = "req-fair-provider"
        let request = AgentRequestPacket(
            requestID: requestID,
            role: "general",
            prompt: "share the hidden answer",
            sessionID: sessionID,
            attachmentCount: nil,
            senderAlias: "payer",
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            ttlMs: 30_000
        )
        guard let requestPayload = request.encode() else {
            XCTFail("failed to encode request")
            return
        }
        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .agentRequest,
            payload: requestPayload,
            timestamp: Date()
        )

        let gotPaymentRequired = await waitUntil(timeout: 2.0) {
            transport.sentAgentResponses.contains { $0.response.requestID == requestID && $0.response.paymentRequired }
        }
        XCTAssertTrue(gotPaymentRequired)
        guard let paymentRequiredResponse = transport.sentAgentResponses.last(where: { $0.response.requestID == requestID && $0.response.paymentRequired }),
              let paymentRequest = paymentRequiredResponse.response.paymentRequest,
              let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
            XCTFail("missing payment-required response")
            return
        }

        let sentFairOfferChunks = transport.sentAgentResponseChunks.filter {
            $0.chunk.requestID == requestID && $0.chunk.content.hasPrefix(AgentFairExchangeService.chunkPrefix)
        }
        XCTAssertFalse(sentFairOfferChunks.isEmpty)

        let payload = makePaymentPayloadPacket(
            envelope: envelope,
            sessionID: sessionID,
            nullifierSuffix: "fair-provider"
        )
        viewModel.handleAgentPaymentPayload(payload, from: peerID)

        let gotReceipt = await waitUntil(timeout: 2.0) {
            transport.sentAgentPaymentReceipts.contains { $0.receipt.requestID == requestID }
        }
        XCTAssertTrue(gotReceipt)
        guard let receipt = transport.sentAgentPaymentReceipts.last(where: { $0.receipt.requestID == requestID })?.receipt else {
            XCTFail("missing payment receipt")
            return
        }
        XCTAssertEqual(receipt.status, .finalizedOnline)
        XCTAssertNotNil(receipt.fairUnlockKey)
    }

    @MainActor
    func testRequesterUnlocksEncryptedOfferUsingReceiptKey() async {
        let (viewModel, _) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-fair-requester")
        let requestID = "req-fair-requester"
        let sessionID = "sess-fair-requester"
        let paymentID = "pay-fair-requester"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        viewModel.pendingAgentRequests[requestID] = ChatViewModel.AgentRequestContext(
            role: "general",
            targetPeerID: peerID,
            targetNickname: "fair-provider",
            sessionID: sessionID,
            threadID: peerID,
            prompt: "unlock this",
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

        let paymentRequest = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: paymentID,
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            expiresAtMs: nowMs + 120_000,
            settlementMode: .onlineRequired,
            sessionID: sessionID,
            pricingModel: .perRequest,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        ).encodeString()!

        let paymentRequired = AgentResponsePacket(
            requestID: requestID,
            content: "payment required",
            isError: false,
            sessionID: sessionID,
            chunkIndex: nil,
            chunkTotal: nil,
            paymentRequired: true,
            paymentRequest: paymentRequest,
            paymentError: nil
        )
        viewModel.handleAgentResponse(paymentRequired, from: peerID)

        let fairService = AgentFairExchangeService()
        let prepared: AgentFairExchangePreparedOffer
        do {
            prepared = try fairService.prepareOffer(
                plaintext: "this unlocks only after payment",
                requestID: requestID,
                paymentID: paymentID,
                sessionID: sessionID
            )
        } catch {
            XCTFail("failed to prepare fair offer: \(error)")
            return
        }
        let chunkContents = fairService.chunkedOfferSegments(
            prepared.offer,
            maxPacketBytes: AgentMeshConstants.maxTLVStringBytes
        )
        for (index, content) in chunkContents.enumerated() {
            let chunk = AgentResponseChunkPacket(
                requestID: requestID,
                index: UInt16(index + 1),
                isFinal: index == chunkContents.count - 1,
                content: content,
                isError: false,
                sessionID: sessionID
            )
            viewModel.handleAgentResponseChunk(chunk, from: peerID)
        }

        let receipt = AgentPaymentReceiptPacket(
            requestID: requestID,
            sessionID: sessionID,
            paymentID: paymentID,
            status: .finalizedOnline,
            details: "settled with mint",
            nullifiers: [],
            notaryReceipts: [],
            fairUnlockKey: prepared.unlockToken
        )
        viewModel.handleAgentPaymentReceipt(receipt, from: peerID)

        XCTAssertNil(viewModel.pendingAgentPayments[requestID])
        let messages = viewModel.privateChats[peerID] ?? []
        XCTAssertTrue(messages.contains(where: { $0.content.contains("this unlocks only after payment") }))
    }

    @MainActor
    func testRequesterUnlocksWhenReceiptArrivesBeforeOfferChunks() async {
        let (viewModel, _) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-fair-reordered")
        let requestID = "req-fair-reordered"
        let sessionID = "sess-fair-reordered"
        let paymentID = "pay-fair-reordered"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        viewModel.pendingAgentRequests[requestID] = ChatViewModel.AgentRequestContext(
            role: "general",
            targetPeerID: peerID,
            targetNickname: "fair-provider",
            sessionID: sessionID,
            threadID: peerID,
            prompt: "unlock this",
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

        let paymentRequest = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: paymentID,
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            expiresAtMs: nowMs + 120_000,
            settlementMode: .onlineRequired,
            sessionID: sessionID,
            pricingModel: .perRequest,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        ).encodeString()!

        let paymentRequired = AgentResponsePacket(
            requestID: requestID,
            content: "payment required",
            isError: false,
            sessionID: sessionID,
            chunkIndex: nil,
            chunkTotal: nil,
            paymentRequired: true,
            paymentRequest: paymentRequest,
            paymentError: nil
        )
        viewModel.handleAgentResponse(paymentRequired, from: peerID)

        let fairService = AgentFairExchangeService()
        let prepared: AgentFairExchangePreparedOffer
        do {
            prepared = try fairService.prepareOffer(
                plaintext: "unlock still works with reordered packets",
                requestID: requestID,
                paymentID: paymentID,
                sessionID: sessionID
            )
        } catch {
            XCTFail("failed to prepare fair offer: \(error)")
            return
        }

        let receipt = AgentPaymentReceiptPacket(
            requestID: requestID,
            sessionID: sessionID,
            paymentID: paymentID,
            status: .finalizedOnline,
            details: "settled with mint",
            nullifiers: [],
            notaryReceipts: [],
            fairUnlockKey: prepared.unlockToken
        )
        viewModel.handleAgentPaymentReceipt(receipt, from: peerID)

        let chunkContents = fairService.chunkedOfferSegments(
            prepared.offer,
            maxPacketBytes: AgentMeshConstants.maxTLVStringBytes
        )
        for (index, content) in chunkContents.enumerated() {
            let chunk = AgentResponseChunkPacket(
                requestID: requestID,
                index: UInt16(index + 1),
                isFinal: index == chunkContents.count - 1,
                content: content,
                isError: false,
                sessionID: sessionID
            )
            viewModel.handleAgentResponseChunk(chunk, from: peerID)
        }

        let messages = viewModel.privateChats[peerID] ?? []
        XCTAssertTrue(messages.contains(where: { $0.content.contains("unlock still works with reordered packets") }))
    }

    @MainActor
    func testHandleAgentPaymentPayloadResendsStoredReceiptWhenRequestNotPending() {
        let (viewModel, transport) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-a")
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let record = AgentPaymentRecord(
            requestID: "req-1",
            sessionID: "sess-1",
            peerID: peerID.id,
            paymentID: "pay-1",
            rail: "cashu",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            settlementMode: .onlineRequired,
            requiresLocking: AgentPaymentLockingMode.none,
            lockPubkey: nil,
            lockSigFlag: nil,
            paymentRequest: "creq:test",
            payload: "{\"proofs\":[]}",
            nullifiers: [],
            notaryReceipts: [],
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        )
        viewModel.agentPaymentStore.recordPaymentRequest(record)
        viewModel.agentPaymentStore.markReceipt(
            requestID: "req-1",
            status: .finalizedOnline,
            details: "settled with mint",
            nullifiers: ["n1"]
        )

        let payload = CashuPaymentPayloadEnvelope(
            paymentID: "pay-1",
            requestID: "req-1",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 42,
            proofs: [CashuProof(amount: 42, secret: "secret-pay-1")],
            nullifiers: ["n1"],
            clientNonce: "nonce-1",
            createdAtMs: nowMs
        )
        let packet = AgentPaymentPayloadPacket(
            requestID: "req-1",
            sessionID: "sess-1",
            rail: "cashu",
            payload: payload.toJSONString()!,
            sentAt: nowMs,
            clientNonce: "nonce-1"
        )

        viewModel.handleAgentPaymentPayload(packet, from: peerID)

        XCTAssertEqual(transport.sentAgentPaymentReceipts.count, 1)
        let sent = transport.sentAgentPaymentReceipts[0].receipt
        XCTAssertEqual(sent.requestID, "req-1")
        XCTAssertEqual(sent.sessionID, "sess-1")
        XCTAssertEqual(sent.status, .finalizedOnline)
        XCTAssertEqual(sent.details, "settled with mint")
        XCTAssertEqual(sent.nullifiers, ["n1"])
    }

    @MainActor
    func testStreamingChunkIsDeferredUntilPaymentReceiptAccepted() {
        let (viewModel, _) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-stream")
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let requestID = "req-stream"

        let prompt = ChatViewModel.AgentPaymentPrompt(
            requestID: requestID,
            sessionID: "sess-stream",
            peerID: peerID,
            rail: .cashu,
            paymentRequest: "creq:test",
            paymentID: "pay-stream",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            settlementMode: .onlineRequired,
            requiresLocking: nil,
            x402ChainID: nil,
            x402TokenAddress: nil,
            x402PayTo: nil,
            x402GatewayURL: nil,
            expiresAtMs: nowMs + 60_000,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil
        )
        viewModel.pendingAgentPayments[requestID] = prompt

        let chunk = AgentResponseChunkPacket(
            requestID: requestID,
            index: 1,
            isFinal: true,
            content: "paid response",
            isError: false,
            sessionID: "sess-stream"
        )
        viewModel.handleAgentResponseChunk(chunk, from: peerID)

        let preMessages = viewModel.privateChats.values.flatMap { $0 }.filter { $0.content.contains("paid response") }
        XCTAssertEqual(preMessages.count, 0)
        XCTAssertEqual(viewModel.deferredAgentResponseChunks[requestID]?.count, 1)

        let receipt = AgentPaymentReceiptPacket(
            requestID: requestID,
            sessionID: "sess-stream",
            paymentID: "pay-stream",
            status: .finalizedOnline,
            details: nil,
            nullifiers: [],
            notaryReceipts: []
        )
        viewModel.handleAgentPaymentReceipt(receipt, from: peerID)

        XCTAssertNil(viewModel.deferredAgentResponseChunks[requestID])
        XCTAssertEqual(viewModel.pendingAgentPayments[requestID], nil)
        let postMessages = viewModel.privateChats.values.flatMap { $0 }.filter { $0.content.contains("paid response") }
        XCTAssertEqual(postMessages.count, 1)
    }

    @MainActor
    func testSettlementMeshMessageHandledWithoutPublicTimelineInsert() {
        let (viewModel, transport) = makePaymentTestViewModel()
        let source = AgentSettlementGossip()
        let content = source.registerAcceptedPayment(
            paymentID: "pay-settle",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-settle"]
        ) ?? ""

        let handled = viewModel.handleSettlementMeshPublicMessageIfNeeded(
            content: content,
            from: PeerID(str: "peer-settle")
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(transport.sentMessages.count, 0)
    }

    @MainActor
    func testConflictingInboundPaymentIsRejectedBeforeBridgeEvaluation() {
        let (viewModel, transport) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-payer")
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let requestID = "req-conflict-precheck"
        let sessionID = "sess-conflict-precheck"

        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            unit: "sat",
            pricePerRequest: 42,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )
        let localInfo = AgentInfo(
            role: "general",
            modelId: "local",
            qualityScore: 80,
            modelHash: nil,
            paymentTerms: terms
        )
        let session = AgentSession(
            sessionID: sessionID,
            threadID: peerID,
            peerID: peerID,
            peerNickname: "payer",
            role: "general",
            createdAt: Date(),
            senderAlias: "payer",
            recordID: nil,
            seedHistory: [],
            seedInjected: false,
            history: []
        )
        let request = AgentRequestPacket(
            requestID: requestID,
            role: "general",
            prompt: "hello",
            sessionID: sessionID,
            attachmentCount: nil,
            senderAlias: "payer",
            createdAtMs: nowMs,
            ttlMs: 30_000
        )

        let paymentRequest = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-conflict-precheck",
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            expiresAtMs: nowMs + 120_000,
            settlementMode: .offlineAccepted,
            sessionID: sessionID,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        ).encodeString()!

        viewModel.pendingInboundPaymentRequests[requestID] = ChatViewModel.PendingInboundPaymentRequest(
            request: request,
            peerID: peerID,
            session: session,
            localInfo: localInfo,
            senderName: "payer",
            paymentRequest: paymentRequest
        )

        _ = viewModel.agentSettlementGossip.registerAcceptedPayment(
            paymentID: "existing-payment",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-conflict-precheck"]
        )

        let payloadEnvelope = CashuPaymentPayloadEnvelope(
            paymentID: "pay-other",
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 42,
            proofs: [CashuProof(amount: 42, secret: "secret-conflict-precheck")],
            nullifiers: ["n-conflict-precheck"],
            clientNonce: "nonce-precheck",
            createdAtMs: nowMs
        )
        let packet = AgentPaymentPayloadPacket(
            requestID: requestID,
            sessionID: sessionID,
            rail: "cashu",
            payload: payloadEnvelope.toJSONString()!,
            sentAt: nowMs,
            clientNonce: "nonce-precheck"
        )

        viewModel.handleAgentPaymentPayload(packet, from: peerID)

        XCTAssertEqual(transport.sentAgentPaymentReceipts.count, 1)
        XCTAssertEqual(transport.sentAgentPaymentReceipts[0].receipt.status, .rejected)
        XCTAssertTrue(transport.sentAgentPaymentReceipts[0].receipt.details?.contains("already observed") == true)
        XCTAssertFalse(transport.sentMessages.isEmpty)
        XCTAssertTrue(transport.sentMessages[0].content.hasPrefix(AgentSettlementGossip.payloadPrefix))
    }

    @MainActor
    func testDuplicateInboundPaymentPayloadWhileInFlightIsIgnored() async {
        let (viewModel, transport) = makePaymentTestViewModel()
        let peerID = PeerID(str: "peer-dup-inflight")
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let requestID = "req-dup-inflight"
        let sessionID = "sess-dup-inflight"

        let terms = AgentPaymentTerms(
            paymentRail: .cashu,
            settlementMode: .offlineAccepted,
            unit: "sat",
            pricePerRequest: 25,
            acceptedMints: ["https://mint.example"],
            requestTTLSeconds: 120
        )
        let localInfo = AgentInfo(
            role: "general",
            modelId: "local",
            qualityScore: 80,
            modelHash: nil,
            paymentTerms: terms
        )
        let session = AgentSession(
            sessionID: sessionID,
            threadID: peerID,
            peerID: peerID,
            peerNickname: "payer",
            role: "general",
            createdAt: Date(),
            senderAlias: "payer",
            recordID: nil,
            seedHistory: [],
            seedInjected: false,
            history: []
        )
        let request = AgentRequestPacket(
            requestID: requestID,
            role: "general",
            prompt: "hello",
            sessionID: sessionID,
            attachmentCount: nil,
            senderAlias: "payer",
            createdAtMs: nowMs,
            ttlMs: 30_000
        )

        let paymentRequest = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-dup-inflight",
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 25,
            expiresAtMs: nowMs + 120_000,
            settlementMode: .offlineAccepted,
            sessionID: sessionID,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        ).encodeString()!

        viewModel.agentPaymentBridge.registerIncomingPaymentRequest(
            requestID: requestID,
            sessionID: sessionID,
            peerID: peerID,
            paymentRequest: paymentRequest
        )
        viewModel.pendingInboundPaymentRequests[requestID] = ChatViewModel.PendingInboundPaymentRequest(
            request: request,
            peerID: peerID,
            session: session,
            localInfo: localInfo,
            senderName: "payer",
            paymentRequest: paymentRequest
        )

        let payloadEnvelope = CashuPaymentPayloadEnvelope(
            paymentID: "pay-dup-inflight",
            requestID: requestID,
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 25,
            proofs: [CashuProof(amount: 25, secret: "secret-dup-inflight")],
            nullifiers: ["n-dup-inflight"],
            clientNonce: "nonce-dup-inflight",
            createdAtMs: nowMs
        )
        let packet = AgentPaymentPayloadPacket(
            requestID: requestID,
            sessionID: sessionID,
            rail: "cashu",
            payload: payloadEnvelope.toJSONString()!,
            sentAt: nowMs,
            clientNonce: "nonce-dup-inflight"
        )

        // Simulate duplicate delivery while first packet is still being processed.
        viewModel.handleAgentPaymentPayload(packet, from: peerID)
        viewModel.handleAgentPaymentPayload(packet, from: peerID)

        let gotReceipt = await waitUntil(timeout: 3.0) {
            transport.sentAgentPaymentReceipts.contains(where: { $0.receipt.requestID == requestID })
        }
        XCTAssertTrue(gotReceipt)

        // Allow any accidental duplicate processing to surface.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let matchingReceipts = transport.sentAgentPaymentReceipts.filter { $0.receipt.requestID == requestID }
        XCTAssertEqual(matchingReceipts.count, 1)
    }
}
