//
// AgentRetryQueue.swift
// bitchat
//
// In-memory retry queue for agent requests when peers are temporarily unreachable.
//

import Foundation
import BitFoundation

final class AgentRetryQueue {
    private struct Entry {
        let requestID: String
        let peerID: PeerID
        let expiresAt: Date
    }

    private var queuedByPeer: [PeerID: [String: Entry]] = [:]

    func enqueue(requestID: String, peerID: PeerID, expiresAt: Date) {
        var entries = queuedByPeer[peerID] ?? [:]
        entries[requestID] = Entry(requestID: requestID, peerID: peerID, expiresAt: expiresAt)
        queuedByPeer[peerID] = entries
    }

    func dequeueReady(for peerID: PeerID, now: Date = Date()) -> [String] {
        guard var entries = queuedByPeer[peerID] else { return [] }
        var ready: [String] = []
        for (requestID, entry) in entries {
            if entry.expiresAt <= now {
                entries.removeValue(forKey: requestID)
                continue
            }
            ready.append(requestID)
            entries.removeValue(forKey: requestID)
        }
        queuedByPeer[peerID] = entries.isEmpty ? nil : entries
        return ready
    }

    func remove(requestID: String, peerID: PeerID) {
        guard var entries = queuedByPeer[peerID] else { return }
        entries.removeValue(forKey: requestID)
        queuedByPeer[peerID] = entries.isEmpty ? nil : entries
    }

    func pruneExpired(now: Date = Date()) {
        for (peerID, entries) in queuedByPeer {
            let filtered = entries.filter { $0.value.expiresAt > now }
            queuedByPeer[peerID] = filtered.isEmpty ? nil : filtered
        }
    }
}
