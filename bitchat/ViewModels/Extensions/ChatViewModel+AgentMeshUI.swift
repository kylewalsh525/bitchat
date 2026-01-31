//
// ChatViewModel+AgentMeshUI.swift
// bitchat
//
// Agent mesh UI helpers (DM-only rendering).
//

import Foundation
import BitLogger

extension ChatViewModel {
    @MainActor
    func addAgentRequestDM(requestID: String, role: String, prompt: String, peerID: PeerID, peerNickname: String, outgoing: Bool) {
        let prefix = "[agent \(role)]"
        let content = "\(prefix) \(prompt)"
        let messageID = agentMessageID(kind: outgoing ? "req-out" : "req-in", requestID: requestID)
        let senderName: String = {
            if outgoing, peerID.isAgentSession, let alias = agentSessionOutgoingDisplayName(for: peerID) {
                return alias
            }
            return outgoing ? nickname : peerNickname
        }()
        appendAgentPrivateMessage(
            peerID: peerID,
            sender: senderName,
            senderPeerID: outgoing ? meshService.myPeerID : peerID,
            content: content,
            messageID: messageID,
            deliveryStatus: outgoing ? .sent : nil,
            markUnread: !outgoing
        )
    }

    @MainActor
    func addAgentResponseDM(requestID: String, role: String, content: String, peerID: PeerID, peerNickname: String, outgoing: Bool, isError: Bool) {
        let prefix = isError ? "[agent error \(role)]" : "[agent \(role)]"
        let body = "\(prefix) \(content)"
        let messageID = agentMessageID(kind: outgoing ? "resp-out" : "resp-in", requestID: requestID)
        let senderName: String = {
            if outgoing, peerID.isAgentSession, let alias = agentSessionOutgoingDisplayName(for: peerID) {
                return alias
            }
            return outgoing ? nickname : peerNickname
        }()
        appendAgentPrivateMessage(
            peerID: peerID,
            sender: senderName,
            senderPeerID: outgoing ? meshService.myPeerID : peerID,
            content: body,
            messageID: messageID,
            deliveryStatus: outgoing ? .sent : nil,
            markUnread: !outgoing
        )
    }

    @MainActor
    func upsertAgentResponseDM(requestID: String, role: String, content: String, peerID: PeerID, peerNickname: String, outgoing: Bool, isError: Bool, markUnread: Bool) {
        let prefix = isError ? "[agent error \(role)]" : "[agent \(role)]"
        let body = "\(prefix) \(content)"
        let messageID = agentMessageID(kind: outgoing ? "resp-out" : "resp-in", requestID: requestID)
        let senderName: String = {
            if outgoing, peerID.isAgentSession, let alias = agentSessionOutgoingDisplayName(for: peerID) {
                return alias
            }
            return outgoing ? nickname : peerNickname
        }()

        if var messages = privateChats[peerID],
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            let existing = messages[index]
            let updated = BitchatMessage(
                id: existing.id,
                sender: existing.sender,
                content: body,
                timestamp: existing.timestamp,
                isRelay: existing.isRelay,
                originalSender: existing.originalSender,
                isPrivate: true,
                recipientNickname: existing.recipientNickname,
                senderPeerID: existing.senderPeerID,
                mentions: nil,
                deliveryStatus: existing.deliveryStatus
            )
            messages[index] = updated
            privateChats[peerID] = messages
            privateChatManager.sanitizeChat(for: peerID)
            objectWillChange.send()
            return
        }

        appendAgentPrivateMessage(
            peerID: peerID,
            sender: senderName,
            senderPeerID: outgoing ? meshService.myPeerID : peerID,
            content: body,
            messageID: messageID,
            deliveryStatus: outgoing ? .sent : nil,
            markUnread: markUnread
        )
    }

    // MARK: - Helpers
    private func agentMessageID(kind: String, requestID: String) -> String {
        "agent-\(kind)-\(requestID)"
    }

    @MainActor
    private func appendAgentPrivateMessage(
        peerID: PeerID,
        sender: String,
        senderPeerID: PeerID?,
        content: String,
        messageID: String,
        deliveryStatus: DeliveryStatus?,
        markUnread: Bool
    ) {
        if isDuplicateMessage(messageID, targetPeerID: peerID) {
            return
        }
        let message = BitchatMessage(
            id: messageID,
            sender: sender,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: meshService.peerNickname(peerID: peerID),
            senderPeerID: senderPeerID,
            mentions: nil,
            deliveryStatus: deliveryStatus
        )

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: peerID)
        privateChatManager.sanitizeChat(for: peerID)

        if markUnread && selectedPrivateChatPeer != peerID {
            unreadPrivateMessages.insert(peerID)
            NotificationService.shared.sendPrivateMessageNotification(
                from: sender,
                message: content,
                peerID: peerID
            )
        }
        objectWillChange.send()
    }
}
