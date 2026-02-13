//
// ChatViewModel+AgentMeshStreaming.swift
// bitchat
//
// Streaming response handling for agent mesh.
//

import Foundation

struct AgentStreamingBuffer {
    var text: String
    var lastIndex: UInt16
    var lastRenderedAt: Date
    var updatedAt: Date
    var isError: Bool
    var role: String
    var agentName: String
    var threadID: PeerID
    var sessionID: String?
}

extension ChatViewModel {
    @MainActor
    func handleAgentResponseChunk(_ chunk: AgentResponseChunkPacket, from peerID: PeerID) {
        let context = pendingAgentRequests[chunk.requestID]
        cancelAgentRequestRetry(requestID: chunk.requestID)
        if let context {
            agentRetryQueue.remove(requestID: chunk.requestID, peerID: context.targetPeerID)
        }

        let agentName: String = {
            if let name = context?.targetNickname {
                return name
            }
            if let sessionID = chunk.sessionID,
               let thread = agentThreadsBySessionID[sessionID],
               let session = agentSessionsByThread[thread] {
                return session.peerNickname
            }
            return unifiedPeerService.getPeer(by: peerID)?.nickname ?? "agent"
        }()
        let role = context?.role ?? unifiedPeerService.getPeer(by: peerID)?.agentInfo?.role ?? "agent"
        let sessionID = chunk.sessionID ?? context?.sessionID
        let threadID = context?.threadID ?? {
            guard let sessionID else { return peerID }
            let session = ensureAgentSession(peerID: peerID, sessionID: sessionID, role: role, peerNickname: agentName)
            return session.threadID
        }()

        if processInboundFairExchangeChunkIfNeeded(
            chunk,
            from: peerID,
            role: role,
            agentName: agentName,
            threadID: threadID
        ) {
            return
        }

        if pendingAgentPayments[chunk.requestID] != nil {
            deferAgentResponseChunk(chunk, from: peerID)
            return
        }

        let key = agentStreamingContextKey(requestID: chunk.requestID, sessionID: sessionID)
        agentStreamingPaymentPauseKeys.remove(key)
        let now = Date()
        let existing = agentStreamingBuffers[key]
        var buffer = existing ?? AgentStreamingBuffer(
            text: "",
            lastIndex: 0,
            lastRenderedAt: .distantPast,
            updatedAt: now,
            isError: false,
            role: role,
            agentName: agentName,
            threadID: threadID,
            sessionID: sessionID
        )

        if chunk.index <= buffer.lastIndex {
            return
        }

        buffer.text += chunk.content
        buffer.lastIndex = chunk.index
        buffer.updatedAt = now
        buffer.isError = buffer.isError || chunk.isError
        buffer.role = role
        buffer.agentName = agentName
        buffer.threadID = threadID
        buffer.sessionID = sessionID

        let shouldRender = chunk.isFinal
            || now.timeIntervalSince(buffer.lastRenderedAt) >= AgentMeshConstants.agentResponseStreamRenderIntervalSeconds

        if shouldRender {
            upsertAgentResponseDM(
                requestID: chunk.requestID,
                role: buffer.role,
                content: buffer.text,
                peerID: buffer.threadID,
                peerNickname: buffer.agentName,
                outgoing: false,
                isError: buffer.isError,
                markUnread: existing == nil
            )
            buffer.lastRenderedAt = now
        }

        agentStreamingBuffers[key] = buffer
        scheduleAgentStreamTimeout(requestID: chunk.requestID, sessionID: sessionID, role: buffer.role, agentName: buffer.agentName, threadID: buffer.threadID)

        if chunk.isFinal {
            cancelAgentStreamTimeout(requestID: chunk.requestID, sessionID: sessionID)
            if let sessionID = buffer.sessionID {
                appendAgentSessionHistory(sessionID: sessionID, role: "assistant", content: buffer.text)
            }
            agentStreamingBuffers.removeValue(forKey: key)
            agentStreamingRetries.remove(key)
            agentStreamingPaymentPauseKeys.remove(key)
            _ = pendingAgentRequests.removeValue(forKey: chunk.requestID)
            pendingAgentPayments.removeValue(forKey: chunk.requestID)
            clearDeferredAgentResponses(for: chunk.requestID)
            cancelPaymentPromptExpiry(requestID: chunk.requestID)
            AgentMeshLogger.log(.responseReceived(requestID: chunk.requestID, peerID: peerID, isError: buffer.isError))
        }
    }

    @MainActor
    func isStreamingAgentMessage(_ message: BitchatMessage) -> Bool {
        let requestID = extractRequestID(from: message.id)
        guard !requestID.isEmpty else { return false }
        return agentStreamingBuffers.keys.contains { $0.hasPrefix(requestID) }
    }

    private func extractRequestID(from messageID: String) -> String {
        if messageID.hasPrefix("agent-resp-in-") {
            return String(messageID.dropFirst("agent-resp-in-".count))
        }
        if messageID.hasPrefix("agent-resp-out-") {
            return String(messageID.dropFirst("agent-resp-out-".count))
        }
        if messageID.hasPrefix("agent-resp-") {
            return String(messageID.dropFirst("agent-resp-".count))
        }
        return ""
    }

    @MainActor
    func agentStreamingContextKey(requestID: String, sessionID: String?) -> String {
        if let sessionID {
            return "\(requestID)|\(sessionID)"
        }
        return requestID
    }

    private func streamingKey(requestID: String, sessionID: String?) -> String {
        agentStreamingContextKey(requestID: requestID, sessionID: sessionID)
    }

    @MainActor
    func pauseAgentStreamingForPayment(requestID: String, sessionID: String?) {
        let key = agentStreamingContextKey(requestID: requestID, sessionID: sessionID)
        agentStreamingPaymentPauseKeys.insert(key)
        if let timer = agentStreamingTimeouts.removeValue(forKey: key) {
            timer.invalidate()
        }
    }

    @MainActor
    func resumeAgentStreamingAfterPayment(requestID: String, sessionID: String?) {
        let key = agentStreamingContextKey(requestID: requestID, sessionID: sessionID)
        agentStreamingPaymentPauseKeys.remove(key)
        guard let buffer = agentStreamingBuffers[key] else { return }
        scheduleAgentStreamTimeout(
            requestID: requestID,
            sessionID: sessionID,
            role: buffer.role,
            agentName: buffer.agentName,
            threadID: buffer.threadID
        )
    }

    @MainActor
    private func scheduleAgentStreamTimeout(requestID: String, sessionID: String?, role: String, agentName: String, threadID: PeerID) {
        let key = streamingKey(requestID: requestID, sessionID: sessionID)
        guard !agentStreamingPaymentPauseKeys.contains(key) else { return }
        guard agentStreamingTimeouts[key] == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: AgentMeshConstants.agentResponseAssemblyTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentStreamingTimeouts.removeValue(forKey: key)
                if self.agentStreamingPaymentPauseKeys.contains(key) {
                    self.scheduleAgentStreamTimeout(
                        requestID: requestID,
                        sessionID: sessionID,
                        role: role,
                        agentName: agentName,
                        threadID: threadID
                    )
                    return
                }
                guard let buffer = self.agentStreamingBuffers[key] else {
                    self.retryAgentResponseIfStreamStalled(requestID: requestID, sessionID: sessionID, threadID: threadID)
                    return
                }
                guard Date().timeIntervalSince(buffer.updatedAt) >= AgentMeshConstants.agentResponseAssemblyTimeoutSeconds else { return }
                self.agentStreamingBuffers.removeValue(forKey: key)
                _ = self.pendingAgentRequests.removeValue(forKey: requestID)
                self.clearDeferredAgentResponses(for: requestID)
                let content = "(partial response; stream interrupted)\n\n\(buffer.text)"
                self.upsertAgentResponseDM(
                    requestID: requestID,
                    role: role,
                    content: content,
                    peerID: threadID,
                    peerNickname: agentName,
                    outgoing: false,
                    isError: true,
                    markUnread: true
                )
                AgentMeshLogger.log(.responseReceived(requestID: requestID, peerID: threadID, isError: true))
            }
        }
        agentStreamingTimeouts[key] = timer
    }

    @MainActor
    private func retryAgentResponseIfStreamStalled(requestID: String, sessionID: String?, threadID: PeerID) {
        let key = streamingKey(requestID: requestID, sessionID: sessionID)
        guard !agentStreamingRetries.contains(key) else { return }
        guard pendingAgentRequests[requestID] != nil else { return }
        agentStreamingRetries.insert(key)
        addLocalPrivateSystemMessage("retrying agent response...", to: threadID)
        retryAgentRequest(requestID: requestID)
    }

    @MainActor
    private func cancelAgentStreamTimeout(requestID: String, sessionID: String?) {
        let key = streamingKey(requestID: requestID, sessionID: sessionID)
        if let timer = agentStreamingTimeouts.removeValue(forKey: key) {
            timer.invalidate()
        }
    }
}
