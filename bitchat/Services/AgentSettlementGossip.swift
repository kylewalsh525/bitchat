import Foundation
import BitLogger

@MainActor
final class AgentSettlementGossip {
    enum Source: String {
        case mesh
        case global
        case local
    }

    enum IngestStatus: Equatable {
        case notSettlement
        case invalid
        case rateLimited
        case duplicate
        case accepted
    }

    struct IngestResult: Equatable {
        let status: IngestStatus
        let isSettlement: Bool
        let shouldForwardToGlobal: Bool
        let shouldForwardToMesh: Bool
        let conflictNullifier: String?
    }

    struct SpendAnnounce: Codable, Equatable {
        let mintHint: String?
        let unit: String?
        let paymentID: String
        let nullifiers: [String]
        let ts: UInt64
        let sig: String?
    }

    struct SpendConflict: Codable, Equatable {
        let nullifier: String
        let seenAt: UInt64
        let evidence: String?
    }

    static let meshRoom = "#settle"
    static let globalRoom = "#settle-global"
    static let payloadPrefix = "settle1:"

    private enum MessageType: String, Codable {
        case spendAnnounce = "spend_announce"
        case spendConflict = "spend_conflict"
    }

    private struct Envelope: Codable {
        let version: UInt8
        let type: MessageType
        let eventID: String
        let room: String?
        let mintHint: String?
        let unit: String?
        let paymentID: String?
        let nullifiers: [String]?
        let ts: UInt64?
        let sig: String?
        let nullifier: String?
        let seenAt: UInt64?
        let evidence: String?
    }

    private struct NullifierObservation {
        let paymentID: String
        let mintHint: String?
        let unit: String?
        let source: Source
        let senderID: String?
        let firstSeenAtMs: UInt64
        var lastSeenAtMs: UInt64
    }

    private struct SenderWindow {
        var startMs: UInt64
        var count: Int
    }

    private var observations: [String: NullifierObservation] = [:]
    private var observationOrder: [String] = []
    private var observationOrderHead: Int = 0
    private var conflictedNullifiers: [String: UInt64] = [:]
    private var senderWindows: [String: SenderWindow] = [:]
    private var lastPruneAtMs: UInt64 = 0
    private let seenEvents = LRUDeduplicationCache<Bool>(capacity: TransportConfig.settlementGossipSeenEventCapacity)

    private let maxMessageBytes = TransportConfig.settlementGossipMaxMessageBytes
    private let maxNullifiersPerMessage = TransportConfig.settlementGossipMaxNullifiersPerMessage
    private let observationCapacity = TransportConfig.settlementGossipObservationCapacity
    private let observationTTLms = UInt64(TransportConfig.settlementGossipObservationTTLSeconds * 1000)
    private let conflictCooldownMs = UInt64(TransportConfig.settlementGossipConflictCooldownSeconds * 1000)
    private let senderWindowMs = UInt64(TransportConfig.settlementGossipSenderWindowSeconds * 1000)
    private let senderWindowMaxMessages = TransportConfig.settlementGossipSenderWindowMaxMessages
    private let senderTrackerCapacity = TransportConfig.settlementGossipSenderTrackerCapacity
    private let pruneIntervalMs: UInt64 = 5_000

    func reset() {
        observations.removeAll(keepingCapacity: false)
        observationOrder.removeAll(keepingCapacity: false)
        observationOrderHead = 0
        conflictedNullifiers.removeAll(keepingCapacity: false)
        senderWindows.removeAll(keepingCapacity: false)
        lastPruneAtMs = 0
        seenEvents.clear()
    }

    func firstConflictingNullifier(
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String]
    ) -> String? {
        let now = nowMs()
        pruneIfNeeded(nowMs: now)

        let normalizedNullifiers = canonicalNullifiers(nullifiers)
        guard !normalizedNullifiers.isEmpty else { return nil }

        let hint = mintHint(for: mintURL, unit: unit)
        for nullifier in normalizedNullifiers {
            if conflictedNullifiers[nullifier] != nil {
                return nullifier
            }
            guard let observed = observations[nullifier] else { continue }
            guard observed.paymentID != paymentID else { continue }
            if likelySameMint(observedHint: observed.mintHint, incomingHint: hint, observedUnit: observed.unit, incomingUnit: unit) {
                return nullifier
            }
        }
        return nil
    }

    func registerAcceptedPayment(
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String]
    ) -> String? {
        let now = nowMs()
        pruneIfNeeded(nowMs: now)

        let normalizedNullifiers = canonicalNullifiers(nullifiers)
        guard !normalizedNullifiers.isEmpty else { return nil }

        let hint = mintHint(for: mintURL, unit: unit)
        for nullifier in normalizedNullifiers {
            if let existing = observations[nullifier],
               existing.paymentID != paymentID,
               likelySameMint(observedHint: existing.mintHint, incomingHint: hint, observedUnit: existing.unit, incomingUnit: unit) {
                conflictedNullifiers[nullifier] = now
            }
            recordObservation(
                nullifier: nullifier,
                paymentID: paymentID,
                mintHint: hint,
                unit: normalizedUnit(unit),
                source: .local,
                senderID: nil,
                nowMs: now
            )
        }

        let announce = SpendAnnounce(
            mintHint: hint,
            unit: normalizedUnit(unit),
            paymentID: paymentID,
            nullifiers: normalizedNullifiers,
            ts: now,
            sig: nil
        )
        return encodeAnnounce(announce, room: Self.meshRoom)
    }

    func makeSpendConflictContent(nullifier: String, evidence: String?) -> String? {
        let normalizedNullifier = nullifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedNullifier.isEmpty else { return nil }

        let now = nowMs()
        pruneIfNeeded(nowMs: now)

        if let lastSeen = conflictedNullifiers[normalizedNullifier], now < (lastSeen + conflictCooldownMs) {
            return nil
        }
        conflictedNullifiers[normalizedNullifier] = now

        let conflict = SpendConflict(
            nullifier: normalizedNullifier,
            seenAt: now,
            evidence: evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return encodeConflict(conflict, room: Self.meshRoom)
    }

    func ingest(content: String, source: Source, senderID: String?) -> IngestResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.payloadPrefix) else {
            return IngestResult(
                status: .notSettlement,
                isSettlement: false,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                conflictNullifier: nil
            )
        }

        let now = nowMs()
        pruneIfNeeded(nowMs: now)

        guard trimmed.utf8.count <= maxMessageBytes else {
            return IngestResult(
                status: .invalid,
                isSettlement: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                conflictNullifier: nil
            )
        }

        let senderKey = senderRateKey(source: source, senderID: senderID)
        guard allowInboundFromSender(senderKey, nowMs: now) else {
            return IngestResult(
                status: .rateLimited,
                isSettlement: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                conflictNullifier: nil
            )
        }

        guard let envelope = decodeEnvelope(from: trimmed) else {
            return IngestResult(
                status: .invalid,
                isSettlement: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                conflictNullifier: nil
            )
        }

        let eventKey = dedupeKey(for: envelope)
        if seenEvents.contains(eventKey) {
            return IngestResult(
                status: .duplicate,
                isSettlement: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                conflictNullifier: nil
            )
        }
        seenEvents.record(eventKey, value: true)

        switch envelope.type {
        case .spendAnnounce:
            guard let paymentID = envelope.paymentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !paymentID.isEmpty,
                  let announcedNullifiers = envelope.nullifiers else {
                return IngestResult(
                    status: .invalid,
                    isSettlement: true,
                    shouldForwardToGlobal: false,
                    shouldForwardToMesh: false,
                    conflictNullifier: nil
                )
            }

            let normalizedNullifiers = canonicalNullifiers(announcedNullifiers)
            guard !normalizedNullifiers.isEmpty else {
                return IngestResult(
                    status: .invalid,
                    isSettlement: true,
                    shouldForwardToGlobal: false,
                    shouldForwardToMesh: false,
                    conflictNullifier: nil
                )
            }

            let hint = envelope.mintHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unit = envelope.unit.map { normalizedUnit($0) }
            var firstConflict: String?
            for nullifier in normalizedNullifiers {
                if let existing = observations[nullifier],
                   existing.paymentID != paymentID,
                   likelySameMint(observedHint: existing.mintHint, incomingHint: hint, observedUnit: existing.unit, incomingUnit: unit) {
                    conflictedNullifiers[nullifier] = now
                    if firstConflict == nil {
                        firstConflict = nullifier
                    }
                }

                recordObservation(
                    nullifier: nullifier,
                    paymentID: paymentID,
                    mintHint: hint,
                    unit: unit,
                    source: source,
                    senderID: senderID,
                    nowMs: now
                )
            }

            return IngestResult(
                status: .accepted,
                isSettlement: true,
                shouldForwardToGlobal: source == .mesh,
                shouldForwardToMesh: source == .global,
                conflictNullifier: firstConflict
            )

        case .spendConflict:
            guard let nullifier = envelope.nullifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !nullifier.isEmpty else {
                return IngestResult(
                    status: .invalid,
                    isSettlement: true,
                    shouldForwardToGlobal: false,
                    shouldForwardToMesh: false,
                    conflictNullifier: nil
                )
            }
            conflictedNullifiers[nullifier] = envelope.seenAt ?? now
            return IngestResult(
                status: .accepted,
                isSettlement: true,
                shouldForwardToGlobal: source == .mesh,
                shouldForwardToMesh: source == .global,
                conflictNullifier: nullifier
            )
        }
    }

    private func encodeAnnounce(_ announce: SpendAnnounce, room: String?) -> String? {
        let payload = "announce|\(announce.paymentID)|\(announce.mintHint ?? "")|\(announce.unit ?? "")|\(announce.nullifiers.joined(separator: ","))|\(announce.ts)"
        let eventID = stableHash(payload)
        let envelope = Envelope(
            version: 1,
            type: .spendAnnounce,
            eventID: eventID,
            room: room,
            mintHint: announce.mintHint,
            unit: announce.unit,
            paymentID: announce.paymentID,
            nullifiers: announce.nullifiers,
            ts: announce.ts,
            sig: announce.sig,
            nullifier: nil,
            seenAt: nil,
            evidence: nil
        )
        return encodeEnvelope(envelope)
    }

    private func encodeConflict(_ conflict: SpendConflict, room: String?) -> String? {
        let payload = "conflict|\(conflict.nullifier)|\(conflict.seenAt)|\(conflict.evidence ?? "")"
        let eventID = stableHash(payload)
        let envelope = Envelope(
            version: 1,
            type: .spendConflict,
            eventID: eventID,
            room: room,
            mintHint: nil,
            unit: nil,
            paymentID: nil,
            nullifiers: nil,
            ts: nil,
            sig: nil,
            nullifier: conflict.nullifier,
            seenAt: conflict.seenAt,
            evidence: conflict.evidence
        )
        return encodeEnvelope(envelope)
    }

    private func encodeEnvelope(_ envelope: Envelope) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= maxMessageBytes else {
                return nil
            }
            seenEvents.record(dedupeKey(for: envelope), value: true)
            return Self.payloadPrefix + (String(data: data, encoding: .utf8) ?? "")
        } catch {
            SecureLogger.error("Failed to encode settlement envelope: \(error)", category: .session)
            return nil
        }
    }

    private func decodeEnvelope(from content: String) -> Envelope? {
        let encoded = String(content.dropFirst(Self.payloadPrefix.count))
        guard let data = encoded.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            SecureLogger.warning("Failed to decode settlement envelope: \(error)", category: .session)
            return nil
        }
    }

    private func senderRateKey(source: Source, senderID: String?) -> String {
        if let senderID {
            let normalized = senderID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                return "\(source.rawValue):\(normalized)"
            }
        }
        return "\(source.rawValue):unknown"
    }

    private func allowInboundFromSender(_ senderKey: String, nowMs: UInt64) -> Bool {
        if senderWindows.count >= senderTrackerCapacity {
            senderWindows = senderWindows.filter { nowMs - $0.value.startMs < senderWindowMs }
        }

        guard var window = senderWindows[senderKey] else {
            senderWindows[senderKey] = SenderWindow(startMs: nowMs, count: 1)
            return true
        }

        if nowMs - window.startMs >= senderWindowMs {
            window.startMs = nowMs
            window.count = 1
            senderWindows[senderKey] = window
            return true
        }

        if window.count >= senderWindowMaxMessages {
            senderWindows[senderKey] = window
            return false
        }

        window.count += 1
        senderWindows[senderKey] = window
        return true
    }

    private func dedupeKey(for envelope: Envelope) -> String {
        let eventID = envelope.eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !eventID.isEmpty {
            return eventID
        }

        switch envelope.type {
        case .spendAnnounce:
            let paymentID = envelope.paymentID ?? ""
            let nullifiers = canonicalNullifiers(envelope.nullifiers ?? []).joined(separator: ",")
            return stableHash("announce|\(paymentID)|\(nullifiers)|\(envelope.ts ?? 0)")
        case .spendConflict:
            return stableHash("conflict|\(envelope.nullifier ?? "")|\(envelope.seenAt ?? 0)")
        }
    }

    private func canonicalNullifiers(_ nullifiers: [String]) -> [String] {
        let normalized = nullifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [] }
        let capped = Array(normalized.prefix(maxNullifiersPerMessage))
        return Array(Set(capped)).sorted()
    }

    private func normalizedUnit(_ unit: String) -> String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func mintHint(for mintURL: String, unit: String) -> String {
        stableHash("\(mintURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(normalizedUnit(unit))")
    }

    private func likelySameMint(
        observedHint: String?,
        incomingHint: String?,
        observedUnit: String?,
        incomingUnit: String?
    ) -> Bool {
        if let observedHint, let incomingHint, observedHint != incomingHint {
            return false
        }
        if let observedUnit, let incomingUnit, observedUnit != incomingUnit {
            return false
        }
        return true
    }

    private func recordObservation(
        nullifier: String,
        paymentID: String,
        mintHint: String?,
        unit: String?,
        source: Source,
        senderID: String?,
        nowMs: UInt64
    ) {
        if var existing = observations[nullifier] {
            existing.lastSeenAtMs = nowMs
            observations[nullifier] = existing
            return
        }

        observations[nullifier] = NullifierObservation(
            paymentID: paymentID,
            mintHint: mintHint,
            unit: unit,
            source: source,
            senderID: senderID,
            firstSeenAtMs: nowMs,
            lastSeenAtMs: nowMs
        )
        observationOrder.append(nullifier)
        trimObservationCapacity()
    }

    private func trimObservationCapacity() {
        let active = observationOrder.count - observationOrderHead
        guard active > observationCapacity else { return }
        let overflow = active - observationCapacity
        for _ in 0..<overflow {
            guard let oldest = popOldestObservationKey() else { break }
            observations.removeValue(forKey: oldest)
        }
        compactObservationOrderIfNeeded()
    }

    private func popOldestObservationKey() -> String? {
        while observationOrderHead < observationOrder.count {
            let key = observationOrder[observationOrderHead]
            observationOrderHead += 1

            if observationOrderHead >= 32 && observationOrderHead * 2 >= observationOrder.count {
                observationOrder.removeFirst(observationOrderHead)
                observationOrderHead = 0
            }

            if observations[key] != nil {
                return key
            }
        }
        return nil
    }

    private func prune(nowMs: UInt64) {
        let cutoff = nowMs > observationTTLms ? (nowMs - observationTTLms) : 0
        if !observations.isEmpty {
            observations = observations.filter { _, observation in
                observation.lastSeenAtMs >= cutoff
            }
        }

        if !conflictedNullifiers.isEmpty {
            conflictedNullifiers = conflictedNullifiers.filter { _, seenAt in
                seenAt >= cutoff
            }
        }

        if !senderWindows.isEmpty {
            senderWindows = senderWindows.filter { _, window in
                nowMs - window.startMs < senderWindowMs
            }
        }

        compactObservationOrderIfNeeded(force: observationOrder.count > (observationCapacity * 4))
    }

    private func pruneIfNeeded(nowMs: UInt64) {
        if lastPruneAtMs == 0 || nowMs >= (lastPruneAtMs + pruneIntervalMs) {
            prune(nowMs: nowMs)
            lastPruneAtMs = nowMs
        }
    }

    private func compactObservationOrderIfNeeded(force: Bool = false) {
        // Keep ordering memory bounded after TTL evictions and long-running churn.
        let shouldCompact = force ||
            observationOrderHead >= 256 ||
            observationOrder.count >= (observationCapacity * 2)
        guard shouldCompact else { return }

        guard observationOrderHead < observationOrder.count else {
            observationOrder.removeAll(keepingCapacity: true)
            observationOrderHead = 0
            return
        }

        var compacted: [String] = []
        compacted.reserveCapacity(min(observations.count, observationCapacity))
        for key in observationOrder[observationOrderHead...] where observations[key] != nil {
            compacted.append(key)
        }
        observationOrder = compacted
        observationOrderHead = 0
    }

    private func stableHash(_ value: String) -> String {
        value.data(using: .utf8)?.sha256Hash().hexEncodedString() ?? UUID().uuidString.lowercased()
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
