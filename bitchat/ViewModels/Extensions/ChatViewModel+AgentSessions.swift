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
    func refreshAgentSessionHistory() {
        agentSessionHistory = agentSessionStore.listSessions()
    }

    @MainActor
    func wipeAllAgentSessions() {
        let activeWasAgentSession = selectedPrivateChatPeer?.isAgentSession == true
        agentSessionStore.wipeAllSessions()
        agentSessionsByThread.removeAll()
        agentThreadsBySessionID.removeAll()
        agentSessionHistory = []
        if activeWasAgentSession {
            selectedPrivateChatPeer = nil
        }
    }

    @MainActor
    func startAgentSession(peerID: PeerID, role: String, peerNickname: String, seedHistory: [AgentSessionMessage] = []) -> AgentSession {
        let sessionID = UUID().uuidString
        let info = allPeers.first(where: { $0.peerID == peerID })?.agentInfo
        let minQuality = info?.qualityScore ?? 0
        let record = agentSessionStore.createSession(
            role: role,
            minQuality: minQuality,
            modelHash: info?.modelHash,
            seedHistory: seedHistory
        )
        let session = createAgentSession(
            sessionID: sessionID,
            peerID: peerID,
            role: role,
            peerNickname: peerNickname,
            senderAlias: nil,
            recordID: record.id,
            seedHistory: record.history,
            paymentState: record.paymentState,
            paymentUpdatedAt: record.paymentUpdatedAt
        )
        refreshAgentSessionHistory()
        return session
    }

    @MainActor
    func ensureAgentSession(peerID: PeerID, sessionID: String, role: String, peerNickname: String, senderAlias: String? = nil, persist: Bool = true) -> AgentSession {
        let normalized = normalizeSessionID(sessionID)
        if let thread = agentThreadsBySessionID[normalized], let session = agentSessionsByThread[thread] {
            return session
        }
        let recordID: String?
        if persist {
            let info = allPeers.first(where: { $0.peerID == peerID })?.agentInfo
            let minQuality = info?.qualityScore ?? 0
            recordID = agentSessionStore.createSession(
                role: role,
                minQuality: minQuality,
                modelHash: info?.modelHash
            ).id
        } else {
            recordID = nil
        }
        let session = createAgentSession(
            sessionID: normalized,
            peerID: peerID,
            role: role,
            peerNickname: peerNickname,
            senderAlias: senderAlias,
            recordID: recordID
        )
        if persist {
            refreshAgentSessionHistory()
        }
        return session
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
        guard let thread = agentThreadsBySessionID[normalized],
              var session = agentSessionsByThread[thread] else { return }
        session.appendMessage(role: role, content: content, limit: agentSessionHistoryLimit)
        agentSessionsByThread[thread] = session
        if let recordID = session.recordID {
            agentSessionStore.updateSession(recordID: recordID, history: session.history)
            refreshAgentSessionHistory()
        }
    }

    @MainActor
    func setAgentSessionPaymentState(sessionID: String?, threadID: PeerID?, state: AgentSessionPaymentState) {
        var resolvedThread = threadID
        if resolvedThread == nil, let sessionID {
            resolvedThread = agentThreadsBySessionID[normalizeSessionID(sessionID)]
        }
        guard let resolvedThread, var session = agentSessionsByThread[resolvedThread] else { return }
        session.paymentState = state
        session.paymentUpdatedAt = Date()
        agentSessionsByThread[resolvedThread] = session
        if let recordID = session.recordID {
            agentSessionStore.updatePaymentState(recordID: recordID, state: state)
            refreshAgentSessionHistory()
        }
    }

    @MainActor
    func clearAgentSessionPaymentState(sessionID: String?, threadID: PeerID?) {
        var resolvedThread = threadID
        if resolvedThread == nil, let sessionID {
            resolvedThread = agentThreadsBySessionID[normalizeSessionID(sessionID)]
        }
        guard let resolvedThread, var session = agentSessionsByThread[resolvedThread] else { return }
        session.paymentState = nil
        session.paymentUpdatedAt = nil
        agentSessionsByThread[resolvedThread] = session
        if let recordID = session.recordID {
            agentSessionStore.clearPaymentState(recordID: recordID)
            refreshAgentSessionHistory()
        }
    }

    @MainActor
    func sendAgentSessionMessage(prompt: String, threadID: PeerID, draftAttachments: [DraftAttachment]) {
        guard let session = agentSessionsByThread[threadID] else {
            addSystemMessage("agent session unavailable")
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        var outgoingPrompt = trimmedPrompt
        if !session.seedInjected, !session.seedHistory.isEmpty {
            let context = buildResumeContext(from: session.seedHistory)
            if !context.isEmpty {
                outgoingPrompt = context + "\n\nUser: " + trimmedPrompt
            }
            updateAgentSession(threadID: threadID) { current in
                current.seedInjected = true
            }
        }

        let memoryContext = buildAgentMemoryContext(for: trimmedPrompt)
        if !memoryContext.context.isEmpty {
            outgoingPrompt = memoryContext.context + "\n\n" + outgoingPrompt
        }

        let requestID = UUID().uuidString
        let attachmentCount = draftAttachments.isEmpty ? nil : UInt8(min(draftAttachments.count, 255))
        let createdAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let ttlMs = TransportConfig.agentRequestTTLms
        let request = AgentRequestPacket(
            requestID: requestID,
            role: session.role,
            prompt: outgoingPrompt,
            sessionID: session.sessionID,
            attachmentCount: attachmentCount,
            senderAlias: session.senderAlias,
            createdAtMs: createdAtMs,
            ttlMs: ttlMs
        )

        pendingAgentRequests[requestID] = AgentRequestContext(
            role: session.role,
            targetPeerID: session.peerID,
            targetNickname: session.peerNickname,
            sessionID: session.sessionID,
            threadID: session.threadID,
            prompt: outgoingPrompt,
            attachmentCount: attachmentCount,
            senderAlias: session.senderAlias,
            quoteID: nil,
            quoteOptionID: nil,
            draftAttachments: draftAttachments,
            createdAtMs: createdAtMs,
            ttlMs: ttlMs,
            retriesLeft: TransportConfig.agentRequestMaxRetries,
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
        if !draftAttachments.isEmpty {
            recordAgentAttachmentHistory(sessionID: session.sessionID, attachments: draftAttachments)
        }
        appendAgentSessionHistory(sessionID: session.sessionID, role: "user", content: trimmedPrompt)
        meshService.sendAgentRequest(request, to: session.peerID)
        scheduleAgentRequestRetry(requestID: requestID)
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
    private func createAgentSession(sessionID: String,
                                    peerID: PeerID,
                                    role: String,
                                    peerNickname: String,
                                    senderAlias: String? = nil,
                                    recordID: String? = nil,
                                    seedHistory: [AgentSessionMessage] = [],
                                    paymentState: AgentSessionPaymentState? = nil,
                                    paymentUpdatedAt: Date? = nil) -> AgentSession {
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
            recordID: recordID,
            seedHistory: seedHistory,
            seedInjected: seedHistory.isEmpty,
            history: seedHistory,
            paymentState: paymentState,
            paymentUpdatedAt: paymentUpdatedAt
        )
        agentSessionsByThread[threadID] = session
        agentThreadsBySessionID[normalized] = threadID
        if privateChats[threadID] == nil {
            privateChats[threadID] = []
        }
        return session
    }

    private func buildResumeContext(from history: [AgentSessionMessage]) -> String {
        guard !history.isEmpty else { return "" }
        let maxTurns = TransportConfig.agentResumeHistoryTurns
        let maxBytes = TransportConfig.agentResumeHistoryMaxBytes
        let maxTurnBytes = TransportConfig.agentResumeTurnMaxBytes

        var lines: [String] = []
        var total = 0
        for message in history.suffix(maxTurns) {
            let content = trimToBytes(message.content, maxBytes: maxTurnBytes)
            let line = "\(message.role): \(content)"
            let bytes = line.utf8.count
            if total + bytes > maxBytes { break }
            lines.append(line)
            total += bytes
        }
        guard !lines.isEmpty else { return "" }
        return "Previous conversation:\n" + lines.joined(separator: "\n")
    }

    private func trimToBytes(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var result = ""
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            if bytes + scalarBytes > maxBytes { break }
            result.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return result
    }

    @MainActor
    private func recordAgentAttachmentHistory(sessionID: String, attachments: [DraftAttachment]) {
        guard !attachments.isEmpty else { return }
        let markers = attachments.map { attachment -> String in
            switch attachment.kind {
            case "image":
                return "[image] \(attachment.url.lastPathComponent)"
            case "voice":
                return "[voice] \(attachment.url.lastPathComponent)"
            default:
                return "[file] \(attachment.url.lastPathComponent)"
            }
        }
        let content = "attachments: " + markers.joined(separator: ", ")
        appendAgentSessionHistory(sessionID: sessionID, role: "user", content: content)
    }

    @MainActor
    func resumeAgentSession(recordID: String) -> CommandResult {
        let resolvedID = agentSessionStore.resolveSessionID(recordID) ?? recordID
        guard let record = agentSessionStore.session(for: resolvedID) else {
            return .error(message: "unknown session id")
        }
        guard let target = selectAgentCandidate(role: record.role, allowAnyRole: false, minimumQuality: record.minQuality) else {
            return .error(message: "no reachable agents for role '\(record.role)' with required quality")
        }
        let alias = "anon-\(UUID().uuidString.prefix(8))"
        let session = startAgentSession(
            peerID: target.peerID,
            role: record.role,
            peerNickname: alias,
            seedHistory: record.history
        )
        selectedPrivateChatPeer = session.threadID
        addLocalPrivateSystemMessage("session resumed; history will be included on first message", to: session.threadID)
        return .success(message: nil)
    }

    @MainActor
    func startFreshAgentSession(role: String, minQuality: UInt8) -> CommandResult {
        guard let target = selectAgentCandidate(role: role, allowAnyRole: false, minimumQuality: minQuality) else {
            return .error(message: "no reachable agents for role '\(role)' with required quality")
        }
        let alias = "anon-\(UUID().uuidString.prefix(8))"
        let session = startAgentSession(peerID: target.peerID, role: role, peerNickname: alias)
        selectedPrivateChatPeer = session.threadID
        addLocalPrivateSystemMessage("new session started", to: session.threadID)
        return .success(message: nil)
    }

    @MainActor
    func handleAgentSessionCommand(_ args: String) -> CommandResult {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "list" {
            let sessions = agentSessionStore.listSessions()
            guard !sessions.isEmpty else {
                return .success(message: "no sessions yet")
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let lines = sessions.prefix(10).map { record in
                let dateString = formatter.string(from: record.lastUsedAt)
                let title = record.title.isEmpty ? "New session" : record.title
                let paymentSuffix: String = {
                    guard let state = record.paymentState else { return "" }
                    return " • \(state.rawValue)"
                }()
                return "\(record.id.prefix(8)) • \(record.role) • \(title) • \(dateString)\(paymentSuffix)"
            }
            return .success(message: "sessions:\n" + lines.joined(separator: "\n"))
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let action = parts.first?.lowercased() else {
            return .error(message: "usage: /agentsession <list|resume|new|end> [id]")
        }
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch action {
        case "resume":
            guard !arg.isEmpty else { return .error(message: "usage: /agentsession resume <id>") }
            return resumeAgentSession(recordID: arg)
        case "new":
            if let threadID = selectedPrivateChatPeer,
               let session = agentSessionsByThread[threadID] {
                let minQuality = agentSessionStore.session(for: session.recordID ?? "")?.minQuality ?? 0
                return startFreshAgentSession(role: session.role, minQuality: minQuality)
            }
            return .error(message: "no active agent session; use /agent to start")
        case "end":
            if let threadID = selectedPrivateChatPeer,
               agentSessionsByThread[threadID] != nil {
                endPrivateChat()
                return .success(message: "agent session ended")
            }
            return .error(message: "no active agent session")
        default:
            return .error(message: "usage: /agentsession <list|resume|new|end> [id]")
        }
    }

 
}
