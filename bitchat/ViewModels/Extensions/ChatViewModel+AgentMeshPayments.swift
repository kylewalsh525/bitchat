import Foundation
import BitFoundation

extension ChatViewModel {
    @MainActor
    func notifyWalletStateChanged(reason: String, requestID: String? = nil, rail: AgentPaymentRail?) {
        var payload: [String: String] = [
            WalletNotificationKeys.source: "ChatViewModel",
            WalletNotificationKeys.reason: reason
        ]
        if let requestID {
            payload[WalletNotificationKeys.requestID] = requestID
        }
        if let rail {
            payload[WalletNotificationKeys.rail] = rail.rawValue
            let name: Notification.Name = rail == .cashu ? .cashuWalletDidUpdate : .thirdwebWalletDidUpdate
            NotificationCenter.default.post(name: name, object: self, userInfo: payload)
            return
        }
        NotificationCenter.default.post(name: .cashuWalletDidUpdate, object: self, userInfo: payload)
        NotificationCenter.default.post(name: .thirdwebWalletDidUpdate, object: self, userInfo: payload)
    }

    @MainActor
    private func updateLastX402PaymentContext(from prompt: AgentPaymentPrompt, updatedAt: Date = Date()) {
        guard prompt.rail == .x402,
              let chainID = prompt.x402ChainID,
              let tokenAddress = prompt.x402TokenAddress,
              let payTo = prompt.x402PayTo,
              let gatewayURL = prompt.x402GatewayURL else {
            return
        }
        lastX402PaymentContext = LastX402PaymentContext(
            requestID: prompt.requestID,
            paymentID: prompt.paymentID,
            chainID: chainID,
            tokenAddress: tokenAddress,
            payTo: payTo,
            gatewayURL: gatewayURL,
            updatedAt: updatedAt
        )
    }

    @MainActor
    func requestIDForAgentMessage(_ message: BitchatMessage) -> String? {
        let id = message.id
        // Payment UI should only appear once per request. If we key off request *and* response
        // message IDs, the prompt card renders multiple times in the transcript.
        let prefixes = ["agent-resp-in-", "agent-resp-out-", "agent-resp-"]
        for prefix in prefixes where id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return nil
    }

    @MainActor
    func hasPendingPayment(for message: BitchatMessage) -> Bool {
        guard let requestID = requestIDForAgentMessage(message) else { return false }
        return pendingAgentPayments[requestID] != nil
    }

    @MainActor
    func payPendingAgentRequestFromUI(requestID: String) {
        let result = payPendingAgentRequest(requestID: requestID)
        switch result {
        case .success(let message):
            if let message { addSystemMessage(message) }
        case .error(let message):
            addSystemMessage(message)
        case .handled:
            break
        }
    }

    @MainActor
    func setupAgentPaymentLifecycle() {
        guard agentMeshFlags.enablePayments else {
            invalidateOfflineFinalizationTimer()
            unsubscribeFromSettlementGlobalRoom()
            return
        }
        subscribeToSettlementGlobalRoomIfNeeded()
        guard offlineFinalizationTimer == nil else { return }
        offlineFinalizationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                let finalizedCount = await self.agentPaymentBridge.finalizePendingOfflinePayments(
                    enablePaymentLocking: self.agentMeshFlags.enablePaymentLocking
                )
                if finalizedCount > 0 {
                    await self.notifyWalletStateChanged(
                        reason: "offline-finalization",
                        requestID: nil,
                        rail: .cashu
                    )
                }
            }
        }
    }

    @MainActor
    func setupSettlementGossipLifecycle() {
        guard agentMeshFlags.enablePayments else {
            unsubscribeFromSettlementGlobalRoom()
            return
        }
        subscribeToSettlementGlobalRoomIfNeeded()
    }

    @MainActor
    func invalidateOfflineFinalizationTimer() {
        if let timer = offlineFinalizationTimer {
            timer.invalidate()
            offlineFinalizationTimer = nil
        }
    }

    @MainActor
    func subscribeToSettlementGlobalRoomIfNeeded() {
        guard agentMeshFlags.enablePayments else { return }
        guard settlementGlobalSubscriptionID == nil else { return }
        guard let relayManager = nostrRelayManager else { return }

        let subID = "settle-global-\(UUID().uuidString)"
        settlementGlobalSubscriptionID = subID
        let filter = NostrFilter.geohashEphemeral(
            AgentSettlementGossip.globalRoom,
            since: Date().addingTimeInterval(-TransportConfig.settlementGossipGlobalLookbackSeconds),
            limit: 200
        )
        relayManager.subscribe(filter: filter, id: subID) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleSettlementGlobalEvent(event)
            }
        }
    }

    @MainActor
    func unsubscribeFromSettlementGlobalRoom() {
        guard let subID = settlementGlobalSubscriptionID else { return }
        nostrRelayManager?.unsubscribe(id: subID)
        settlementGlobalSubscriptionID = nil
    }

    @MainActor
    func handleNotaryMeshPublicMessageIfNeeded(content: String, from peerID: PeerID) -> Bool {
        guard agentMeshFlags.enablePayments else { return false }
        let result = agentPaymentNotaryService.ingest(content: content, source: .mesh, senderID: peerID.id)
        guard result.isNotary else { return false }

        guard result.status == .accepted else {
            return true
        }

        if result.shouldForwardToGlobal {
            sendNotaryGlobalMessage(content)
        }
        processAcceptedNotaryIngest(result)
        return true
    }

    @MainActor
    func handleSettlementMeshPublicMessageIfNeeded(content: String, from peerID: PeerID) -> Bool {
        guard agentMeshFlags.enablePayments else { return false }
        let result = agentSettlementGossip.ingest(content: content, source: .mesh, senderID: peerID.id)
        guard result.isSettlement else { return false }

        guard result.status == .accepted else {
            return true
        }

        if result.shouldForwardToGlobal {
            sendSettlementGlobalMessage(content)
        }

        if let conflictNullifier = result.conflictNullifier,
           let conflictContent = agentSettlementGossip.makeSpendConflictContent(
                nullifier: conflictNullifier,
                evidence: "nullifier seen across multiple paymentIDs"
           ) {
            sendSettlementMeshMessage(conflictContent)
            sendSettlementGlobalMessage(conflictContent)
        }

        return true
    }

    @MainActor
    func handleSettlementGlobalEvent(_ event: NostrEvent) {
        guard agentMeshFlags.enablePayments else { return }
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard !identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) else { return }

        let notaryResult = agentPaymentNotaryService.ingest(content: content, source: .global, senderID: event.pubkey)
        if notaryResult.isNotary {
            guard notaryResult.status == .accepted else { return }
            if notaryResult.shouldForwardToMesh {
                sendNotaryMeshMessage(content)
            }
            processAcceptedNotaryIngest(notaryResult)
            return
        }

        let result = agentSettlementGossip.ingest(content: content, source: .global, senderID: event.pubkey)
        guard result.isSettlement, result.status == .accepted else { return }

        if result.shouldForwardToMesh {
            sendSettlementMeshMessage(content)
        }

        if let conflictNullifier = result.conflictNullifier,
           let conflictContent = agentSettlementGossip.makeSpendConflictContent(
                nullifier: conflictNullifier,
                evidence: "nullifier seen across multiple paymentIDs"
           ) {
            sendSettlementMeshMessage(conflictContent)
            sendSettlementGlobalMessage(conflictContent)
        }
    }

    @MainActor
    private func processAcceptedNotaryIngest(_ result: AgentPaymentNotaryService.IngestResult) {
        guard let request = result.request else { return }
        let policy = agentConfig.notaryPolicy
        guard policy.isNotaryCapable else { return }
        if request.requesterPeerID?.lowercased() == meshService.myPeerID.id.lowercased() {
            return
        }

        let noiseService = meshService.getNoiseService()
        let signingPublicKeyHex = noiseService.getSigningPublicKeyData().hexEncodedString()
        let notaryPeerID = meshService.myPeerID.id
        guard let content = agentPaymentNotaryService.makeNotaryAttestationContent(
            request: request,
            room: AgentSettlementGossip.meshRoom,
            notaryPeerID: notaryPeerID,
            signingPublicKeyHex: signingPublicKeyHex,
            sign: { payload in
                noiseService.signData(payload)
            }
        ) else {
            return
        }

        sendNotaryMeshMessage(content)
        sendNotaryGlobalMessage(content)
    }

    @MainActor
    func sendSettlementMeshMessage(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meshService.sendMessage(
            trimmed,
            mentions: [],
            messageID: UUID().uuidString,
            timestamp: Date()
        )
    }

    @MainActor
    func sendSettlementGlobalMessage(_ content: String) {
        guard agentMeshFlags.enablePayments else { return }
        guard nostrRelayManager?.isConnected == true else { return }
        guard let identity = try? idBridge.getCurrentNostrIdentity() else { return }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let event = try NostrProtocol.createEphemeralGeohashEvent(
                content: trimmed,
                geohash: AgentSettlementGossip.globalRoom,
                senderIdentity: identity,
                nickname: nickname,
                teleported: false
            )
            nostrRelayManager?.sendEvent(event)
        } catch {
            return
        }
    }

    @MainActor
    func sendNotaryMeshMessage(_ content: String) {
        sendSettlementMeshMessage(content)
    }

    @MainActor
    func sendNotaryGlobalMessage(_ content: String) {
        sendSettlementGlobalMessage(content)
    }

    @MainActor
    func shouldRequireAgentPayment(localInfo: AgentInfo) -> Bool {
        guard agentMeshFlags.enablePayments else { return false }
        guard let terms = localInfo.paymentTerms?.sanitized() else { return false }
        if terms.paymentRail == .x402 && !agentMeshFlags.enableX402Payments {
            return false
        }
        return terms.paymentRail != .none && terms.isEnabled
    }

    @MainActor
    func sendPaymentRequiredResponse(
        requestID: String,
        role: String,
        peerID: PeerID,
        sessionID: String,
        threadID: PeerID,
        senderName: String,
        paymentRequest: String,
        hasEncryptedOffer: Bool = false
    ) {
        let summary: String = {
            if let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) {
                let lockDetail = (envelope.requiresLocking ?? .none) == .p2pk ? ", lock p2pk" : ""
                if let trancheIndex = envelope.trancheIndex, let trancheCount = envelope.trancheCount {
                    return "payment required (tranche \(trancheIndex)/\(trancheCount)): \(envelope.amount) \(envelope.unit)\(lockDetail)"
                }
                if hasEncryptedOffer {
                    return "payment required: encrypted response locked (\(envelope.amount) \(envelope.unit)\(lockDetail))"
                }
                return "payment required: \(envelope.amount) \(envelope.unit)\(lockDetail)"
            }
            if let envelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
                let chainLabel = "eip155:\(envelope.chainID)"
                if hasEncryptedOffer {
                    return "payment required: encrypted response locked (\(envelope.amount) \(envelope.unit), x402 \(chainLabel), online-only)"
                }
                return "payment required: \(envelope.amount) \(envelope.unit) (x402 \(chainLabel), online-only)"
            }
            return "payment required"
        }()

        let response = AgentResponsePacket(
            requestID: requestID,
            content: summary,
            isError: false,
            sessionID: sessionID,
            chunkIndex: nil,
            chunkTotal: nil,
            paymentRequired: true,
            paymentRequest: paymentRequest,
            paymentError: nil
        )
        addAgentResponseDM(
            requestID: requestID,
            role: role,
            content: summary,
            peerID: threadID,
            peerNickname: senderName,
            outgoing: true,
            isError: false
        )
        sendAgentResponseChunks(response, to: peerID)
    }

    @MainActor
    func startPerTokenTranchePreparation(
        request: AgentRequestPacket,
        from peerID: PeerID,
        localInfo: AgentInfo,
        session: AgentSession,
        senderName: String,
        terms: AgentPaymentTerms
    ) {
        let requestID = request.requestID
        if let pending = pendingInboundPaymentRequests[requestID] {
            sendPaymentRequiredResponse(
                requestID: requestID,
                role: localInfo.role,
                peerID: pending.peerID,
                sessionID: pending.session.sessionID,
                threadID: pending.session.threadID,
                senderName: pending.senderName,
                paymentRequest: pending.paymentRequest
            )
            return
        }
        guard providerTranchePlans[requestID] == nil else { return }
        guard !providerTranchePreparationRequestIDs.contains(requestID) else { return }
        providerTranchePreparationRequestIDs.insert(requestID)

        Task { [weak self, agentRuntime] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.providerTranchePreparationRequestIDs.remove(requestID)
                }
            }

            let expected = Int(request.attachmentCount ?? 0)
            let requestStart = Date().addingTimeInterval(-self.agentAttachmentLookbackSeconds)
            let pendingAttachments = expected > 0
                ? await self.awaitAgentAttachments(
                    sessionID: session.sessionID,
                    peerID: peerID,
                    expected: expected,
                    since: requestStart
                )
                : []

            if expected > 0, pendingAttachments.count < expected {
                await MainActor.run {
                    let message = "missing attachments (\(pendingAttachments.count)/\(expected)); please retry"
                    let response = AgentResponsePacket(
                        requestID: requestID,
                        content: message,
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: message,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                }
                return
            }

            let runtimeAttachments = self.makeRuntimeAttachments(from: pendingAttachments)
            let runtimeResult = await agentRuntime.run(
                request: request,
                from: peerID,
                localInfo: localInfo,
                session: session,
                attachments: runtimeAttachments
            )

            await MainActor.run {
                if runtimeResult.response.isError {
                    self.appendAgentSessionHistory(sessionID: session.sessionID, role: "assistant", content: runtimeResult.response.content)
                    self.addAgentResponseDM(
                        requestID: runtimeResult.response.requestID,
                        role: localInfo.role,
                        content: runtimeResult.response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(runtimeResult.response, to: peerID)
                    self.sendAgentAttachments(runtimeResult.attachments, session: session)
                    self.cacheAgentResponseIfNeeded(runtimeResult.response, attachments: runtimeResult.attachments)
                    AgentMeshLogger.log(.responseSent(requestID: runtimeResult.response.requestID, peerID: peerID, isError: true))
                    return
                }

                let split = self.splitResponseIntoPaymentTranches(
                    text: runtimeResult.response.content,
                    granularity: terms.effectiveGranularityTokens
                )
                let trancheTexts = split.texts
                let trancheTokenCounts = split.tokenCounts

                guard !trancheTexts.isEmpty else {
                    self.appendAgentSessionHistory(sessionID: session.sessionID, role: "assistant", content: runtimeResult.response.content)
                    self.addAgentResponseDM(
                        requestID: runtimeResult.response.requestID,
                        role: localInfo.role,
                        content: runtimeResult.response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: runtimeResult.response.isError
                    )
                    self.sendAgentResponseChunks(runtimeResult.response, to: peerID)
                    self.sendAgentAttachments(runtimeResult.attachments, session: session)
                    self.cacheAgentResponseIfNeeded(runtimeResult.response, attachments: runtimeResult.attachments)
                    AgentMeshLogger.log(.responseSent(requestID: runtimeResult.response.requestID, peerID: peerID, isError: runtimeResult.response.isError))
                    return
                }

                let inputTokenCount = self.estimatedTokenCount(text: request.prompt)
                let inputTokenPrice = terms.pricePerInputToken ?? 0
                let outputTokenPrice = terms.pricePerOutputToken ?? 0
                var trancheAmounts: [UInt64] = []
                trancheAmounts.reserveCapacity(trancheTokenCounts.count)
                for (index, trancheTokenCount) in trancheTokenCounts.enumerated() {
                    let outputAmount = self.safeMultiply(outputTokenPrice, UInt64(trancheTokenCount))
                    var amount = outputAmount
                    if index == 0 {
                        amount = self.safeAdd(amount, self.safeMultiply(inputTokenPrice, UInt64(inputTokenCount)))
                        amount = max(amount, terms.effectiveMinimumDeposit)
                    }
                    trancheAmounts.append(max(1, amount))
                }

                let plan = ProviderTranchePlan(
                    request: request,
                    peerID: peerID,
                    session: session,
                    localInfo: localInfo,
                    senderName: senderName,
                    fullResponse: runtimeResult.response.content,
                    isError: runtimeResult.response.isError,
                    attachments: runtimeResult.attachments,
                    trancheTexts: trancheTexts,
                    trancheTokenCounts: trancheTokenCounts,
                    trancheAmounts: trancheAmounts,
                    nextTrancheIndex: 0,
                    nextChunkIndex: 1
                )

                guard let firstAmount = trancheAmounts.first,
                      let firstTokenCount = trancheTokenCounts.first,
                      let firstPaymentRequest = self.agentPaymentBridge.createPaymentRequest(
                        requestID: requestID,
                        sessionID: session.sessionID,
                        peerID: peerID,
                        terms: terms,
                        metadata: AgentPaymentRequestMetadata(
                            amountOverride: firstAmount,
                            pricingModel: .perToken,
                            trancheIndex: 1,
                            trancheCount: UInt32(trancheTexts.count),
                            trancheTokenCount: firstTokenCount,
                            outputTokenPrice: terms.pricePerOutputToken,
                            inputTokenPrice: terms.pricePerInputToken,
                            minimumDeposit: terms.minDeposit
                        ),
                        enablePaymentLocking: self.agentMeshFlags.enablePaymentLocking,
                        enableX402Payments: self.agentMeshFlags.enableX402Payments
                      ) else {
                    let response = AgentResponsePacket(
                        requestID: requestID,
                        content: "payment unavailable",
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil,
                        paymentRequired: false,
                        paymentRequest: nil,
                        paymentError: "failed to build per-token payment request"
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                    return
                }

                self.providerTranchePlans[requestID] = plan
                self.pendingInboundPaymentRequests[requestID] = PendingInboundPaymentRequest(
                    request: request,
                    peerID: peerID,
                    session: session,
                    localInfo: localInfo,
                    senderName: senderName,
                    paymentRequest: firstPaymentRequest
                )
                self.scheduleInboundPaymentExpiry(
                    requestID: requestID,
                    sessionID: session.sessionID,
                    threadID: session.threadID,
                    paymentRequest: firstPaymentRequest
                )
                self.sendPaymentRequiredResponse(
                    requestID: requestID,
                    role: localInfo.role,
                    peerID: peerID,
                    sessionID: session.sessionID,
                    threadID: session.threadID,
                    senderName: senderName,
                    paymentRequest: firstPaymentRequest
                )
            }
        }
    }

    @MainActor
    func startPerRequestFairExchangePreparation(
        request: AgentRequestPacket,
        from peerID: PeerID,
        localInfo: AgentInfo,
        session: AgentSession,
        senderName: String,
        terms: AgentPaymentTerms,
        quotedAmountOverride: UInt64? = nil
    ) {
        let requestID = request.requestID
        if let pending = pendingInboundPaymentRequests[requestID] {
            let hasEncryptedOffer = providerFairExchangePlans[requestID]?.encryptedOffer != nil
            sendPaymentRequiredResponse(
                requestID: requestID,
                role: localInfo.role,
                peerID: pending.peerID,
                sessionID: pending.session.sessionID,
                threadID: pending.session.threadID,
                senderName: pending.senderName,
                paymentRequest: pending.paymentRequest,
                hasEncryptedOffer: hasEncryptedOffer
            )
            if let plan = providerFairExchangePlans[requestID] {
                sendProviderFairExchangeOfferChunks(plan)
            }
            return
        }

        if let plan = providerFairExchangePlans[requestID] {
            pendingInboundPaymentRequests[requestID] = PendingInboundPaymentRequest(
                request: plan.request,
                peerID: plan.peerID,
                session: plan.session,
                localInfo: plan.localInfo,
                senderName: plan.senderName,
                paymentRequest: plan.paymentRequest
            )
            scheduleInboundPaymentExpiry(
                requestID: requestID,
                sessionID: plan.session.sessionID,
                threadID: plan.session.threadID,
                paymentRequest: plan.paymentRequest
            )
            sendPaymentRequiredResponse(
                requestID: requestID,
                role: plan.localInfo.role,
                peerID: plan.peerID,
                sessionID: plan.session.sessionID,
                threadID: plan.session.threadID,
                senderName: plan.senderName,
                paymentRequest: plan.paymentRequest,
                hasEncryptedOffer: plan.encryptedOffer != nil
            )
            sendProviderFairExchangeOfferChunks(plan)
            return
        }

        guard !providerFairExchangePreparationRequestIDs.contains(requestID) else { return }
        providerFairExchangePreparationRequestIDs.insert(requestID)

        Task { [weak self, agentRuntime] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.providerFairExchangePreparationRequestIDs.remove(requestID)
                }
            }

            let expected = Int(request.attachmentCount ?? 0)
            let requestStart = Date().addingTimeInterval(-self.agentAttachmentLookbackSeconds)
            let pendingAttachments = expected > 0
                ? await self.awaitAgentAttachments(
                    sessionID: session.sessionID,
                    peerID: peerID,
                    expected: expected,
                    since: requestStart
                )
                : []

            if expected > 0, pendingAttachments.count < expected {
                await MainActor.run {
                    let message = "missing attachments (\(pendingAttachments.count)/\(expected)); please retry"
                    let response = AgentResponsePacket(
                        requestID: requestID,
                        content: message,
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: message,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                }
                return
            }

            let runtimeAttachments = self.makeRuntimeAttachments(from: pendingAttachments)
            let runtimeResult = await agentRuntime.run(
                request: request,
                from: peerID,
                localInfo: localInfo,
                session: session,
                attachments: runtimeAttachments
            )

            await MainActor.run {
                if runtimeResult.response.isError {
                    self.appendAgentSessionHistory(sessionID: session.sessionID, role: "assistant", content: runtimeResult.response.content)
                    self.addAgentResponseDM(
                        requestID: runtimeResult.response.requestID,
                        role: localInfo.role,
                        content: runtimeResult.response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(runtimeResult.response, to: peerID)
                    self.sendAgentAttachments(runtimeResult.attachments, session: session)
                    self.cacheAgentResponseIfNeeded(runtimeResult.response, attachments: runtimeResult.attachments)
                    AgentMeshLogger.log(.responseSent(requestID: runtimeResult.response.requestID, peerID: peerID, isError: true))
                    return
                }

                guard let paymentRequest = self.agentPaymentBridge.createPaymentRequest(
                    requestID: requestID,
                    sessionID: session.sessionID,
                    peerID: peerID,
                    terms: terms,
                    metadata: AgentPaymentRequestMetadata(
                        amountOverride: quotedAmountOverride,
                        pricingModel: nil,
                        trancheIndex: nil,
                        trancheCount: nil,
                        trancheTokenCount: nil,
                        outputTokenPrice: nil,
                        inputTokenPrice: nil,
                        minimumDeposit: nil
                    ),
                    enablePaymentLocking: self.agentMeshFlags.enablePaymentLocking,
                    enableX402Payments: self.agentMeshFlags.enableX402Payments
                ) else {
                    let response = AgentResponsePacket(
                        requestID: requestID,
                        content: "payment unavailable",
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil,
                        paymentRequired: false,
                        paymentRequest: nil,
                        paymentError: "failed to build payment request"
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                    return
                }

                let paymentID: String
                if let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) {
                    paymentID = envelope.paymentID
                } else if let envelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
                    paymentID = envelope.paymentID
                } else {
                    let response = AgentResponsePacket(
                        requestID: requestID,
                        content: "payment unavailable",
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil,
                        paymentRequired: false,
                        paymentRequest: nil,
                        paymentError: "failed to parse payment request"
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: response.content,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                    return
                }

                let preparedOffer = try? self.agentFairExchangeService.prepareOffer(
                    plaintext: runtimeResult.response.content,
                    requestID: requestID,
                    paymentID: paymentID,
                    sessionID: session.sessionID
                )
                let plan = ProviderFairExchangePlan(
                    request: request,
                    peerID: peerID,
                    session: session,
                    localInfo: localInfo,
                    senderName: senderName,
                    paymentRequest: paymentRequest,
                    paymentID: paymentID,
                    encryptedOffer: preparedOffer?.offer,
                    unlockToken: preparedOffer?.unlockToken,
                    runtimeResult: runtimeResult
                )
                self.providerFairExchangePlans[requestID] = plan
                self.pendingInboundPaymentRequests[requestID] = PendingInboundPaymentRequest(
                    request: request,
                    peerID: peerID,
                    session: session,
                    localInfo: localInfo,
                    senderName: senderName,
                    paymentRequest: paymentRequest
                )
                self.scheduleInboundPaymentExpiry(
                    requestID: requestID,
                    sessionID: session.sessionID,
                    threadID: session.threadID,
                    paymentRequest: paymentRequest
                )
                self.sendPaymentRequiredResponse(
                    requestID: requestID,
                    role: localInfo.role,
                    peerID: peerID,
                    sessionID: session.sessionID,
                    threadID: session.threadID,
                    senderName: senderName,
                    paymentRequest: paymentRequest,
                    hasEncryptedOffer: preparedOffer != nil
                )
                self.sendProviderFairExchangeOfferChunks(plan)
            }
        }
    }

    @MainActor
    func sendProviderFairExchangeOfferChunks(_ plan: ProviderFairExchangePlan) {
        guard let encryptedOffer = plan.encryptedOffer else { return }
        let chunks = agentFairExchangeService.chunkedOfferSegments(
            encryptedOffer,
            maxPacketBytes: AgentMeshConstants.maxTLVStringBytes
        )
        guard !chunks.isEmpty else { return }

        for (index, content) in chunks.enumerated() {
            let packet = AgentResponseChunkPacket(
                requestID: plan.request.requestID,
                index: UInt16(index + 1),
                isFinal: index == chunks.count - 1,
                content: content,
                isError: false,
                sessionID: plan.session.sessionID
            )
            meshService.sendAgentResponseChunk(packet, to: plan.peerID)
        }
    }

    @MainActor
    func scheduleInboundPaymentExpiry(requestID: String, sessionID: String?, threadID: PeerID, paymentRequest: String) {
        if let timer = inboundPaymentExpiryTimers.removeValue(forKey: requestID) {
            timer.invalidate()
        }
        struct InboundExpiry {
            let paymentID: String
            let expiresAtMs: UInt64
            let rail: AgentPaymentRail
        }
        let envelope: InboundExpiry?
        if let decoded = CashuPaymentRequestEnvelope.decode(from: paymentRequest) {
            envelope = InboundExpiry(paymentID: decoded.paymentID, expiresAtMs: decoded.expiresAtMs, rail: .cashu)
        } else if let decoded = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
            envelope = InboundExpiry(paymentID: decoded.paymentID, expiresAtMs: decoded.expiresAtMs, rail: .x402)
        } else {
            envelope = nil
        }
        guard let envelope else { return }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard envelope.expiresAtMs > nowMs else {
            pendingInboundPaymentRequests.removeValue(forKey: requestID)
            providerTranchePlans.removeValue(forKey: requestID)
            providerTranchePreparationRequestIDs.remove(requestID)
            providerFairExchangePlans.removeValue(forKey: requestID)
            providerFairExchangePreparationRequestIDs.remove(requestID)
            inboundFairExchangeAssemblies.removeValue(forKey: requestID)
            inboundFairExchangeOffers.removeValue(forKey: requestID)
            inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
            agentPaymentStore.markFailed(requestID: requestID, details: "payment request expired")
            if envelope.rail == .cashu {
                agentPaymentLockKeyStore.delete(requestID: requestID, paymentID: envelope.paymentID)
            }
            return
        }

        let interval = TimeInterval(envelope.expiresAtMs - nowMs) / 1000.0
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pendingInboundPaymentRequests.removeValue(forKey: requestID)
                self.providerTranchePlans.removeValue(forKey: requestID)
                self.providerTranchePreparationRequestIDs.remove(requestID)
                self.providerFairExchangePlans.removeValue(forKey: requestID)
                self.providerFairExchangePreparationRequestIDs.remove(requestID)
                self.inboundFairExchangeAssemblies.removeValue(forKey: requestID)
                self.inboundFairExchangeOffers.removeValue(forKey: requestID)
                self.inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
                self.inboundPaymentExpiryTimers.removeValue(forKey: requestID)
                self.agentPaymentStore.markFailed(requestID: requestID, details: "payment request expired")
                if envelope.rail == .cashu {
                    self.agentPaymentLockKeyStore.delete(requestID: requestID, paymentID: envelope.paymentID)
                }
                self.addLocalPrivateSystemMessage("payment request expired", to: threadID)
            }
        }
        inboundPaymentExpiryTimers[requestID] = timer
    }

    @MainActor
    private func cancelInboundPaymentExpiry(requestID: String) {
        if let timer = inboundPaymentExpiryTimers.removeValue(forKey: requestID) {
            timer.invalidate()
        }
    }

    @MainActor
    func processInboundFairExchangeChunkIfNeeded(
        _ chunk: AgentResponseChunkPacket,
        from peerID: PeerID,
        role: String,
        agentName: String,
        threadID: PeerID
    ) -> Bool {
        guard let payload = agentFairExchangeService.extractOfferChunkPayload(from: chunk.content) else {
            return false
        }

        var assembly = inboundFairExchangeAssemblies[chunk.requestID] ?? InboundFairExchangeAssembly(
            peerID: peerID,
            sessionID: chunk.sessionID,
            segments: [:],
            finalIndex: nil
        )
        assembly.segments[chunk.index] = payload
        if chunk.isFinal {
            assembly.finalIndex = chunk.index
        }
        inboundFairExchangeAssemblies[chunk.requestID] = assembly

        guard let finalIndex = assembly.finalIndex else {
            return true
        }

        var mergedSegments: [String] = []
        mergedSegments.reserveCapacity(Int(finalIndex))
        for index in UInt16(1)...finalIndex {
            guard let segment = assembly.segments[index] else {
                return true
            }
            mergedSegments.append(segment)
        }
        let offer = mergedSegments.joined()
        guard let envelope = agentFairExchangeService.decodeOfferIfPresent(offer),
              envelope.requestID == chunk.requestID else {
            inboundFairExchangeAssemblies.removeValue(forKey: chunk.requestID)
            addLocalPrivateSystemMessage("received invalid encrypted response offer", to: threadID)
            return true
        }

        inboundFairExchangeAssemblies.removeValue(forKey: chunk.requestID)
        inboundFairExchangeOffers[chunk.requestID] = InboundFairExchangeOffer(
            peerID: peerID,
            sessionID: chunk.sessionID,
            offer: offer
        )

        if let unlockToken = inboundFairExchangeUnlockTokens[chunk.requestID],
           tryUnlockFairExchangeOffer(
                requestID: chunk.requestID,
                unlockToken: unlockToken,
                from: peerID,
                threadID: threadID
           ) {
            return true
        }

        let lockedMessage = "encrypted response ready. pay to unlock."
        upsertAgentResponseDM(
            requestID: chunk.requestID,
            role: role,
            content: lockedMessage,
            peerID: threadID,
            peerNickname: agentName,
            outgoing: false,
            isError: false,
            markUnread: true
        )
        return true
    }

    @MainActor
    func deferAgentResponseChunk(_ chunk: AgentResponseChunkPacket, from peerID: PeerID) {
        var queued = deferredAgentResponseChunks[chunk.requestID] ?? []
        if queued.contains(where: { $0.chunk.index == chunk.index && $0.chunk.sessionID == chunk.sessionID }) {
            return
        }
        queued.append(DeferredAgentResponseChunk(peerID: peerID, chunk: chunk))
        if queued.count > 128 {
            queued.removeFirst(queued.count - 128)
        }
        deferredAgentResponseChunks[chunk.requestID] = queued
    }

    @MainActor
    func flushDeferredAgentResponses(for requestID: String) {
        guard pendingAgentPayments[requestID] == nil else { return }
        let deferredPacket = deferredAgentResponses.removeValue(forKey: requestID)
        let deferredChunks = deferredAgentResponseChunks.removeValue(forKey: requestID) ?? []

        if let deferredPacket, deferredChunks.isEmpty {
            handleAgentResponse(deferredPacket.response, from: deferredPacket.peerID)
        }

        if !deferredChunks.isEmpty {
            let ordered = deferredChunks.sorted { lhs, rhs in
                if lhs.chunk.index == rhs.chunk.index {
                    return lhs.peerID.id < rhs.peerID.id
                }
                return lhs.chunk.index < rhs.chunk.index
            }
            for entry in ordered {
                handleAgentResponseChunk(entry.chunk, from: entry.peerID)
            }
        }
    }

    @MainActor
    func clearDeferredAgentResponses(for requestID: String) {
        deferredAgentResponses.removeValue(forKey: requestID)
        deferredAgentResponseChunks.removeValue(forKey: requestID)
    }

    @MainActor
    func handlePaymentRequiredResponse(
        response: AgentResponsePacket,
        from peerID: PeerID,
        role: String,
        agentName: String,
        threadID: PeerID
    ) {
        guard agentMeshFlags.enablePayments else {
            addLocalPrivateSystemMessage("agent requested payment but payments are disabled", to: threadID)
            return
        }
        guard let paymentRequest = response.paymentRequest else {
            let fallback = response.paymentError ?? "invalid payment request"
            addLocalPrivateSystemMessage("agent payment error: \(fallback)", to: threadID)
            return
        }

        enum ParsedPaymentRequest {
            case cashu(CashuPaymentRequestEnvelope)
            case x402(X402PaymentRequestEnvelope)
        }

        let parsedRequest: ParsedPaymentRequest?
        if let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) {
            parsedRequest = .cashu(envelope)
        } else if let envelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
            parsedRequest = .x402(envelope)
        } else {
            parsedRequest = nil
        }
        guard let parsedRequest else {
            let fallback = response.paymentError ?? "invalid payment request"
            addLocalPrivateSystemMessage("agent payment error: \(fallback)", to: threadID)
            return
        }

        let prompt: AgentPaymentPrompt
        let settlementMode: AgentSettlementMode
        let lockMode: AgentPaymentLockingMode
        let mintHint: String
        let amount: UInt64
        let unit: String
        let rail: AgentPaymentRail
        let trancheDetail: String

        switch parsedRequest {
        case .cashu(let envelope):
            settlementMode = envelope.settlementMode
            lockMode = envelope.requiresLocking ?? .none
            mintHint = URL(string: envelope.mintURL)?.host ?? envelope.mintURL
            amount = envelope.amount
            unit = envelope.unit
            rail = .cashu
            if let index = envelope.trancheIndex, let count = envelope.trancheCount {
                trancheDetail = ", tranche \(index)/\(count)"
            } else {
                trancheDetail = ""
            }
            prompt = AgentPaymentPrompt(
                requestID: response.requestID,
                sessionID: response.sessionID,
                peerID: peerID,
                rail: .cashu,
                paymentRequest: paymentRequest,
                paymentID: envelope.paymentID,
                mintURL: envelope.mintURL,
                unit: envelope.unit,
                amount: envelope.amount,
                settlementMode: envelope.settlementMode,
                requiresLocking: envelope.requiresLocking,
                x402ChainID: nil,
                x402TokenAddress: nil,
                x402PayTo: nil,
                x402GatewayURL: nil,
                expiresAtMs: envelope.expiresAtMs,
                pricingModel: envelope.pricingModel,
                trancheIndex: envelope.trancheIndex,
                trancheCount: envelope.trancheCount,
                trancheTokenCount: envelope.trancheTokenCount
            )
        case .x402(let envelope):
            guard agentMeshFlags.enableX402Payments else {
                addLocalPrivateSystemMessage("agent requested x402 payment but x402 payments are disabled", to: threadID)
                return
            }
            settlementMode = .onlineRequired
            lockMode = .none
            mintHint = URL(string: envelope.gatewayURL)?.host ?? envelope.gatewayURL
            amount = envelope.amount
            unit = envelope.unit
            rail = .x402
            trancheDetail = ""
            prompt = AgentPaymentPrompt(
                requestID: response.requestID,
                sessionID: response.sessionID,
                peerID: peerID,
                rail: .x402,
                paymentRequest: paymentRequest,
                paymentID: envelope.paymentID,
                mintURL: envelope.gatewayURL,
                unit: envelope.unit,
                amount: envelope.amount,
                settlementMode: .onlineRequired,
                requiresLocking: AgentPaymentLockingMode.none,
                x402ChainID: envelope.chainID,
                x402TokenAddress: envelope.tokenAddress,
                x402PayTo: envelope.payTo,
                x402GatewayURL: envelope.gatewayURL,
                expiresAtMs: envelope.expiresAtMs,
                pricingModel: .perRequest,
                trancheIndex: nil,
                trancheCount: nil,
                trancheTokenCount: nil
            )
        }

        agentPaymentBridge.registerIncomingPaymentRequest(
            requestID: response.requestID,
            sessionID: response.sessionID,
            peerID: peerID,
            paymentRequest: paymentRequest
        )

        clearDeferredAgentResponses(for: response.requestID)
        pendingAgentPayments[response.requestID] = prompt
        if rail == .x402 {
            updateLastX402PaymentContext(from: prompt)
        }
        Task {
            let mode = settlementMode == .offlineAccepted ? "offline-accepted" : "online-required"
            let locking = lockMode.rawValue
            await SupportEventLog.shared.record(
                category: "payment",
                message: "payment required id=\(response.requestID.prefix(8)) rail=\(rail.rawValue) mint=\(mintHint) amount=\(amount)\(unit) settlement=\(mode) lock=\(locking)"
            )
        }
        pauseAgentStreamingForPayment(requestID: response.requestID, sessionID: response.sessionID)
        schedulePaymentPromptExpiry(requestID: response.requestID, threadID: threadID)
        clearAgentSessionPaymentState(sessionID: response.sessionID, threadID: threadID)

        let mode = settlementMode == .offlineAccepted ? "offline-accepted" : "online-required"
        let hasEncryptedOffer = inboundFairExchangeOffers[response.requestID] != nil
        let fairDetail = hasEncryptedOffer ? ", encrypted response ready to unlock" : ""
        let lockDetail = lockMode == .p2pk ? ", lock p2pk" : ""
        let railDetail: String = {
            if rail == .x402 {
                return ", rail x402"
            }
            return ""
        }()
        let message = "payment required (\(amount) \(unit), \(mode)\(lockDetail)\(railDetail)\(trancheDetail), mint \(mintHint)\(fairDetail)). tap Pay or use /agentpay \(response.requestID)"
        upsertAgentResponseDM(
            requestID: response.requestID,
            role: role,
            content: message,
            peerID: threadID,
            peerNickname: agentName,
            outgoing: false,
            isError: false,
            markUnread: true
        )
    }

    @MainActor
    private func schedulePaymentPromptExpiry(requestID: String, threadID: PeerID) {
        if let timer = agentPaymentExpiryTimers.removeValue(forKey: requestID) {
            timer.invalidate()
        }
        guard let prompt = pendingAgentPayments[requestID] else { return }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if prompt.expiresAtMs <= nowMs {
            pendingAgentPayments.removeValue(forKey: requestID)
            clearDeferredAgentResponses(for: requestID)
            inboundFairExchangeAssemblies.removeValue(forKey: requestID)
            inboundFairExchangeOffers.removeValue(forKey: requestID)
            inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
            agentPaymentStore.markFailed(requestID: requestID, details: "payment request expired")
            setAgentSessionPaymentState(sessionID: prompt.sessionID, threadID: threadID, state: .failed)
            addLocalPrivateSystemMessage("payment request expired", to: threadID)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(prompt.expiresAtMs - nowMs) / 1000.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pendingAgentPayments.removeValue(forKey: requestID)
                self.agentPaymentExpiryTimers.removeValue(forKey: requestID)
                self.clearDeferredAgentResponses(for: requestID)
                self.inboundFairExchangeAssemblies.removeValue(forKey: requestID)
                self.inboundFairExchangeOffers.removeValue(forKey: requestID)
                self.inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
                self.agentPaymentStore.markFailed(requestID: requestID, details: "payment request expired")
                self.setAgentSessionPaymentState(sessionID: prompt.sessionID, threadID: threadID, state: .failed)
                self.addLocalPrivateSystemMessage("payment request expired", to: threadID)
            }
        }
        agentPaymentExpiryTimers[requestID] = timer
    }

    @MainActor
    func cancelPaymentPromptExpiry(requestID: String) {
        if let timer = agentPaymentExpiryTimers.removeValue(forKey: requestID) {
            timer.invalidate()
        }
    }

    @MainActor
    func paymentPrompt(for requestID: String) -> AgentPaymentPrompt? {
        pendingAgentPayments[requestID]
    }

    @MainActor
    func payPendingAgentRequest(requestID: String) -> CommandResult {
        guard !inFlightAgentPaymentRequestIDs.contains(requestID) else {
            return .error(message: "payment already in progress")
        }
        inFlightAgentPaymentRequestIDs.insert(requestID)
        Task { [weak self] in
            guard let self else { return }
            await self.payPendingAgentRequestAsync(requestID: requestID)
        }
        return .handled
    }

    @MainActor
    private func payPendingAgentRequestAsync(requestID: String) async {
        defer { inFlightAgentPaymentRequestIDs.remove(requestID) }
        guard agentMeshFlags.enablePayments else {
            addSystemMessage("payments are disabled")
            return
        }
        guard let prompt = pendingAgentPayments[requestID] else {
            addSystemMessage("no pending payment for request")
            return
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard nowMs < prompt.expiresAtMs else {
            pendingAgentPayments.removeValue(forKey: requestID)
            cancelPaymentPromptExpiry(requestID: requestID)
            clearDeferredAgentResponses(for: requestID)
            inboundFairExchangeAssemblies.removeValue(forKey: requestID)
            inboundFairExchangeOffers.removeValue(forKey: requestID)
            inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
            let threadID = pendingAgentRequests[requestID]?.threadID
                ?? (prompt.sessionID.flatMap { agentThreadsBySessionID[$0] })
                ?? prompt.peerID
            setAgentSessionPaymentState(sessionID: prompt.sessionID, threadID: threadID, state: .failed)
            addLocalPrivateSystemMessage("payment request expired", to: threadID)
            return
        }

        let thread = pendingAgentRequests[requestID]?.threadID
            ?? (prompt.sessionID.flatMap { agentThreadsBySessionID[$0] })
            ?? prompt.peerID

        do {
            Task {
                let mintHint = URL(string: prompt.mintURL)?.host ?? prompt.mintURL
                await SupportEventLog.shared.record(category: "payment", message: "pay start id=\(requestID.prefix(8)) rail=\(prompt.rail.rawValue) mint=\(mintHint) amount=\(prompt.amount)\(prompt.unit)")
            }
            let proxyRequestClosure: (@Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket)? = {
                guard self.agentMeshFlags.enableGateway else { return nil }
                return { [weak self] request in
                    guard let self else { throw MintGatewayProxyError.unavailable }
                    return try await self.requestMintProxyViaMesh(request)
                }
            }()

            let packet = try await agentPaymentBridge.prepareOutboundPaymentPayload(
                requestID: requestID,
                sessionID: prompt.sessionID,
                paymentRequest: prompt.paymentRequest,
                enablePaymentLocking: agentMeshFlags.enablePaymentLocking,
                enableX402Payments: agentMeshFlags.enableX402Payments,
                allowGatewayRelockFallback: agentMeshFlags.enableGateway,
                sendProxyRequest: proxyRequestClosure
            )
            meshService.sendAgentPaymentPayload(packet, to: prompt.peerID)
            notifyWalletStateChanged(
                reason: "outbound-payload-sent",
                requestID: requestID,
                rail: prompt.rail
            )
            setAgentSessionPaymentState(sessionID: prompt.sessionID, threadID: thread, state: .paid)
            Task { await SupportEventLog.shared.record(category: "payment", message: "pay sent id=\(requestID.prefix(8)) to=\(prompt.peerID.id)") }
            if let trancheIndex = prompt.trancheIndex, let trancheCount = prompt.trancheCount {
                addLocalPrivateSystemMessage("payment sent for tranche \(trancheIndex)/\(trancheCount); waiting for receipt", to: thread)
            } else {
                addLocalPrivateSystemMessage("payment sent; waiting for receipt", to: thread)
            }
        } catch {
            Task { await SupportEventLog.shared.record(category: "payment", message: "pay failed id=\(requestID.prefix(8)) err=\(error.localizedDescription)") }
            addLocalPrivateSystemMessage("payment failed: \(error.localizedDescription)", to: thread)
        }
    }

    @MainActor
    func handleAgentPaymentReceipt(_ receipt: AgentPaymentReceiptPacket, from peerID: PeerID) {
        guard pendingAgentPayments[receipt.requestID] != nil || agentPaymentStore.record(for: receipt.requestID) != nil else {
            return
        }

        if let prompt = pendingAgentPayments[receipt.requestID], prompt.sessionID != receipt.sessionID {
            let threadID = pendingAgentRequests[receipt.requestID]?.threadID
                ?? (prompt.sessionID.flatMap { agentThreadsBySessionID[$0] })
                ?? prompt.peerID
            addLocalPrivateSystemMessage("ignoring payment receipt with mismatched session", to: threadID)
            return
        }

        let activePrompt = pendingAgentPayments[receipt.requestID]
        let matchesActivePrompt: Bool = {
            guard let activePrompt else { return true }
            guard let receiptPaymentID = receipt.paymentID else { return true }
            return activePrompt.paymentID == receiptPaymentID
        }()

        agentPaymentBridge.applyReceipt(receipt)
        let threadID = pendingAgentRequests[receipt.requestID]?.threadID
            ?? (receipt.sessionID.flatMap { agentThreadsBySessionID[$0] })
            ?? peerID
        let rail: AgentPaymentRail = (activePrompt?.rail ?? .cashu)
        notifyWalletStateChanged(
            reason: "receipt-updated",
            requestID: receipt.requestID,
            rail: rail
        )

        let statusText: String
        switch receipt.status {
        case .acceptedOffline:
            if receipt.notaryReceipts.isEmpty {
                statusText = "payment accepted offline"
            } else {
                statusText = "payment accepted offline (\(receipt.notaryReceipts.count) notary)"
            }
            setAgentSessionPaymentState(sessionID: receipt.sessionID, threadID: threadID, state: .acceptedOffline)
        case .finalizedOnline:
            statusText = "payment finalized online"
            setAgentSessionPaymentState(sessionID: receipt.sessionID, threadID: threadID, state: .finalized)
        case .rejected:
            statusText = "payment rejected"
            setAgentSessionPaymentState(sessionID: receipt.sessionID, threadID: threadID, state: .failed)
        }

        let detailsSuffix = receipt.details?.isEmpty == false ? ": \(receipt.details!)" : ""
        addLocalPrivateSystemMessage("\(statusText)\(detailsSuffix)", to: threadID)
        Task {
            await SupportEventLog.shared.record(
                category: "payment",
                message: "receipt id=\(receipt.requestID.prefix(8)) status=\(receipt.status.rawValue)"
            )
        }

        if !matchesActivePrompt {
            // A stale receipt can arrive after we already rotated to the next tranche prompt.
            return
        }

        let unlockedEncryptedResponse = applyFairExchangeUnlockIfPresent(receipt: receipt, from: peerID, threadID: threadID)

        if receipt.status != .rejected {
            pendingAgentPayments.removeValue(forKey: receipt.requestID)
            cancelPaymentPromptExpiry(requestID: receipt.requestID)
            if unlockedEncryptedResponse {
                clearDeferredAgentResponses(for: receipt.requestID)
            } else {
                flushDeferredAgentResponses(for: receipt.requestID)
            }
            resumeAgentStreamingAfterPayment(requestID: receipt.requestID, sessionID: receipt.sessionID)
        } else {
            clearDeferredAgentResponses(for: receipt.requestID)
            inboundFairExchangeUnlockTokens.removeValue(forKey: receipt.requestID)
            resumeAgentStreamingAfterPayment(requestID: receipt.requestID, sessionID: receipt.sessionID)
        }
    }

    @MainActor
    private func paymentReceiptStatus(for state: AgentPaymentState) -> AgentPaymentReceiptStatus? {
        switch state {
        case .acceptedOffline:
            return .acceptedOffline
        case .finalizedOnline:
            return .finalizedOnline
        case .rejected, .failed:
            return .rejected
        case .paymentRequested, .payloadSent:
            return nil
        }
    }

    @MainActor
    private func applyFairExchangeUnlockIfPresent(
        receipt: AgentPaymentReceiptPacket,
        from peerID: PeerID,
        threadID: PeerID
    ) -> Bool {
        guard receipt.status != .rejected else { return false }
        guard let unlockToken = receipt.fairUnlockKey else { return false }
        inboundFairExchangeUnlockTokens[receipt.requestID] = unlockToken
        return tryUnlockFairExchangeOffer(
            requestID: receipt.requestID,
            unlockToken: unlockToken,
            from: peerID,
            threadID: threadID
        )
    }

    @MainActor
    private func tryUnlockFairExchangeOffer(
        requestID: String,
        unlockToken: String,
        from peerID: PeerID,
        threadID: PeerID
    ) -> Bool {
        guard let locked = inboundFairExchangeOffers[requestID],
              let envelope = agentFairExchangeService.decodeOfferIfPresent(locked.offer),
              envelope.requestID == requestID else {
            return false
        }

        do {
            let plaintext = try agentFairExchangeService.decrypt(
                offer: locked.offer,
                unlockToken: unlockToken,
                requestID: envelope.requestID,
                paymentID: envelope.paymentID,
                sessionID: envelope.sessionID
            )
            let context = pendingAgentRequests[requestID]
            let role = context?.role ?? unifiedPeerService.getPeer(by: peerID)?.agentInfo?.role ?? "agent"
            let agentName: String = {
                if let name = context?.targetNickname { return name }
                if let sessionID = envelope.sessionID ?? locked.sessionID,
                   let thread = agentThreadsBySessionID[sessionID],
                   let session = agentSessionsByThread[thread] {
                    return session.peerNickname
                }
                return unifiedPeerService.getPeer(by: peerID)?.nickname ?? "agent"
            }()
            let resolvedThreadID = context?.threadID
                ?? (envelope.sessionID.flatMap { agentThreadsBySessionID[$0] })
                ?? locked.peerID

            upsertAgentResponseDM(
                requestID: requestID,
                role: role,
                content: plaintext,
                peerID: resolvedThreadID,
                peerNickname: agentName,
                outgoing: false,
                isError: false,
                markUnread: true
            )

            if let sessionID = envelope.sessionID ?? locked.sessionID {
                appendAgentSessionHistory(sessionID: sessionID, role: "assistant", content: plaintext)
            }

            inboundFairExchangeOffers.removeValue(forKey: requestID)
            inboundFairExchangeAssemblies.removeValue(forKey: requestID)
            inboundFairExchangeUnlockTokens.removeValue(forKey: requestID)
            _ = pendingAgentRequests.removeValue(forKey: requestID)
            return true
        } catch {
            addLocalPrivateSystemMessage("payment unlock failed: \(error.localizedDescription)", to: threadID)
            return false
        }
    }

    @MainActor
    private func sendStoredPaymentReceiptIfAvailable(for packet: AgentPaymentPayloadPacket, from peerID: PeerID) -> Bool {
        guard let record = agentPaymentStore.record(for: packet.requestID), record.peerID == peerID.id else {
            return false
        }

        if let sessionID = record.sessionID, sessionID != packet.sessionID {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: nil,
                status: .rejected,
                details: "payment session does not match request",
                nullifiers: [],
                notaryReceipts: []
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            return true
        }

        if let status = paymentReceiptStatus(for: record.state) {
            let receipt = AgentPaymentReceiptPacket(
                requestID: record.requestID,
                sessionID: record.sessionID ?? packet.sessionID,
                paymentID: record.paymentID,
                status: status,
                details: record.details,
                nullifiers: record.nullifiers,
                notaryReceipts: record.notaryReceipts
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            return true
        }

        let receipt = AgentPaymentReceiptPacket(
            requestID: packet.requestID,
            sessionID: packet.sessionID,
            paymentID: record.paymentID,
            status: .rejected,
            details: "payment request no longer active",
            nullifiers: record.nullifiers,
            notaryReceipts: []
        )
        meshService.sendAgentPaymentReceipt(receipt, to: peerID)
        return true
    }

    @MainActor
    func handleAgentPaymentPayload(_ packet: AgentPaymentPayloadPacket, from peerID: PeerID) {
        let decodedCashuPayload = CashuPaymentPayloadEnvelope.decode(fromJSONString: packet.payload)
        let decodedX402Payload = X402PaymentPayloadEnvelope.decode(from: packet.payload)
        let decodedPaymentID = decodedCashuPayload?.paymentID ?? decodedX402Payload?.paymentID

        guard let pending = pendingInboundPaymentRequests[packet.requestID], pending.peerID == peerID else {
            if sendStoredPaymentReceiptIfAvailable(for: packet, from: peerID) {
                return
            }
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: decodedPaymentID,
                status: .rejected,
                details: "unknown request",
                nullifiers: [],
                notaryReceipts: []
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            return
        }

        guard packet.sessionID == pending.session.sessionID else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: decodedPaymentID,
                status: .rejected,
                details: "payment session does not match request",
                nullifiers: [],
                notaryReceipts: []
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            return
        }

        guard let terms = pending.localInfo.paymentTerms?.sanitized() else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: decodedPaymentID,
                status: .rejected,
                details: "provider payments disabled",
                nullifiers: [],
                notaryReceipts: []
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            return
        }

        let payloadEnvelope = decodedCashuPayload
        if let payloadEnvelope,
           let conflictNullifier = agentSettlementGossip.firstConflictingNullifier(
                paymentID: payloadEnvelope.paymentID,
                mintURL: payloadEnvelope.mintURL,
                unit: payloadEnvelope.unit,
                nullifiers: payloadEnvelope.nullifiers
           ) {
            let details = "payment nullifier already observed in settlement gossip"
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: details,
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: []
            )
            agentPaymentStore.markReceipt(
                requestID: packet.requestID,
                status: .rejected,
                details: details,
                nullifiers: payloadEnvelope.nullifiers
            )
            meshService.sendAgentPaymentReceipt(receipt, to: peerID)
            if let conflictContent = agentSettlementGossip.makeSpendConflictContent(
                nullifier: conflictNullifier,
                evidence: "incoming payment matched existing nullifier"
            ) {
                sendSettlementMeshMessage(conflictContent)
                sendSettlementGlobalMessage(conflictContent)
            }
            addLocalPrivateSystemMessage("payment rejected: \(details)", to: pending.session.threadID)
            return
        }

        let inboundProcessingKey = "\(peerID.id)|\(packet.requestID)"
        if inFlightInboundPaymentRequestKeys.contains(inboundProcessingKey) {
            return
        }
        inFlightInboundPaymentRequestKeys.insert(inboundProcessingKey)

        addLocalPrivateSystemMessage("payment received; validating…", to: pending.session.threadID)

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.inFlightInboundPaymentRequestKeys.remove(inboundProcessingKey)
                }
            }
            let notaryRequirement = self.offlineNotaryRequirement(for: terms)
            let evaluation = await self.agentPaymentBridge.evaluateIncomingPaymentDetailed(
                packet: packet,
                from: peerID,
                terms: terms,
                enablePaymentLocking: self.agentMeshFlags.enablePaymentLocking,
                enableX402Payments: self.agentMeshFlags.enableX402Payments,
                x402GatewayToken: self.agentConfig.runtime.gatewayToken,
                notaryRequirement: notaryRequirement
            ) { context in
                await self.collectOfflineNotaryReceipts(context: context)
            }
            let receipt = evaluation.receipt
            await MainActor.run {
                let fairPlan = self.providerFairExchangePlans[packet.requestID]
                let receiptPaymentID = receipt.paymentID ?? decodedPaymentID
                let shouldAttachUnlock = evaluation.shouldAdvanceFlow
                    && (receipt.status == .acceptedOffline || receipt.status == .finalizedOnline)
                    && fairPlan?.paymentID == receiptPaymentID
                    && fairPlan?.unlockToken != nil

                let outboundReceipt = AgentPaymentReceiptPacket(
                    requestID: receipt.requestID,
                    sessionID: receipt.sessionID,
                    paymentID: receipt.paymentID,
                    status: receipt.status,
                    details: receipt.details,
                    nullifiers: receipt.nullifiers,
                    notaryReceipts: receipt.notaryReceipts,
                    fairUnlockKey: shouldAttachUnlock ? fairPlan?.unlockToken : nil
                )

                self.meshService.sendAgentPaymentReceipt(outboundReceipt, to: peerID)
                switch outboundReceipt.status {
                case .acceptedOffline, .finalizedOnline:
                    guard evaluation.shouldAdvanceFlow else { return }
                    let statusLine: String = {
                        switch outboundReceipt.status {
                        case .finalizedOnline:
                            return "payment accepted and finalized online"
                        case .acceptedOffline:
                            return "payment accepted offline; finalization queued"
                        case .rejected:
                            return "payment rejected"
                        }
                    }()
                    self.addLocalPrivateSystemMessage(statusLine, to: pending.session.threadID)
                    if let payloadEnvelope,
                       let announceContent = self.agentSettlementGossip.registerAcceptedPayment(
                            paymentID: payloadEnvelope.paymentID,
                            mintURL: payloadEnvelope.mintURL,
                            unit: payloadEnvelope.unit,
                            nullifiers: payloadEnvelope.nullifiers
                       ) {
                        self.sendSettlementMeshMessage(announceContent)
                        self.sendSettlementGlobalMessage(announceContent)
                    }
                    self.pendingInboundPaymentRequests.removeValue(forKey: packet.requestID)
                    self.cancelInboundPaymentExpiry(requestID: packet.requestID)
                    if self.providerTranchePlans[packet.requestID] != nil {
                        self.advanceProviderTrancheFlowAfterAcceptedPayment(
                            requestID: packet.requestID,
                            terms: terms
                        )
                    } else if self.providerFairExchangePlans[packet.requestID] != nil {
                        self.completeProviderFairExchangeAfterAcceptedPayment(requestID: packet.requestID)
                    } else {
                        self.runAgentRequestWithRuntime(
                            request: pending.request,
                            from: pending.peerID,
                            localInfo: pending.localInfo,
                            session: pending.session,
                            senderName: pending.senderName
                        )
                    }
                case .rejected:
                    self.addLocalPrivateSystemMessage(
                        "payment rejected: \(receipt.details ?? "unknown reason")",
                        to: pending.session.threadID
                    )
                }
            }
        }
    }

    @MainActor
    private func offlineNotaryRequirement(for terms: AgentPaymentTerms) -> AgentOfflineNotaryRequirement {
        guard terms.settlementMode == .offlineAccepted else {
            return .disabled
        }
        let policy = agentConfig.notaryPolicy
        let minimum = policy.effectiveRequiredOfflineSignatures
        guard minimum > 0 else {
            return .disabled
        }
        return AgentOfflineNotaryRequirement(
            minimumReceipts: minimum,
            timeoutMs: policy.effectiveCollectTimeoutMs
        )
    }

    @MainActor
    private func collectOfflineNotaryReceipts(context: AgentOfflineNotaryCollectionContext) async -> [String] {
        guard context.minimumReceipts > 0 else { return [] }

        if let requestContent = agentPaymentNotaryService.makeNotaryRequestContent(
            requestID: context.requestID,
            paymentID: context.paymentID,
            mintURL: context.mintURL,
            unit: context.unit,
            nullifiers: context.nullifiers,
            requesterPeerID: meshService.myPeerID.id
        ) {
            sendNotaryMeshMessage(requestContent)
            sendNotaryGlobalMessage(requestContent)
        }

        return await agentPaymentNotaryService.waitForReceipts(
            requestID: context.requestID,
            paymentID: context.paymentID,
            mintURL: context.mintURL,
            unit: context.unit,
            nullifiers: context.nullifiers,
            minCount: context.minimumReceipts,
            timeoutMs: context.timeoutMs
        ) { [weak self] encoded, receipt in
            guard let self else { return false }
            return self.validateNotaryReceipt(
                encodedReceipt: encoded,
                receipt: receipt,
                context: context
            )
        }
    }

    @MainActor
    private func validateNotaryReceipt(
        encodedReceipt: String,
        receipt: AgentPaymentNotaryService.NotaryReceipt,
        context: AgentOfflineNotaryCollectionContext
    ) -> Bool {
        guard let decoded = agentPaymentNotaryService.decodeReceipt(encodedReceipt), decoded == receipt else {
            return false
        }
        guard agentPaymentNotaryService.receiptContextMatches(
            receipt,
            requestID: context.requestID,
            paymentID: context.paymentID,
            mintURL: context.mintURL,
            unit: context.unit,
            nullifiers: context.nullifiers
        ) else {
            return false
        }
        guard let signature = Data(hexString: receipt.signature),
              let signingPublicKey = Data(hexString: receipt.notarySigningKey) else {
            return false
        }
        if receipt.notaryPeerID.lowercased() == meshService.myPeerID.id.lowercased() {
            return false
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if receipt.issuedAtMs > nowMs + 5_000 {
            return false
        }
        let maxAgeMs = UInt64(TransportConfig.notaryReceiptTTLSeconds * 1000)
        if nowMs > receipt.issuedAtMs, (nowMs - receipt.issuedAtMs) > maxAgeMs {
            return false
        }

        let payload = agentPaymentNotaryService.receiptSigningPayload(
            requestID: receipt.requestID,
            paymentID: receipt.paymentID,
            mintHint: receipt.mintHint,
            unit: receipt.unit,
            nullifierDigest: receipt.nullifierDigest,
            nullifierCount: Int(receipt.nullifierCount),
            notaryPeerID: receipt.notaryPeerID,
            notarySigningKey: receipt.notarySigningKey,
            issuedAtMs: receipt.issuedAtMs
        )

        return meshService.getNoiseService().verifySignature(
            signature,
            for: payload,
            publicKey: signingPublicKey
        )
    }

    @MainActor
    private func completeProviderFairExchangeAfterAcceptedPayment(requestID: String) {
        guard let plan = providerFairExchangePlans.removeValue(forKey: requestID) else {
            return
        }
        providerFairExchangePreparationRequestIDs.remove(requestID)

        let result = plan.runtimeResult
        appendAgentSessionHistory(sessionID: plan.session.sessionID, role: "assistant", content: result.response.content)
        addAgentResponseDM(
            requestID: requestID,
            role: plan.localInfo.role,
            content: result.response.content,
            peerID: plan.session.threadID,
            peerNickname: plan.senderName,
            outgoing: true,
            isError: result.response.isError
        )
        sendAgentResponseChunks(result.response, to: plan.peerID)
        sendAgentAttachments(result.attachments, session: plan.session)
        cacheAgentResponseIfNeeded(result.response, attachments: result.attachments)
        AgentMeshLogger.log(.responseSent(requestID: requestID, peerID: plan.peerID, isError: result.response.isError))
    }

    @MainActor
    private func advanceProviderTrancheFlowAfterAcceptedPayment(
        requestID: String,
        terms: AgentPaymentTerms
    ) {
        guard var plan = providerTranchePlans[requestID] else { return }
        guard plan.nextTrancheIndex < plan.trancheTexts.count else {
            providerTranchePlans.removeValue(forKey: requestID)
            return
        }

        let trancheIndex = plan.nextTrancheIndex
        let trancheText = plan.trancheTexts[trancheIndex]
        let isFinalTranche = trancheIndex == plan.trancheTexts.count - 1

        sendProviderTrancheChunks(plan: &plan, requestID: requestID, trancheText: trancheText, isFinalTranche: isFinalTranche)

        let deliveredText = plan.trancheTexts.prefix(trancheIndex + 1).joined()
        upsertAgentResponseDM(
            requestID: requestID,
            role: plan.localInfo.role,
            content: deliveredText,
            peerID: plan.session.threadID,
            peerNickname: plan.senderName,
            outgoing: true,
            isError: plan.isError,
            markUnread: false
        )

        if isFinalTranche {
            appendAgentSessionHistory(sessionID: plan.session.sessionID, role: "assistant", content: plan.fullResponse)
            sendAgentAttachments(plan.attachments, session: plan.session)
            let finalResponse = AgentResponsePacket(
                requestID: requestID,
                content: plan.fullResponse,
                isError: plan.isError,
                sessionID: plan.session.sessionID,
                chunkIndex: nil,
                chunkTotal: nil
            )
            cacheAgentResponseIfNeeded(finalResponse, attachments: plan.attachments)
            providerTranchePlans.removeValue(forKey: requestID)
            pendingInboundPaymentRequests.removeValue(forKey: requestID)
            cancelInboundPaymentExpiry(requestID: requestID)
            AgentMeshLogger.log(.responseSent(requestID: requestID, peerID: plan.peerID, isError: plan.isError))
            return
        }

        let nextIndex = trancheIndex + 1
        guard nextIndex < plan.trancheAmounts.count, nextIndex < plan.trancheTokenCounts.count else {
            providerTranchePlans.removeValue(forKey: requestID)
            return
        }

        let nextAmount = plan.trancheAmounts[nextIndex]
        let nextTokens = plan.trancheTokenCounts[nextIndex]
        guard let nextPaymentRequest = agentPaymentBridge.createPaymentRequest(
            requestID: requestID,
            sessionID: plan.session.sessionID,
            peerID: plan.peerID,
            terms: terms,
            metadata: AgentPaymentRequestMetadata(
                amountOverride: nextAmount,
                pricingModel: .perToken,
                trancheIndex: UInt32(nextIndex + 1),
                trancheCount: UInt32(plan.trancheTexts.count),
                trancheTokenCount: nextTokens,
                outputTokenPrice: terms.pricePerOutputToken,
                inputTokenPrice: terms.pricePerInputToken,
                minimumDeposit: terms.minDeposit
            ),
            enablePaymentLocking: agentMeshFlags.enablePaymentLocking,
            enableX402Payments: agentMeshFlags.enableX402Payments
        ) else {
            let response = AgentResponsePacket(
                requestID: requestID,
                content: "payment unavailable",
                isError: true,
                sessionID: plan.session.sessionID,
                chunkIndex: nil,
                chunkTotal: nil,
                paymentRequired: false,
                paymentRequest: nil,
                paymentError: "failed to build next tranche payment request"
            )
            addAgentResponseDM(
                requestID: response.requestID,
                role: plan.localInfo.role,
                content: response.content,
                peerID: plan.session.threadID,
                peerNickname: plan.senderName,
                outgoing: true,
                isError: true
            )
            sendAgentResponseChunks(response, to: plan.peerID)
            providerTranchePlans.removeValue(forKey: requestID)
            pendingInboundPaymentRequests.removeValue(forKey: requestID)
            cancelInboundPaymentExpiry(requestID: requestID)
            return
        }

        plan.nextTrancheIndex = nextIndex
        providerTranchePlans[requestID] = plan
        pendingInboundPaymentRequests[requestID] = PendingInboundPaymentRequest(
            request: plan.request,
            peerID: plan.peerID,
            session: plan.session,
            localInfo: plan.localInfo,
            senderName: plan.senderName,
            paymentRequest: nextPaymentRequest
        )
        scheduleInboundPaymentExpiry(
            requestID: requestID,
            sessionID: plan.session.sessionID,
            threadID: plan.session.threadID,
            paymentRequest: nextPaymentRequest
        )
        sendPaymentRequiredResponse(
            requestID: requestID,
            role: plan.localInfo.role,
            peerID: plan.peerID,
            sessionID: plan.session.sessionID,
            threadID: plan.session.threadID,
            senderName: plan.senderName,
            paymentRequest: nextPaymentRequest
        )
    }

    @MainActor
    private func sendProviderTrancheChunks(
        plan: inout ProviderTranchePlan,
        requestID: String,
        trancheText: String,
        isFinalTranche: Bool
    ) {
        let chunks = AgentMeshChunker.chunk(text: trancheText, maxBytes: AgentMeshConstants.maxTLVStringBytes)
        for (offset, chunkText) in chunks.enumerated() {
            let isLastChunk = offset == chunks.count - 1
            let packet = AgentResponseChunkPacket(
                requestID: requestID,
                index: plan.nextChunkIndex,
                isFinal: isFinalTranche && isLastChunk,
                content: chunkText,
                isError: plan.isError,
                sessionID: plan.session.sessionID
            )
            plan.nextChunkIndex = plan.nextChunkIndex &+ 1
            meshService.sendAgentResponseChunk(packet, to: plan.peerID)
        }
    }

    private func splitResponseIntoPaymentTranches(text: String, granularity: UInt32) -> (texts: [String], tokenCounts: [UInt32]) {
        let boundedGranularity = max(1, Int(granularity))
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: "\\S+\\s*", options: []) else {
            if text.isEmpty {
                return ([], [])
            }
            return ([text], [max(1, UInt32(estimatedTokenCount(text: text)))])
        }
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            if text.isEmpty {
                return ([], [])
            }
            return ([text], [1])
        }

        var texts: [String] = []
        var tokenCounts: [UInt32] = []
        var index = 0
        while index < matches.count {
            let upper = min(index + boundedGranularity, matches.count)
            guard let firstRange = Range(matches[index].range, in: text),
                  let lastRange = Range(matches[upper - 1].range, in: text) else {
                break
            }
            var chunk = String(text[firstRange.lowerBound..<lastRange.upperBound])
            if index == 0, firstRange.lowerBound > text.startIndex {
                chunk = String(text[text.startIndex..<firstRange.lowerBound]) + chunk
            }
            if upper == matches.count, lastRange.upperBound < text.endIndex {
                chunk += String(text[lastRange.upperBound..<text.endIndex])
            }
            texts.append(chunk)
            tokenCounts.append(UInt32(upper - index))
            index = upper
        }

        if texts.isEmpty {
            if text.isEmpty {
                return ([], [])
            }
            return ([text], [1])
        }
        return (texts, tokenCounts)
    }

    private func estimatedTokenCount(text: String) -> Int {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: "\\S+", options: []) else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? 0 : 1
        }
        let count = regex.numberOfMatches(in: text, options: [], range: fullRange)
        if count == 0 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 1
        }
        return count
    }

    private func safeMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : result
    }

    private func safeAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }

    @MainActor
    func handleAgentPayCommand(_ command: String) -> CommandResult? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/agentwallet" {
            let units = cashuWalletService.availableUnits()
            if units.isEmpty {
                return .success(message: "wallet empty")
            }
            let summary = units.map { unit in
                "\(unit)=\(cashuWalletService.balance(unit: unit))"
            }.joined(separator: " ")
            return .success(message: "wallet \(summary)")
        }

        if trimmed.hasPrefix("/agentpay ") {
            let requestID = String(trimmed.dropFirst("/agentpay ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestID.isEmpty else {
                return .error(message: "usage: /agentpay <requestID>")
            }
            return payPendingAgentRequest(requestID: requestID)
        }

        if trimmed.hasPrefix("/agentwallet import ") {
            let token = String(trimmed.dropFirst("/agentwallet import ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return .error(message: "usage: /agentwallet import <cashu_token>")
            }
            do {
                let imported = try cashuWalletService.importToken(token)
                return .success(message: "imported \(imported) units")
            } catch {
                return .error(message: error.localizedDescription)
            }
        }

        if trimmed.hasPrefix("/agentwallet export ") {
            let args = String(trimmed.dropFirst("/agentwallet export ".count))
                .split(separator: " ", omittingEmptySubsequences: true)
            guard args.count == 3,
                  let amount = UInt64(args[2]) else {
                return .error(message: "usage: /agentwallet export <mintURL> <unit> <amount>")
            }
            do {
                let token = try cashuWalletService.exportToken(
                    mintURL: String(args[0]),
                    unit: String(args[1]),
                    amount: amount
                )
                return .success(message: token)
            } catch {
                return .error(message: error.localizedDescription)
            }
        }

        if trimmed == "/agentwallet balance" {
            let total = cashuWalletService.balance()
            return .success(message: "wallet total=\(total)")
        }

        if trimmed.hasPrefix("/agentwallet balance ") {
            let args = String(trimmed.dropFirst("/agentwallet balance ".count))
                .split(separator: " ", omittingEmptySubsequences: true)
            if args.count == 1 {
                let mint = String(args[0])
                return .success(message: "wallet mint=\(mint) total=\(cashuWalletService.balance(mintURL: mint))")
            }
            if args.count >= 2 {
                let mint = String(args[0])
                let unit = String(args[1])
                return .success(message: "wallet mint=\(mint) unit=\(unit) total=\(cashuWalletService.balance(mintURL: mint, unit: unit))")
            }
            return .error(message: "usage: /agentwallet balance [mintURL] [unit]")
        }

        if trimmed.hasPrefix("/agentfilter") {
            return handleAgentFilterCommand(trimmed)
        }

        return nil
    }

    @MainActor
    private func handleAgentFilterCommand(_ command: String) -> CommandResult {
        let args = command.split(separator: " ", omittingEmptySubsequences: true)
        if args.count == 1 {
            return .success(message: "agent filter \(paymentFilter.description)")
        }
        if args.count == 2, args[1].lowercased() == "clear" {
            paymentFilter = .any
            return .success(message: "agent filter cleared")
        }
        guard args.count == 5 else {
            return .error(message: "usage: /agentfilter <rail|any> <unit|any> <maxPrice|any> <mode|any>")
        }

        let railArg = String(args[1]).lowercased()
        let unitArg = String(args[2]).lowercased()
        let maxArg = String(args[3]).lowercased()
        let modeArg = String(args[4]).lowercased()

        let rail: AgentPaymentRail?
        if railArg == "any" {
            rail = nil
        } else {
            rail = AgentPaymentRail(rawValue: railArg)
            if rail == nil { return .error(message: "invalid rail") }
        }

        let mode: AgentSettlementMode?
        if modeArg == "any" {
            mode = nil
        } else {
            mode = AgentSettlementMode(rawValue: modeArg)
            if mode == nil { return .error(message: "invalid settlement mode") }
        }

        let maxPrice: UInt64?
        if maxArg == "any" {
            maxPrice = nil
        } else {
            maxPrice = UInt64(maxArg)
            if maxPrice == nil { return .error(message: "invalid max price") }
        }

        paymentFilter = AgentPaymentFilter(
            rail: rail,
            unit: unitArg == "any" ? nil : unitArg,
            maxPricePerRequest: maxPrice,
            settlementMode: mode
        )
        return .success(message: "agent filter \(paymentFilter.description)")
    }

    @MainActor
    func runAgentRequestWithRuntime(
        request: AgentRequestPacket,
        from peerID: PeerID,
        localInfo: AgentInfo,
        session: AgentSession,
        senderName: String
    ) {
        let executionKey = providerRuntimeExecutionKey(
            requestID: request.requestID,
            peerID: peerID,
            sessionID: session.sessionID
        )
        guard beginProviderRuntimeExecution(key: executionKey) else {
            return
        }

        Task { [agentRuntime] in
            defer {
                Task { @MainActor in
                    self.endProviderRuntimeExecution(key: executionKey)
                }
            }
            let expected = Int(request.attachmentCount ?? 0)
            let requestStart = Date().addingTimeInterval(-self.agentAttachmentLookbackSeconds)
            let pendingAttachments = expected > 0
                ? await self.awaitAgentAttachments(
                    sessionID: session.sessionID,
                    peerID: peerID,
                    expected: expected,
                    since: requestStart
                )
                : []
            if expected > 0, pendingAttachments.count < expected {
                await MainActor.run {
                    let message = "missing attachments (\(pendingAttachments.count)/\(expected)); please retry"
                    let response = AgentResponsePacket(
                        requestID: request.requestID,
                        content: message,
                        isError: true,
                        sessionID: session.sessionID,
                        chunkIndex: nil,
                        chunkTotal: nil
                    )
                    self.addAgentResponseDM(
                        requestID: response.requestID,
                        role: localInfo.role,
                        content: message,
                        peerID: session.threadID,
                        peerNickname: senderName,
                        outgoing: true,
                        isError: true
                    )
                    self.sendAgentResponseChunks(response, to: peerID)
                    AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: true))
                }
                return
            }

            let runtimeAttachments = self.makeRuntimeAttachments(from: pendingAttachments)
            let allowStreaming = self.agentConfig.runtime.streamResponses && !(agentRuntime is GatewayAgentRuntime)
            if allowStreaming, let streamingRuntime = agentRuntime as? StreamingAgentRuntime {
                var assembled = ""
                var isError = false
                let stream = streamingRuntime.runStream(
                    request: request,
                    from: peerID,
                    localInfo: localInfo,
                    session: session,
                    attachments: runtimeAttachments
                )
                for await chunk in stream {
                    assembled += chunk.content
                    isError = isError || chunk.isError
                    let outbound = AgentResponseChunkPacket(
                        requestID: request.requestID,
                        index: chunk.index,
                        isFinal: chunk.isFinal,
                        content: chunk.content,
                        isError: chunk.isError,
                        sessionID: session.sessionID
                    )
                    await MainActor.run {
                        self.meshService.sendAgentResponseChunk(outbound, to: peerID)
                    }
                    if chunk.isFinal {
                        await MainActor.run {
                            let response = AgentResponsePacket(
                                requestID: request.requestID,
                                content: assembled,
                                isError: isError,
                                sessionID: session.sessionID,
                                chunkIndex: nil,
                                chunkTotal: nil
                            )
                            self.appendAgentSessionHistory(sessionID: session.sessionID, role: "assistant", content: assembled)
                            self.addAgentResponseDM(
                                requestID: response.requestID,
                                role: localInfo.role,
                                content: response.content,
                                peerID: session.threadID,
                                peerNickname: senderName,
                                outgoing: true,
                                isError: response.isError
                            )
                            self.cacheAgentResponseIfNeeded(response, attachments: [])
                            AgentMeshLogger.log(.responseSent(requestID: response.requestID, peerID: peerID, isError: response.isError))
                        }
                    }
                }
                return
            }

            let result = await agentRuntime.run(request: request, from: peerID, localInfo: localInfo, session: session, attachments: runtimeAttachments)
            await MainActor.run {
                self.appendAgentSessionHistory(sessionID: session.sessionID, role: "assistant", content: result.response.content)
                self.addAgentResponseDM(
                    requestID: result.response.requestID,
                    role: localInfo.role,
                    content: result.response.content,
                    peerID: session.threadID,
                    peerNickname: senderName,
                    outgoing: true,
                    isError: result.response.isError
                )
                self.sendAgentResponseChunks(result.response, to: peerID)
                self.sendAgentAttachments(result.attachments, session: session)
                self.cacheAgentResponseIfNeeded(result.response, attachments: result.attachments)
                AgentMeshLogger.log(.responseSent(requestID: result.response.requestID, peerID: peerID, isError: result.response.isError))
            }
        }
    }
}
