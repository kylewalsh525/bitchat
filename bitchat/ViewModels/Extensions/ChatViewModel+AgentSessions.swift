//
// ChatViewModel+AgentSessions.swift
// bitchat
//
// Agent session lifecycle and history helpers.
//

import Foundation
import BitLogger

extension ChatViewModel {
    @MainActor
    func startAgentSession(peerID: PeerID, role: String, peerNickname: String) -> AgentSession {
        let sessionID = UUID().uuidString
        return createAgentSession(sessionID: sessionID, peerID: peerID, role: role, peerNickname: peerNickname)
    }

    @MainActor
    func ensureAgentSession(peerID: PeerID, sessionID: String, role: String, peerNickname: String, senderAlias: String? = nil) -> AgentSession {
        let normalized = normalizeSessionID(sessionID)
        if let thread = agentThreadsBySessionID[normalized], let session = agentSessionsByThread[thread] {
            return session
        }
        return createAgentSession(sessionID: normalized, peerID: peerID, role: role, peerNickname: peerNickname, senderAlias: senderAlias)
    }

    @MainActor
    func resolveAgentSession(for threadID: PeerID) -> AgentSession? {
        agentSessionsByThread[threadID]
    }

    func resolveAgentThread(for peerID: PeerID, sessionID: String) -> PeerID? {
        if Thread.isMainThread {
            let normalized = normalizeSessionID(sessionID)
            return agentThreadsBySessionID[normalized] ?? PeerID(agentSessionID: normalized)
        }
        var result: PeerID?
        DispatchQueue.main.sync {
            let normalized = normalizeSessionID(sessionID)
            result = agentThreadsBySessionID[normalized] ?? PeerID(agentSessionID: normalized)
        }
        return result
    }

    @MainActor
    func appendAgentSessionHistory(sessionID: String, role: String, content: String) {
        let normalized = normalizeSessionID(sessionID)
        guard let thread = agentThreadsBySessionID[normalized] else { return }
        updateAgentSession(threadID: thread) { session in
            session.appendMessage(role: role, content: content, limit: agentSessionHistoryLimit)
        }
    }

    @MainActor
    func sendAgentSessionMessage(prompt: String, threadID: PeerID) {
        guard let session = agentSessionsByThread[threadID] else {
            addSystemMessage("agent session unavailable")
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let requestID = UUID().uuidString
        let attachmentCount = pendingAgentAttachmentCount
        pendingAgentAttachmentCount = nil
        let request = AgentRequestPacket(
            requestID: requestID,
            role: session.role,
            prompt: trimmedPrompt,
            sessionID: session.sessionID,
            attachmentCount: attachmentCount,
            senderAlias: session.senderAlias
        )

        pendingAgentRequests[requestID] = AgentRequestContext(
            role: session.role,
            targetPeerID: session.peerID,
            targetNickname: session.peerNickname,
            sessionID: session.sessionID,
            threadID: session.threadID,
            prompt: trimmedPrompt,
            sentAt: Date()
        )

        addAgentRequestDM(
            requestID: requestID,
            role: session.role,
            prompt: trimmedPrompt,
            peerID: session.threadID,
            peerNickname: session.peerNickname,
            outgoing: true
        )
        appendAgentSessionHistory(sessionID: session.sessionID, role: "user", content: trimmedPrompt)
        meshService.sendAgentRequest(request, to: session.peerID)
        AgentMeshLogger.log(.requestSent(requestID: requestID, role: session.role, peerID: session.peerID))
    }

    @MainActor
    func sendAgentResponseChunks(_ response: AgentResponsePacket, to peerID: PeerID) {
        let chunks = AgentMeshChunker.chunk(text: response.content, maxBytes: AgentMeshConstants.maxTLVStringBytes)
        guard chunks.count > 1 else {
            meshService.sendAgentResponse(response, to: peerID)
            return
        }

        let total = UInt16(chunks.count)
        let delayMs: Double = 40
        for (index, chunk) in chunks.enumerated() {
            let packet = AgentResponsePacket(
                requestID: response.requestID,
                content: chunk,
                isError: response.isError,
                sessionID: response.sessionID,
                chunkIndex: UInt16(index + 1),
                chunkTotal: total
            )
            let delay = (Double(index) * delayMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.meshService.sendAgentResponse(packet, to: peerID)
            }
        }
    }

    @MainActor
    func sendAgentAttachments(_ attachments: [AgentRuntimeAttachment], session: AgentSession) {
        guard !attachments.isEmpty else { return }

        for attachment in attachments {
            let mime = MimeType(attachment.mimeType) ?? .octetStream
            guard mime.isAllowed else {
                addSystemMessage("unsupported attachment type: \(attachment.mimeType)")
                continue
            }
            guard FileTransferLimits.isValidPayload(attachment.data.count) else {
                addSystemMessage("attachment too large to send")
                continue
            }

            guard let url = saveAgentAttachment(data: attachment.data, mime: mime, fileNameHint: attachment.fileName) else {
                addSystemMessage("failed to save attachment")
                continue
            }

            let marker: String
            switch mime.category {
            case .audio:
                marker = "[voice] \(url.lastPathComponent)"
            case .image:
                marker = "[image] \(url.lastPathComponent)"
            case .file:
                marker = "[file] \(url.lastPathComponent)"
            }

            let messageID = UUID().uuidString
            let message = BitchatMessage(
                id: messageID,
                sender: nickname,
                content: marker,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: session.peerNickname,
                senderPeerID: meshService.myPeerID,
                mentions: nil,
                deliveryStatus: .sending
            )

            addMessageToPrivateChatsIfNeeded(message, targetPeerID: session.threadID)
            let transferId = makeTransferID(messageID: messageID)
            registerTransfer(transferId: transferId, messageID: messageID)
            objectWillChange.send()

            let packet = BitchatFilePacket(
                fileName: url.lastPathComponent,
                fileSize: UInt64(attachment.data.count),
                mimeType: mime.mimeString,
                contextID: session.sessionID,
                content: attachment.data
            )
            guard let _ = packet.encode() else {
                addSystemMessage("failed to encode attachment")
                continue
            }
            meshService.sendFilePrivate(packet, to: session.peerID, transferId: transferId)
        }
    }

    @MainActor
    private func saveAgentAttachment(data: Data, mime: MimeType, fileNameHint: String) -> URL? {
        do {
            let base = try applicationFilesDirectory()
            let subdir: String
            switch mime.category {
            case .audio:
                subdir = "voicenotes/outgoing"
            case .image:
                subdir = "images/outgoing"
            case .file:
                subdir = "files/outgoing"
            }
            let directory = base.appendingPathComponent(subdir, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

            let safeName = (fileNameHint as NSString).lastPathComponent
            let fileName: String
            if safeName.isEmpty || safeName == "." || safeName == ".." {
                fileName = "agent_\(UUID().uuidString.prefix(8)).\(mime.defaultExtension)"
            } else {
                fileName = safeName
            }
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            SecureLogger.error("Failed to save agent attachment: \(error)", category: .session)
            return nil
        }
    }

    @MainActor
    func updateAgentSession(threadID: PeerID, mutate: (inout AgentSession) -> Void) {
        guard var session = agentSessionsByThread[threadID] else { return }
        mutate(&session)
        agentSessionsByThread[threadID] = session
    }

    @MainActor
    func agentSessionDisplayName(for threadID: PeerID) -> String {
        guard let session = agentSessionsByThread[threadID] else { return "agent" }
        if agentConfig.info == nil {
            return session.peerNickname
        }
        let suffix = session.sessionID.suffix(4)
        return "agent @\(session.peerNickname) #\(suffix)"
    }

    @MainActor
    private func createAgentSession(sessionID: String, peerID: PeerID, role: String, peerNickname: String, senderAlias: String? = nil) -> AgentSession {
        let normalized = normalizeSessionID(sessionID)
        let threadID = PeerID(agentSessionID: normalized)
        let alias = senderAlias ?? "anon-\(UUID().uuidString.prefix(8))"
        let session = AgentSession(
            sessionID: normalized,
            threadID: threadID,
            peerID: peerID,
            peerNickname: peerNickname,
            role: role,
            createdAt: Date(),
            senderAlias: alias,
            history: []
        )
        agentSessionsByThread[threadID] = session
        agentThreadsBySessionID[normalized] = threadID
        if privateChats[threadID] == nil {
            privateChats[threadID] = []
        }
        return session
    }
}
