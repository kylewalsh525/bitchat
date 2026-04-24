import Foundation
import BitFoundation
import BitLogger

@MainActor
final class AgentPaymentNotaryService {
    enum Source: String {
        case mesh
        case global
    }

    enum IngestStatus: Equatable {
        case notNotary
        case invalid
        case duplicate
        case accepted
    }

    struct IngestResult: Equatable {
        let status: IngestStatus
        let isNotary: Bool
        let shouldForwardToGlobal: Bool
        let shouldForwardToMesh: Bool
        let request: NotaryRequest?
        let receipt: NotaryReceipt?
        let encodedReceipt: String?
    }

    struct NotaryRequest: Codable, Equatable {
        let requestID: String
        let paymentID: String
        let mintHint: String?
        let unit: String
        let nullifierDigest: String
        let nullifiers: [String]
        let requesterPeerID: String?
        let ts: UInt64
    }

    struct NotaryReceipt: Codable, Equatable {
        let version: UInt8
        let requestID: String
        let paymentID: String
        let mintHint: String?
        let unit: String
        let nullifierDigest: String
        let nullifierCount: UInt16
        let notaryPeerID: String
        let notarySigningKey: String
        let issuedAtMs: UInt64
        let signature: String
    }

    static let payloadPrefix = "notary1:"
    static let receiptPrefix = "anr1:"

    private enum MessageType: String, Codable {
        case request = "notary_request"
        case attest = "notary_attest"
    }

    private struct Envelope: Codable {
        let version: UInt8
        let type: MessageType
        let eventID: String
        let room: String?
        let requestID: String?
        let paymentID: String?
        let mintHint: String?
        let unit: String?
        let nullifierDigest: String?
        let nullifiers: [String]?
        let requesterPeerID: String?
        let ts: UInt64?
        let receipt: String?
    }

    private struct ReceiptCacheEntry {
        let receipt: NotaryReceipt
        let encodedReceipt: String
        let seenAtMs: UInt64
    }

    private var receiptsByRequirementKey: [String: [String: ReceiptCacheEntry]] = [:]
    private var receiptOrder: [(requirementKey: String, receiptKey: String)] = []

    private let seenEvents = LRUDeduplicationCache<Bool>(capacity: TransportConfig.notaryGossipSeenEventCapacity)
    private let maxMessageBytes = TransportConfig.notaryGossipMaxMessageBytes
    private let receiptCacheCapacity = TransportConfig.notaryReceiptCacheCapacity
    private let receiptTTLms = UInt64(TransportConfig.notaryReceiptTTLSeconds * 1000)

    func reset() {
        receiptsByRequirementKey.removeAll(keepingCapacity: false)
        receiptOrder.removeAll(keepingCapacity: false)
        seenEvents.clear()
    }

    func requirement(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String]
    ) -> NotaryRequest {
        let canonical = canonicalNullifiers(nullifiers)
        let normalizedUnit = normalizedUnit(unit)
        return NotaryRequest(
            requestID: requestID,
            paymentID: paymentID,
            mintHint: mintHint(for: mintURL, unit: normalizedUnit),
            unit: normalizedUnit,
            nullifierDigest: digestForNullifiers(mintHint: mintHint(for: mintURL, unit: normalizedUnit), unit: normalizedUnit, nullifiers: canonical),
            nullifiers: canonical,
            requesterPeerID: nil,
            ts: nowMs()
        )
    }

    func makeNotaryRequestContent(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String],
        requesterPeerID: String?
    ) -> String? {
        let canonical = canonicalNullifiers(nullifiers)
        guard !canonical.isEmpty else { return nil }

        let normalizedUnit = normalizedUnit(unit)
        let hint = mintHint(for: mintURL, unit: normalizedUnit)
        let request = NotaryRequest(
            requestID: requestID,
            paymentID: paymentID,
            mintHint: hint,
            unit: normalizedUnit,
            nullifierDigest: digestForNullifiers(mintHint: hint, unit: normalizedUnit, nullifiers: canonical),
            nullifiers: canonical,
            requesterPeerID: requesterPeerID,
            ts: nowMs()
        )
        return encodeRequestEnvelope(request: request, room: AgentSettlementGossip.meshRoom)
    }

    func makeNotaryAttestationContent(
        request: NotaryRequest,
        room: String,
        notaryPeerID: String,
        signingPublicKeyHex: String,
        sign: (Data) -> Data?
    ) -> String? {
        let issuedAtMs = nowMs()
        let payload = receiptSigningPayload(
            requestID: request.requestID,
            paymentID: request.paymentID,
            mintHint: request.mintHint,
            unit: request.unit,
            nullifierDigest: request.nullifierDigest,
            nullifierCount: request.nullifiers.count,
            notaryPeerID: notaryPeerID,
            notarySigningKey: signingPublicKeyHex,
            issuedAtMs: issuedAtMs
        )

        guard let signature = sign(payload), !signature.isEmpty else { return nil }

        let receipt = NotaryReceipt(
            version: 1,
            requestID: request.requestID,
            paymentID: request.paymentID,
            mintHint: request.mintHint,
            unit: request.unit,
            nullifierDigest: request.nullifierDigest,
            nullifierCount: UInt16(min(request.nullifiers.count, Int(UInt16.max))),
            notaryPeerID: notaryPeerID,
            notarySigningKey: signingPublicKeyHex,
            issuedAtMs: issuedAtMs,
            signature: signature.hexEncodedString()
        )

        guard let encodedReceipt = encodeReceipt(receipt) else { return nil }
        insertReceipt(encodedReceipt: encodedReceipt, receipt: receipt)

        let envelope = Envelope(
            version: 1,
            type: .attest,
            eventID: stableHash("attest|\(request.requestID)|\(request.paymentID)|\(request.nullifierDigest)|\(receipt.notaryPeerID)|\(issuedAtMs)"),
            room: room,
            requestID: request.requestID,
            paymentID: request.paymentID,
            mintHint: request.mintHint,
            unit: request.unit,
            nullifierDigest: request.nullifierDigest,
            nullifiers: nil,
            requesterPeerID: request.requesterPeerID,
            ts: issuedAtMs,
            receipt: encodedReceipt
        )
        return encodeEnvelope(envelope)
    }

    func ingest(content: String, source: Source, senderID: String?) -> IngestResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.payloadPrefix) else {
            return IngestResult(
                status: .notNotary,
                isNotary: false,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                request: nil,
                receipt: nil,
                encodedReceipt: nil
            )
        }

        guard trimmed.utf8.count <= maxMessageBytes,
              let envelope = decodeEnvelope(trimmed) else {
            return IngestResult(
                status: .invalid,
                isNotary: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                request: nil,
                receipt: nil,
                encodedReceipt: nil
            )
        }

        let eventKey = dedupeKey(for: envelope)
        if seenEvents.contains(eventKey) {
            return IngestResult(
                status: .duplicate,
                isNotary: true,
                shouldForwardToGlobal: false,
                shouldForwardToMesh: false,
                request: nil,
                receipt: nil,
                encodedReceipt: nil
            )
        }
        seenEvents.record(eventKey, value: true)

        switch envelope.type {
        case .request:
            guard let request = request(from: envelope) else {
                return IngestResult(
                    status: .invalid,
                    isNotary: true,
                    shouldForwardToGlobal: false,
                    shouldForwardToMesh: false,
                    request: nil,
                    receipt: nil,
                    encodedReceipt: nil
                )
            }
            return IngestResult(
                status: .accepted,
                isNotary: true,
                shouldForwardToGlobal: source == .mesh,
                shouldForwardToMesh: source == .global,
                request: request,
                receipt: nil,
                encodedReceipt: nil
            )

        case .attest:
            guard let encodedReceipt = envelope.receipt,
                  let receipt = decodeReceipt(encodedReceipt),
                  receipt.requestID == envelope.requestID,
                  receipt.paymentID == envelope.paymentID,
                  receipt.nullifierDigest == envelope.nullifierDigest else {
                return IngestResult(
                    status: .invalid,
                    isNotary: true,
                    shouldForwardToGlobal: false,
                    shouldForwardToMesh: false,
                    request: nil,
                    receipt: nil,
                    encodedReceipt: nil
                )
            }
            insertReceipt(encodedReceipt: encodedReceipt, receipt: receipt)
            return IngestResult(
                status: .accepted,
                isNotary: true,
                shouldForwardToGlobal: source == .mesh,
                shouldForwardToMesh: source == .global,
                request: nil,
                receipt: receipt,
                encodedReceipt: encodedReceipt
            )
        }
    }

    func waitForReceipts(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String],
        minCount: Int,
        timeoutMs: UInt64,
        validate: (String, NotaryReceipt) -> Bool
    ) async -> [String] {
        let requiredCount = max(0, min(minCount, TransportConfig.notaryRequiredSignatureMax))
        guard requiredCount > 0 else { return [] }

        let deadline = nowMs() + timeoutMs
        while true {
            let current = selectReceipts(
                requestID: requestID,
                paymentID: paymentID,
                mintURL: mintURL,
                unit: unit,
                nullifiers: nullifiers,
                minCount: requiredCount,
                validate: validate
            )
            if current.count >= requiredCount {
                return current
            }
            if nowMs() >= deadline {
                return current
            }
            try? await Task.sleep(nanoseconds: TransportConfig.notaryReceiptCollectPollIntervalMs * 1_000_000)
        }
    }

    func selectReceipts(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String],
        minCount: Int,
        validate: (String, NotaryReceipt) -> Bool
    ) -> [String] {
        pruneReceipts(now: nowMs())

        let requirementKey = requirementKey(
            requestID: requestID,
            paymentID: paymentID,
            mintURL: mintURL,
            unit: unit,
            nullifiers: nullifiers
        )
        guard let candidates = receiptsByRequirementKey[requirementKey], !candidates.isEmpty else {
            return []
        }

        var selected: [String] = []
        var seenNotaryIDs: Set<String> = []
        for candidate in candidates.values.sorted(by: { $0.receipt.issuedAtMs > $1.receipt.issuedAtMs }) {
            let signingKey = candidate.receipt.notarySigningKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let notaryID = signingKey.isEmpty
                ? candidate.receipt.notaryPeerID.lowercased()
                : signingKey
            guard !seenNotaryIDs.contains(notaryID) else { continue }
            guard validate(candidate.encodedReceipt, candidate.receipt) else { continue }
            seenNotaryIDs.insert(notaryID)
            selected.append(candidate.encodedReceipt)
            if selected.count >= minCount {
                break
            }
        }

        return selected
    }

    func decodeReceipt(_ encoded: String) -> NotaryReceipt? {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if trimmed.hasPrefix(Self.receiptPrefix) {
            payload = String(trimmed.dropFirst(Self.receiptPrefix.count))
        } else {
            payload = trimmed
        }

        guard let data = Data(base64URLEncoded: payload) else { return nil }
        do {
            return try JSONDecoder().decode(NotaryReceipt.self, from: data)
        } catch {
            return nil
        }
    }

    func receiptSigningPayload(
        requestID: String,
        paymentID: String,
        mintHint: String?,
        unit: String,
        nullifierDigest: String,
        nullifierCount: Int,
        notaryPeerID: String,
        notarySigningKey: String,
        issuedAtMs: UInt64
    ) -> Data {
        let normalizedHint = mintHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedUnit = normalizedUnit(unit)
        let normalizedDigest = nullifierDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedNotary = notaryPeerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKey = notarySigningKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let payload = "anr1|\(requestID)|\(paymentID)|\(normalizedHint)|\(normalizedUnit)|\(normalizedDigest)|\(nullifierCount)|\(normalizedNotary)|\(normalizedKey)|\(issuedAtMs)"
        return Data(payload.utf8)
    }

    func receiptContextMatches(
        _ receipt: NotaryReceipt,
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String]
    ) -> Bool {
        guard receipt.requestID == requestID,
              receipt.paymentID == paymentID else {
            return false
        }

        let canonical = canonicalNullifiers(nullifiers)
        guard !canonical.isEmpty else { return false }

        let normalized = normalizedUnit(unit)
        let hint = mintHint(for: mintURL, unit: normalized)
        let digest = digestForNullifiers(mintHint: hint, unit: normalized, nullifiers: canonical)
        guard receipt.nullifierDigest == digest else { return false }
        guard receipt.unit == normalized else { return false }
        guard receipt.mintHint == hint else { return false }
        guard receipt.nullifierCount == UInt16(min(canonical.count, Int(UInt16.max))) else { return false }
        return true
    }

    private func request(from envelope: Envelope) -> NotaryRequest? {
        guard let requestID = envelope.requestID?.trimmingCharacters(in: .whitespacesAndNewlines), !requestID.isEmpty,
              let paymentID = envelope.paymentID?.trimmingCharacters(in: .whitespacesAndNewlines), !paymentID.isEmpty,
              let unitRaw = envelope.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unitRaw.isEmpty,
              let nullifiersRaw = envelope.nullifiers else {
            return nil
        }

        let canonical = canonicalNullifiers(nullifiersRaw)
        guard !canonical.isEmpty else { return nil }

        let normalizedUnit = normalizedUnit(unitRaw)
        let mintHint = envelope.mintHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedDigest = digestForNullifiers(mintHint: mintHint, unit: normalizedUnit, nullifiers: canonical)
        let digest = envelope.nullifierDigest?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard digest == expectedDigest else { return nil }

        return NotaryRequest(
            requestID: requestID,
            paymentID: paymentID,
            mintHint: mintHint,
            unit: normalizedUnit,
            nullifierDigest: expectedDigest,
            nullifiers: canonical,
            requesterPeerID: envelope.requesterPeerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ts: envelope.ts ?? nowMs()
        )
    }

    private func encodeRequestEnvelope(request: NotaryRequest, room: String?) -> String? {
        let envelope = Envelope(
            version: 1,
            type: .request,
            eventID: stableHash("request|\(request.requestID)|\(request.paymentID)|\(request.nullifierDigest)|\(request.ts)"),
            room: room,
            requestID: request.requestID,
            paymentID: request.paymentID,
            mintHint: request.mintHint,
            unit: request.unit,
            nullifierDigest: request.nullifierDigest,
            nullifiers: request.nullifiers,
            requesterPeerID: request.requesterPeerID,
            ts: request.ts,
            receipt: nil
        )
        return encodeEnvelope(envelope)
    }

    private func encodeEnvelope(_ envelope: Envelope) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard data.count <= maxMessageBytes,
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            seenEvents.record(dedupeKey(for: envelope), value: true)
            return Self.payloadPrefix + content
        } catch {
            SecureLogger.error("Failed to encode notary envelope: \(error)", category: .session)
            return nil
        }
    }

    private func decodeEnvelope(_ content: String) -> Envelope? {
        let encoded = String(content.dropFirst(Self.payloadPrefix.count))
        guard let data = encoded.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            SecureLogger.warning("Failed to decode notary envelope: \(error)", category: .session)
            return nil
        }
    }

    private func dedupeKey(for envelope: Envelope) -> String {
        let trimmed = envelope.eventID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return trimmed
        }
        switch envelope.type {
        case .request:
            return stableHash("request|\(envelope.requestID ?? "")|\(envelope.paymentID ?? "")|\(envelope.nullifierDigest ?? "")|\(envelope.ts ?? 0)")
        case .attest:
            return stableHash("attest|\(envelope.requestID ?? "")|\(envelope.paymentID ?? "")|\(envelope.nullifierDigest ?? "")|\(envelope.receipt ?? "")")
        }
    }

    private func encodeReceipt(_ receipt: NotaryReceipt) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(receipt)
            return Self.receiptPrefix + data.base64URLEncodedString()
        } catch {
            return nil
        }
    }

    private func insertReceipt(encodedReceipt: String, receipt: NotaryReceipt) {
        let now = nowMs()
        let requirementKey = requirementKey(
            requestID: receipt.requestID,
            paymentID: receipt.paymentID,
            mintHint: receipt.mintHint,
            unit: receipt.unit,
            nullifierDigest: receipt.nullifierDigest
        )
        let receiptKey = stableHash("\(receipt.notaryPeerID.lowercased())|\(receipt.issuedAtMs)|\(encodedReceipt)")

        var receipts = receiptsByRequirementKey[requirementKey] ?? [:]
        if receipts[receiptKey] == nil {
            receiptOrder.append((requirementKey: requirementKey, receiptKey: receiptKey))
        }
        receipts[receiptKey] = ReceiptCacheEntry(receipt: receipt, encodedReceipt: encodedReceipt, seenAtMs: now)
        receiptsByRequirementKey[requirementKey] = receipts

        pruneReceipts(now: now)
        trimReceiptCapacityIfNeeded()
    }

    private func pruneReceipts(now: UInt64) {
        guard !receiptsByRequirementKey.isEmpty else { return }
        let cutoff = now > receiptTTLms ? (now - receiptTTLms) : 0

        for (requirementKey, entries) in receiptsByRequirementKey {
            let filtered = entries.filter { _, entry in
                entry.seenAtMs >= cutoff
            }
            if filtered.isEmpty {
                receiptsByRequirementKey.removeValue(forKey: requirementKey)
            } else {
                receiptsByRequirementKey[requirementKey] = filtered
            }
        }

        receiptOrder = receiptOrder.filter { pair in
            guard let current = receiptsByRequirementKey[pair.requirementKey] else { return false }
            return current[pair.receiptKey] != nil
        }
    }

    private func trimReceiptCapacityIfNeeded() {
        guard receiptOrder.count > receiptCacheCapacity else { return }

        let overflow = receiptOrder.count - receiptCacheCapacity
        guard overflow > 0 else { return }
        for _ in 0..<overflow {
            guard !receiptOrder.isEmpty else { break }
            let oldest = receiptOrder.removeFirst()
            guard var entries = receiptsByRequirementKey[oldest.requirementKey] else { continue }
            entries.removeValue(forKey: oldest.receiptKey)
            if entries.isEmpty {
                receiptsByRequirementKey.removeValue(forKey: oldest.requirementKey)
            } else {
                receiptsByRequirementKey[oldest.requirementKey] = entries
            }
        }
    }

    private func requirementKey(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        nullifiers: [String]
    ) -> String {
        let normalizedUnit = normalizedUnit(unit)
        let hint = mintHint(for: mintURL, unit: normalizedUnit)
        let digest = digestForNullifiers(mintHint: hint, unit: normalizedUnit, nullifiers: canonicalNullifiers(nullifiers))
        return requirementKey(
            requestID: requestID,
            paymentID: paymentID,
            mintHint: hint,
            unit: normalizedUnit,
            nullifierDigest: digest
        )
    }

    private func requirementKey(
        requestID: String,
        paymentID: String,
        mintHint: String?,
        unit: String,
        nullifierDigest: String
    ) -> String {
        let hint = mintHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(requestID.lowercased())|\(paymentID.lowercased())|\(hint)|\(normalizedUnit(unit))|\(nullifierDigest.lowercased())"
    }

    private func canonicalNullifiers(_ nullifiers: [String]) -> [String] {
        let normalized = nullifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [] }
        return Array(Set(normalized)).sorted()
    }

    private func normalizedUnit(_ unit: String) -> String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func mintHint(for mintURL: String, unit: String) -> String {
        stableHash("\(mintURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(normalizedUnit(unit))")
    }

    private func digestForNullifiers(mintHint: String?, unit: String, nullifiers: [String]) -> String {
        let hint = mintHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let joined = canonicalNullifiers(nullifiers).joined(separator: ",")
        return stableHash("\(hint)|\(normalizedUnit(unit))|\(joined)")
    }

    private func stableHash(_ value: String) -> String {
        value.data(using: .utf8)?.sha256Hash().hexEncodedString() ?? UUID().uuidString.lowercased()
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded: String) {
        var normalized = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }
}
