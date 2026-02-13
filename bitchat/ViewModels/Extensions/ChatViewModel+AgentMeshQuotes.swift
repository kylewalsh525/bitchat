import Foundation

extension ChatViewModel {
    @MainActor
    func beginAgentQuoteSelectionIfNeeded(
        role: String,
        prompt: String,
        promptWithMemory: String,
        allowAnyRole: Bool,
        ttlOverrideMs: UInt32? = nil
    ) -> CommandResult? {
        let candidates = selectAgentCandidates(
            role: role,
            allowAnyRole: allowAnyRole,
            minimumQuality: 0,
            limit: TransportConfig.agentQuoteMaxCandidateProviders
        )
        guard !candidates.isEmpty else {
            return nil
        }

        let quoteCapable = candidates.filter { peer in
            guard let terms = peer.agentInfo?.paymentTerms?.sanitized() else { return false }
            guard terms.paymentRail != .none else { return false }
            // Tiered quote flow is per-request only in this milestone.
            return !terms.usesPerTokenPricing
        }
        guard !quoteCapable.isEmpty else { return nil }

        let quoteID = UUID().uuidString
        let createdAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let ttlMs = ttlOverrideMs ?? TransportConfig.agentRequestTTLms
        prunePendingQuoteSelections(nowMs: createdAtMs)
        prunePendingQuoteSelectionCapacity()

        let draftContextKey = pendingAgentDraftContextKeyForCommand()
        let draftAttachments = takePendingAgentDraftAttachments()
        let estimate = estimateAgentPromptTokens(promptWithMemory)

        pendingAgentQuoteSelections[quoteID] = PendingAgentQuoteSelection(
            quoteID: quoteID,
            role: role,
            prompt: prompt,
            promptWithMemory: promptWithMemory,
            allowAnyRole: allowAnyRole,
            createdAtMs: createdAtMs,
            ttlMs: ttlMs,
            draftContextKey: draftContextKey,
            draftAttachments: draftAttachments,
            expectedPeers: Set(quoteCapable.map(\.peerID)),
            respondedPeers: [],
            options: [],
            published: false
        )

        for peer in quoteCapable {
            let packet = AgentQuoteRequestPacket(
                quoteID: quoteID,
                role: role,
                prompt: promptWithMemory,
                estimatedInputTokens: estimate.input,
                estimatedOutputTokens: estimate.output,
                sentAt: createdAtMs,
                maxOptions: TransportConfig.agentQuoteDefaultMaxOptionsPerProvider
            )
            meshService.sendAgentQuoteRequest(packet, to: peer.peerID)
        }

        scheduleQuotePublishTimer(quoteID: quoteID)
        scheduleQuoteExpiryTimer(quoteID: quoteID, ttlMs: ttlMs)
        refreshActiveAgentQuoteSelections()
        return .success(
            message: "Collecting quotes from \(quoteCapable.count) provider(s). Quote ID: \(quoteID.prefix(8))…"
        )
    }

    @MainActor
    func handleAgentQuoteRequest(_ request: AgentQuoteRequestPacket, from peerID: PeerID) {
        guard let localInfo = agentConfig.info else { return }
        let requestedRole = request.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let anyRole = requestedRole == "any" || requestedRole == "*"
        guard anyRole || localInfo.normalizedRole == requestedRole else { return }
        guard let terms = localInfo.paymentTerms?.sanitized(),
              terms.paymentRail != .none else {
            sendAgentQuoteResponse(
                AgentQuoteResponsePacket(
                    quoteID: request.quoteID,
                    role: localInfo.role,
                    options: [],
                    expiresAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    error: "provider payments unavailable"
                ),
                to: peerID
            )
            return
        }

        guard !terms.usesPerTokenPricing else {
            sendAgentQuoteResponse(
                AgentQuoteResponsePacket(
                    quoteID: request.quoteID,
                    role: localInfo.role,
                    options: [],
                    expiresAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    error: "tiered quotes not supported for per-token pricing"
                ),
                to: peerID
            )
            return
        }

        let tierDefs = quoteTierDefinitions()
        let maxOptions = max(1, min(Int(request.maxOptions), tierDefs.count))
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let expiresAt = nowMs + UInt64(TransportConfig.agentQuoteLockSeconds * 1000)

        let options = tierDefs.prefix(maxOptions).map { tier -> AgentQuoteOption in
            let discounted = applyDiscount(
                amount: terms.pricePerRequest,
                discountBps: tier.discountBps
            )
            return AgentQuoteOption(
                optionID: "\(request.quoteID)-\(tier.id)-\(meshService.myPeerID.id.prefix(6))",
                label: tier.label,
                waitSeconds: tier.waitSeconds,
                discountBps: tier.discountBps,
                estimatedPrice: max(1, discounted),
                paymentRail: terms.paymentRail,
                unit: terms.unit,
                settlementMode: terms.settlementMode,
                requiresLocking: terms.requiresLocking,
                acceptedMints: terms.acceptedMints,
                requestTTLSeconds: terms.requestTTLSeconds,
                chainID: terms.x402ChainID,
                tokenAddress: terms.x402TokenAddress,
                qualityScore: localInfo.qualityScore,
                modelId: localInfo.modelId,
                modelHash: localInfo.modelHash
            )
        }

        providerQuoteCache[request.quoteID] = ProviderQuoteCacheEntry(
            peerID: peerID,
            role: localInfo.role,
            issuedAtMs: nowMs,
            expiresAtMs: expiresAt,
            optionsByID: Dictionary(uniqueKeysWithValues: options.map { ($0.optionID, $0) })
        )
        pruneProviderQuoteCache(nowMs: nowMs)

        sendAgentQuoteResponse(
            AgentQuoteResponsePacket(
                quoteID: request.quoteID,
                role: localInfo.role,
                options: options,
                expiresAt: expiresAt,
                error: nil
            ),
            to: peerID
        )
    }

    @MainActor
    func handleAgentQuoteResponse(_ response: AgentQuoteResponsePacket, from peerID: PeerID) {
        prunePendingQuoteSelections(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
        guard var pending = pendingAgentQuoteSelections[response.quoteID] else { return }
        guard pending.expectedPeers.contains(peerID) else { return }
        pending.respondedPeers.insert(peerID)

        if response.error == nil {
            let peerNickname = unifiedPeerService.getPeer(by: peerID)?.nickname ?? "agent"
            let mapped = response.options.map { option in
                AgentQuoteSelectionOption(
                    quoteID: response.quoteID,
                    optionID: option.optionID,
                    peerID: peerID,
                    peerNickname: peerNickname,
                    role: response.role,
                    waitSeconds: option.waitSeconds,
                    label: option.label,
                    estimatedPrice: option.estimatedPrice,
                    paymentRail: option.paymentRail,
                    unit: option.unit,
                    settlementMode: option.settlementMode,
                    requiresLocking: option.requiresLocking,
                    requestTTLSeconds: option.requestTTLSeconds,
                    chainID: option.chainID,
                    tokenAddress: option.tokenAddress,
                    qualityScore: option.qualityScore,
                    modelId: option.modelId,
                    modelHash: option.modelHash
                )
            }

            var deduped = pending.options
            for option in mapped {
                if let existingIndex = deduped.firstIndex(where: { $0.peerID == option.peerID && $0.optionID == option.optionID }) {
                    deduped[existingIndex] = option
                } else {
                    deduped.append(option)
                }
            }
            pending.options = deduped
        }

        pendingAgentQuoteSelections[response.quoteID] = pending
        refreshActiveAgentQuoteSelections()

        if pending.respondedPeers.count >= pending.expectedPeers.count, !pending.published {
            publishQuoteOptions(quoteID: response.quoteID)
        }
    }

    @MainActor
    func handleAgentChooseCommand(_ command: String) -> CommandResult? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/agentchoose") else { return nil }
        let args = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard args.count == 3 else {
            return .error(message: "usage: /agentchoose <quoteID> <optionIndex>")
        }

        let quoteID = String(args[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedIndex = Int(args[2]), selectedIndex > 0 else {
            return .error(message: "option index must be >= 1")
        }
        return selectAgentQuoteOptionByIndex(quoteID: quoteID, selectedIndex: selectedIndex, source: "command")
    }

    @MainActor
    func selectAgentQuoteOptionFromUI(quoteID: String, optionID: String) -> CommandResult {
        selectAgentQuoteOptionByID(quoteID: quoteID, optionID: optionID, source: "tap")
    }

    @MainActor
    func dismissPendingAgentQuote(quoteID: String) {
        guard let pending = pendingAgentQuoteSelections[quoteID] else { return }
        removePendingQuoteSelection(quoteID: quoteID, restoreDrafts: true)
        addSystemMessage("dismissed quote \(quoteID.prefix(8)) for role '\(pending.role)'")
    }

    @MainActor
    private func selectAgentQuoteOptionByIndex(
        quoteID: String,
        selectedIndex: Int,
        source: String
    ) -> CommandResult {
        prunePendingQuoteSelections(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
        guard let pending = pendingAgentQuoteSelections[quoteID] else {
            return .error(message: "quote id not found or expired")
        }

        if !pending.published {
            publishQuoteOptions(quoteID: quoteID)
            guard let republished = pendingAgentQuoteSelections[quoteID], republished.published else {
                return .error(message: "quotes still being collected; retry in a moment")
            }
        }

        guard let published = pendingAgentQuoteSelections[quoteID] else {
            return .error(message: "quote id not found or expired")
        }
        let sorted = sortedQuoteOptions(published.options)
        guard selectedIndex <= sorted.count else {
            return .error(message: "option index out of range (1-\(sorted.count))")
        }
        let option = sorted[selectedIndex - 1]
        return completeQuoteSelection(quoteID: quoteID, pending: published, option: option, source: source)
    }

    @MainActor
    private func selectAgentQuoteOptionByID(
        quoteID: String,
        optionID: String,
        source: String
    ) -> CommandResult {
        prunePendingQuoteSelections(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
        guard let pending = pendingAgentQuoteSelections[quoteID] else {
            return .error(message: "quote id not found or expired")
        }
        if !pending.published {
            publishQuoteOptions(quoteID: quoteID)
            guard let republished = pendingAgentQuoteSelections[quoteID], republished.published else {
                return .error(message: "quotes still being collected; retry in a moment")
            }
        }

        guard let published = pendingAgentQuoteSelections[quoteID] else {
            return .error(message: "quote id not found or expired")
        }
        guard let option = published.options.first(where: { $0.optionID == optionID }) else {
            return .error(message: "quote option not found")
        }
        return completeQuoteSelection(quoteID: quoteID, pending: published, option: option, source: source)
    }

    @MainActor
    private func completeQuoteSelection(
        quoteID: String,
        pending: PendingAgentQuoteSelection,
        option: AgentQuoteSelectionOption,
        source: String
    ) -> CommandResult {
        removePendingQuoteSelection(quoteID: quoteID, restoreDrafts: false)
        submitAgentRequest(from: pending, selected: option)
        return .success(
            message: "selected quote (\(source)): \(option.peerNickname) \(option.estimatedPrice) \(option.unit), \(option.label)"
        )
    }

    @MainActor
    private func autoPickQuoteOption(
        for pending: PendingAgentQuoteSelection,
        sortedOptions: [AgentQuoteSelectionOption]
    ) -> AgentQuoteSelectionOption? {
        let policy = agentRequesterPreferences.quoteAutoPickPolicy
        guard policy != .manual else { return nil }
        guard !sortedOptions.isEmpty else { return nil }

        switch policy {
        case .manual:
            return nil
        case .cheapest:
            return sortedOptions.min(by: cheapestAutoPickSort)
        case .fastest:
            return sortedOptions.min(by: fastestAutoPickSort)
        case .bestQualityUnderBudget:
            let budget = agentRequesterPreferences.quoteAutoPickBudget
            let capped = budget > 0 ? sortedOptions.filter { $0.estimatedPrice <= budget } : sortedOptions
            if capped.isEmpty {
                addSystemMessage("auto-pick skipped for \(pending.quoteID.prefix(8)): no options under budget")
                return nil
            }
            return capped.min(by: bestQualityUnderBudgetSort)
        }
    }

    @MainActor
    private func autoPickPolicyDescription(_ policy: AgentQuoteAutoPickPolicy) -> String {
        switch policy {
        case .manual:
            return "manual"
        case .cheapest:
            return "cheapest"
        case .fastest:
            return "fastest"
        case .bestQualityUnderBudget:
            let budget = agentRequesterPreferences.quoteAutoPickBudget
            if budget > 0 {
                return "best quality <= \(budget)"
            }
            return "best quality"
        }
    }

    private func cheapestAutoPickSort(_ lhs: AgentQuoteSelectionOption, _ rhs: AgentQuoteSelectionOption) -> Bool {
        if lhs.estimatedPrice != rhs.estimatedPrice { return lhs.estimatedPrice < rhs.estimatedPrice }
        if lhs.waitSeconds != rhs.waitSeconds { return lhs.waitSeconds < rhs.waitSeconds }
        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        return lhs.peerID.id < rhs.peerID.id
    }

    private func fastestAutoPickSort(_ lhs: AgentQuoteSelectionOption, _ rhs: AgentQuoteSelectionOption) -> Bool {
        if lhs.waitSeconds != rhs.waitSeconds { return lhs.waitSeconds < rhs.waitSeconds }
        if lhs.estimatedPrice != rhs.estimatedPrice { return lhs.estimatedPrice < rhs.estimatedPrice }
        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        return lhs.peerID.id < rhs.peerID.id
    }

    private func bestQualityUnderBudgetSort(_ lhs: AgentQuoteSelectionOption, _ rhs: AgentQuoteSelectionOption) -> Bool {
        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        if lhs.estimatedPrice != rhs.estimatedPrice { return lhs.estimatedPrice < rhs.estimatedPrice }
        if lhs.waitSeconds != rhs.waitSeconds { return lhs.waitSeconds < rhs.waitSeconds }
        return lhs.peerID.id < rhs.peerID.id
    }

    @MainActor
    func quotedAmountOverrideValidation(
        request: AgentRequestPacket,
        from peerID: PeerID
    ) -> (amount: UInt64?, waitSeconds: UInt16, error: String?) {
        pruneProviderQuoteCache(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))

        guard request.quoteID != nil || request.quoteOptionID != nil else {
            return (nil, 0, nil)
        }
        guard let quoteID = request.quoteID,
              let quoteOptionID = request.quoteOptionID else {
            return (nil, 0, "invalid quote selection")
        }
        guard let cached = providerQuoteCache[quoteID] else {
            return (nil, 0, "quote expired or unknown")
        }
        guard cached.peerID == peerID else {
            return (nil, 0, "quote not issued for this requester")
        }
        guard let option = cached.optionsByID[quoteOptionID] else {
            return (nil, 0, "quote option not found")
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let eligibleAtMs = cached.issuedAtMs + (UInt64(option.waitSeconds) * 1000)
        if nowMs < eligibleAtMs {
            return (nil, option.waitSeconds, "quote wait window not reached")
        }
        return (option.estimatedPrice, option.waitSeconds, nil)
    }

    @MainActor
    private func submitAgentRequest(from pending: PendingAgentQuoteSelection, selected: AgentQuoteSelectionOption) {
        let requestID = UUID().uuidString
        let alias = "anon-\(UUID().uuidString.prefix(8))"
        let session = startAgentSession(peerID: selected.peerID, role: selected.role, peerNickname: alias)
        let attachmentCount = pending.draftAttachments.isEmpty ? nil : UInt8(min(pending.draftAttachments.count, 255))
        let waitTTLms = UInt64(selected.waitSeconds) * 1000 + UInt64(TransportConfig.agentRequestTTLms)
        let effectiveTTLms = UInt32(min(UInt64(UInt32.max), max(UInt64(pending.ttlMs), waitTTLms)))

        let request = AgentRequestPacket(
            requestID: requestID,
            role: selected.role,
            prompt: pending.promptWithMemory,
            sessionID: session.sessionID,
            attachmentCount: attachmentCount,
            senderAlias: session.senderAlias,
            createdAtMs: pending.createdAtMs,
            ttlMs: effectiveTTLms,
            quoteID: selected.quoteID,
            quoteOptionID: selected.optionID
        )
        pendingAgentRequests[requestID] = AgentRequestContext(
            role: selected.role,
            targetPeerID: selected.peerID,
            targetNickname: session.peerNickname,
            sessionID: session.sessionID,
            threadID: session.threadID,
            prompt: pending.promptWithMemory,
            attachmentCount: attachmentCount,
            senderAlias: session.senderAlias,
            quoteID: selected.quoteID,
            quoteOptionID: selected.optionID,
            draftAttachments: pending.draftAttachments,
            createdAtMs: pending.createdAtMs,
            ttlMs: effectiveTTLms,
            retriesLeft: TransportConfig.agentRequestMaxRetries,
            sentAt: Date()
        )
        addAgentRequestDM(
            requestID: requestID,
            role: selected.role,
            prompt: pending.prompt,
            peerID: session.threadID,
            peerNickname: session.peerNickname,
            outgoing: true
        )
        selectedPrivateChatPeer = session.threadID

        let sendRequest: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard self.pendingAgentRequests[requestID] != nil else { return }

            self.meshService.sendAgentRequest(request, to: selected.peerID)
            self.scheduleAgentRequestRetry(requestID: requestID)

            if !pending.draftAttachments.isEmpty {
                let delay = max(0.2, 0.2 * Double(pending.draftAttachments.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendDraftAttachments(
                        pending.draftAttachments,
                        threadPeer: session.threadID,
                        targetPeer: session.peerID,
                        contextID: session.sessionID
                    )
                }
            }
            AgentMeshLogger.log(.requestSent(requestID: requestID, role: selected.role, peerID: selected.peerID))
        }

        if selected.waitSeconds > 0 {
            addSystemMessage("queued quote request for \(selected.peerNickname); sending in ~\(selected.waitSeconds)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(selected.waitSeconds))) {
                Task { @MainActor in
                    sendRequest()
                }
            }
        } else {
            sendRequest()
        }
    }

    @MainActor
    private func scheduleQuotePublishTimer(quoteID: String) {
        cancelQuotePublishTimer(quoteID: quoteID)
        let timer = Timer.scheduledTimer(withTimeInterval: TransportConfig.agentQuoteCollectionWindowSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentQuoteTimers.removeValue(forKey: quoteID)
                self.publishQuoteOptions(quoteID: quoteID)
            }
        }
        agentQuoteTimers[quoteID] = timer
    }

    @MainActor
    private func scheduleQuoteExpiryTimer(quoteID: String, ttlMs: UInt32) {
        cancelQuoteExpiryTimer(quoteID: quoteID)
        let interval = max(0.2, TimeInterval(ttlMs) / 1000)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentQuoteExpiryTimers.removeValue(forKey: quoteID)
                self.expirePendingQuoteSelection(quoteID: quoteID)
            }
        }
        agentQuoteExpiryTimers[quoteID] = timer
    }

    @MainActor
    private func cancelQuotePublishTimer(quoteID: String) {
        if let timer = agentQuoteTimers.removeValue(forKey: quoteID) {
            timer.invalidate()
        }
    }

    @MainActor
    private func cancelQuoteExpiryTimer(quoteID: String) {
        if let timer = agentQuoteExpiryTimers.removeValue(forKey: quoteID) {
            timer.invalidate()
        }
    }

    @MainActor
    private func publishQuoteOptions(quoteID: String) {
        prunePendingQuoteSelections(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
        guard var pending = pendingAgentQuoteSelections[quoteID] else { return }
        guard !pending.published else { return }

        let sorted = Array(sortedQuoteOptions(pending.options).prefix(TransportConfig.agentQuoteMaxTotalOptions))
        guard !sorted.isEmpty else {
            removePendingQuoteSelection(quoteID: quoteID, restoreDrafts: true)
            addSystemMessage("No quotes arrived for role '\(pending.role)'. Try again in a moment.")
            return
        }

        pending.options = sorted
        pending.published = true
        pendingAgentQuoteSelections[quoteID] = pending
        refreshActiveAgentQuoteSelections()

        if let autoOption = autoPickQuoteOption(for: pending, sortedOptions: sorted) {
            let policyLabel = autoPickPolicyDescription(agentRequesterPreferences.quoteAutoPickPolicy)
            let result = completeQuoteSelection(
                quoteID: quoteID,
                pending: pending,
                option: autoOption,
                source: "auto: \(policyLabel)"
            )
            if case .success(let message) = result, let message {
                addSystemMessage(message)
            }
            return
        }

        var lines: [String] = []
        lines.append("quotes for role '\(pending.role)' (\(quoteID))")
        for (index, option) in sorted.enumerated() {
            let waitText = option.waitSeconds == 0 ? "immediate" : "~\(option.waitSeconds)s"
            lines.append("\(index + 1)) \(option.peerNickname) q\(option.qualityScore) \(waitText) \(option.estimatedPrice) \(option.unit) [\(option.modelId)]")
        }
        lines.append("choose with /agentchoose \(quoteID) <1-\(sorted.count)> or tap an option in the quote card")
        addSystemMessage(lines.joined(separator: "\n"))
    }

    private func sortedQuoteOptions(_ options: [AgentQuoteSelectionOption]) -> [AgentQuoteSelectionOption] {
        options.sorted { lhs, rhs in
            if lhs.estimatedPrice != rhs.estimatedPrice { return lhs.estimatedPrice < rhs.estimatedPrice }
            if lhs.waitSeconds != rhs.waitSeconds { return lhs.waitSeconds < rhs.waitSeconds }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
            return lhs.peerID.id < rhs.peerID.id
        }
    }

    private func estimateAgentPromptTokens(_ prompt: String) -> (input: UInt32, output: UInt32) {
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        let inputEstimate = max(8, min(4096, words + (words / 3)))
        let outputEstimate = max(32, min(8192, inputEstimate * 2))
        return (UInt32(inputEstimate), UInt32(outputEstimate))
    }

    private func quoteTierDefinitions() -> [(id: String, label: String, waitSeconds: UInt16, discountBps: UInt16)] {
        let policy = agentConfig.quoteTierPolicy.sanitized()
        return [
            ("immediate", "immediate", 0, policy.immediateDiscountBps),
            ("standard", "wait ~\(policy.standardWaitSeconds)s", policy.standardWaitSeconds, policy.standardDiscountBps),
            ("economy", "wait ~\(policy.economyWaitSeconds)s", policy.economyWaitSeconds, policy.economyDiscountBps)
        ]
    }

    private func applyDiscount(amount: UInt64, discountBps: UInt16) -> UInt64 {
        let clamped = UInt64(min(discountBps, 9_500))
        let remaining = UInt64(10_000) - clamped
        let (multiplied, overflow) = amount.multipliedReportingOverflow(by: remaining)
        if overflow {
            return UInt64.max / 10_000
        }
        return multiplied / 10_000
    }

    @MainActor
    private func sendAgentQuoteResponse(_ response: AgentQuoteResponsePacket, to peerID: PeerID) {
        meshService.sendAgentQuoteResponse(response, to: peerID)
    }

    @MainActor
    private func pruneProviderQuoteCache(nowMs: UInt64) {
        providerQuoteCache = providerQuoteCache.filter { _, value in
            value.expiresAtMs >= nowMs
        }
        if providerQuoteCache.count > TransportConfig.agentQuoteProviderCacheMaxEntries {
            let sortedKeys = providerQuoteCache
                .sorted { $0.value.expiresAtMs < $1.value.expiresAtMs }
                .map(\.key)
            let overflow = providerQuoteCache.count - TransportConfig.agentQuoteProviderCacheMaxEntries
            for key in sortedKeys.prefix(max(0, overflow)) {
                providerQuoteCache.removeValue(forKey: key)
            }
        }
    }

    @MainActor
    private func removePendingQuoteSelection(quoteID: String, restoreDrafts: Bool) {
        cancelQuotePublishTimer(quoteID: quoteID)
        cancelQuoteExpiryTimer(quoteID: quoteID)
        guard let pending = pendingAgentQuoteSelections.removeValue(forKey: quoteID) else {
            refreshActiveAgentQuoteSelections()
            return
        }
        if restoreDrafts {
            restorePendingAgentDraftAttachments(pending.draftAttachments, to: pending.draftContextKey)
        }
        refreshActiveAgentQuoteSelections()
    }

    @MainActor
    private func expirePendingQuoteSelection(quoteID: String) {
        guard let pending = pendingAgentQuoteSelections[quoteID] else { return }
        removePendingQuoteSelection(quoteID: quoteID, restoreDrafts: true)
        addSystemMessage("quote \(quoteID.prefix(8)) for role '\(pending.role)' expired; run /agent again")
    }

    @MainActor
    private func prunePendingQuoteSelections(nowMs: UInt64) {
        let expiredQuoteIDs = pendingAgentQuoteSelections.compactMap { quoteID, pending -> String? in
            nowMs > pending.createdAtMs + UInt64(pending.ttlMs) ? quoteID : nil
        }
        for quoteID in expiredQuoteIDs {
            expirePendingQuoteSelection(quoteID: quoteID)
        }
    }

    @MainActor
    private func prunePendingQuoteSelectionCapacity() {
        guard pendingAgentQuoteSelections.count >= TransportConfig.agentQuoteMaxPendingSelections else { return }
        let sorted = pendingAgentQuoteSelections
            .sorted { $0.value.createdAtMs < $1.value.createdAtMs }
            .map(\.key)
        let overflow = pendingAgentQuoteSelections.count - TransportConfig.agentQuoteMaxPendingSelections + 1
        for quoteID in sorted.prefix(max(0, overflow)) {
            removePendingQuoteSelection(quoteID: quoteID, restoreDrafts: true)
        }
    }

    @MainActor
    private func refreshActiveAgentQuoteSelections() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        activeAgentQuoteSelections = pendingAgentQuoteSelections.values
            .filter { $0.published && nowMs <= $0.createdAtMs + UInt64($0.ttlMs) }
            .map { pending in
                AgentQuoteSelectionSummary(
                    quoteID: pending.quoteID,
                    role: pending.role,
                    createdAtMs: pending.createdAtMs,
                    expiresAtMs: pending.createdAtMs + UInt64(pending.ttlMs),
                    options: sortedQuoteOptions(pending.options)
                )
            }
            .sorted { $0.createdAtMs > $1.createdAtMs }
    }
}
