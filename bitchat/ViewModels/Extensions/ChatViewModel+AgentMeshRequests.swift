//
// ChatViewModel+AgentMeshRequests.swift
// bitchat
//
// Reliability helpers for agent request lifecycle (TTL, retries, idempotency).
//

import Foundation

extension ChatViewModel {
    private var agentRequestRetryInterval: TimeInterval {
        TransportConfig.agentRequestRetryIntervalSeconds
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func requestExpiresAt(_ context: AgentRequestContext) -> Date {
        let created = Date(timeIntervalSince1970: TimeInterval(context.createdAtMs) / 1000.0)
        return created.addingTimeInterval(TimeInterval(context.ttlMs) / 1000.0)
    }

    @MainActor
    func scheduleAgentRequestRetry(requestID: String) {
        guard agentRequestTimeouts[requestID] == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: agentRequestRetryInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentRequestTimeouts.removeValue(forKey: requestID)
                self.retryAgentRequest(requestID: requestID)
            }
        }
        agentRequestTimeouts[requestID] = timer
    }

    @MainActor
    func cancelAgentRequestRetry(requestID: String) {
        if let timer = agentRequestTimeouts.removeValue(forKey: requestID) {
            timer.invalidate()
        }
    }

    @MainActor
    func retryAgentRequest(requestID: String) {
        guard var context = pendingAgentRequests[requestID] else { return }
        let expiresAt = requestExpiresAt(context)
        let now = Date()
        if now >= expiresAt || context.retriesLeft <= 0 {
            pendingAgentRequests.removeValue(forKey: requestID)
            pendingAgentPayments.removeValue(forKey: requestID)
            pendingInboundPaymentRequests.removeValue(forKey: requestID)
            clearDeferredAgentResponses(for: requestID)
            if let timer = agentPaymentExpiryTimers.removeValue(forKey: requestID) { timer.invalidate() }
            if let timer = inboundPaymentExpiryTimers.removeValue(forKey: requestID) { timer.invalidate() }
            agentRetryQueue.remove(requestID: requestID, peerID: context.targetPeerID)
            addLocalPrivateSystemMessage("agent request timed out", to: context.threadID)
            AgentMeshLogger.log(.responseReceived(requestID: requestID, peerID: context.targetPeerID, isError: true))
            return
        }

        let isReachable = meshService.isPeerConnected(context.targetPeerID) || meshService.isPeerReachable(context.targetPeerID)
        if isReachable {
            context.retriesLeft -= 1
            pendingAgentRequests[requestID] = context
            let retryRequest = AgentRequestPacket(
                requestID: requestID,
                role: context.role,
                prompt: context.prompt,
                sessionID: context.sessionID,
                attachmentCount: context.attachmentCount,
                senderAlias: context.senderAlias,
                createdAtMs: context.createdAtMs,
                ttlMs: context.ttlMs,
                quoteID: context.quoteID,
                quoteOptionID: context.quoteOptionID
            )
            meshService.sendAgentRequest(retryRequest, to: context.targetPeerID)
            if !context.draftAttachments.isEmpty {
                let delay = max(0.2, 0.2 * Double(context.draftAttachments.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendDraftAttachments(
                        context.draftAttachments,
                        threadPeer: context.threadID,
                        targetPeer: context.targetPeerID,
                        contextID: context.sessionID
                    )
                }
            }
            AgentMeshLogger.log(.requestSent(requestID: requestID, role: context.role, peerID: context.targetPeerID))
        } else {
            agentRetryQueue.enqueue(requestID: requestID, peerID: context.targetPeerID, expiresAt: expiresAt)
        }

        scheduleAgentRequestRetry(requestID: requestID)
    }

    @MainActor
    func flushAgentRetryQueue(for peerID: PeerID) {
        let pending = agentRetryQueue.dequeueReady(for: peerID)
        for requestID in pending {
            retryAgentRequest(requestID: requestID)
        }
    }

    @MainActor
    func cacheAgentResponseIfNeeded(_ response: AgentResponsePacket, attachments: [AgentRuntimeAttachment]) {
        let totalBytes = attachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes <= TransportConfig.agentResponseCacheMaxBytes else { return }
        agentResponseCache[response.requestID] = AgentResponseCacheEntry(
            response: response,
            attachments: attachments,
            cachedAt: Date(),
            totalBytes: totalBytes
        )
        purgeAgentResponseCache()
    }

    @MainActor
    func cachedAgentResponse(for requestID: String) -> AgentResponseCacheEntry? {
        purgeAgentResponseCache()
        return agentResponseCache[requestID]
    }

    @MainActor
    private func purgeAgentResponseCache() {
        let cutoff = Date().addingTimeInterval(-TransportConfig.agentRequestIdempotencySeconds)
        agentResponseCache = agentResponseCache.filter { $0.value.cachedAt >= cutoff }
    }
}
