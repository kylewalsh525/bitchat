//
// AgentSessionStore.swift
// bitchat
//
// Local-only storage for agent session history (privacy-preserving).
//

import Foundation
import BitLogger

struct AgentSessionRecord: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let minQuality: UInt8
    let modelHash: String?
    let createdAt: Date
    var lastUsedAt: Date
    var title: String
    var history: [AgentSessionMessage]
}

@MainActor
final class AgentSessionStore {
    private var sessionsByID: [String: AgentSessionRecord] = [:]
    private let storeURL: URL

    init() {
        self.storeURL = AgentSessionStore.defaultStoreURL()
        load()
    }

    func listSessions() -> [AgentSessionRecord] {
        purgeIfNeeded()
        return sessionsByID.values
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func session(for id: String) -> AgentSessionRecord? {
        sessionsByID[id]
    }

    func resolveSessionID(_ token: String) -> String? {
        if sessionsByID[token] != nil {
            return token
        }
        let matches = sessionsByID.keys.filter { $0.hasPrefix(token) }
        return matches.count == 1 ? matches.first : nil
    }

    func createSession(role: String,
                       minQuality: UInt8,
                       modelHash: String?,
                       seedHistory: [AgentSessionMessage] = []) -> AgentSessionRecord {
        let recordID = UUID().uuidString
        let now = Date()
        let title = makeTitle(from: seedHistory.first?.content)
        let record = AgentSessionRecord(
            id: recordID,
            role: role,
            minQuality: minQuality,
            modelHash: modelHash,
            createdAt: now,
            lastUsedAt: now,
            title: title,
            history: trimHistory(seedHistory)
        )
        sessionsByID[recordID] = record
        purgeIfNeeded()
        save()
        return record
    }

    func updateSession(recordID: String, history: [AgentSessionMessage]) {
        guard var record = sessionsByID[recordID] else { return }
        record.history = trimHistory(history)
        record.lastUsedAt = Date()
        if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.title = makeTitle(from: record.history.first?.content)
        }
        sessionsByID[recordID] = record
        purgeIfNeeded()
        save()
    }

    func touch(recordID: String) {
        guard var record = sessionsByID[recordID] else { return }
        record.lastUsedAt = Date()
        sessionsByID[recordID] = record
        save()
    }

    func wipeAllSessions() {
        sessionsByID.removeAll()
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.removeItem(at: storeURL)
            }
        } catch {
            SecureLogger.error("Failed to wipe session store: \(error)", category: .session)
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([AgentSessionRecord].self, from: data)
            sessionsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            purgeIfNeeded()
        } catch {
            SecureLogger.error("Failed to load session store: \(error)", category: .session)
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Array(sessionsByID.values))
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            SecureLogger.error("Failed to save session store: \(error)", category: .session)
        }
    }

    private func purgeIfNeeded() {
        let ttl = TransportConfig.agentSessionStoreTTLSeconds
        let cutoff = Date().addingTimeInterval(-ttl)
        sessionsByID = sessionsByID.filter { $0.value.lastUsedAt >= cutoff }

        let maxCount = TransportConfig.agentSessionStoreMaxCount
        if sessionsByID.count > maxCount {
            let sorted = sessionsByID.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
            let keep = sorted.prefix(maxCount)
            sessionsByID = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
    }

    private func trimHistory(_ history: [AgentSessionMessage]) -> [AgentSessionMessage] {
        guard !history.isEmpty else { return [] }
        let maxTurns = TransportConfig.agentSessionStoreMaxHistoryTurns
        let maxBytes = TransportConfig.agentSessionStoreMaxHistoryBytes
        let maxTurnBytes = TransportConfig.agentResumeTurnMaxBytes

        var trimmed: [AgentSessionMessage] = []
        var total = 0
        for message in history.suffix(maxTurns) {
            let content = trimToBytes(message.content, maxBytes: maxTurnBytes)
            let entry = AgentSessionMessage(role: message.role, content: content)
            let bytes = entry.role.utf8.count + content.utf8.count
            if total + bytes > maxBytes {
                break
            }
            trimmed.append(entry)
            total += bytes
        }
        return trimmed
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

    private func makeTitle(from content: String?) -> String {
        let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "" }
        let maxLen = 64
        if raw.count <= maxLen { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: maxLen)
        return String(raw[..<idx]) + "…"
    }

    private static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("bitchat/agent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("sessions.json")
    }
}
