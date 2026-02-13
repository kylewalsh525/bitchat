import Foundation
import BitLogger

enum AgentPaymentState: String, Codable, CaseIterable {
    case paymentRequested
    case payloadSent
    case acceptedOffline
    case finalizedOnline
    case rejected
    case failed
}

struct AgentPaymentRecord: Codable, Equatable {
    let requestID: String
    var sessionID: String?
    var peerID: String
    var paymentID: String
    var rail: String
    var mintURL: String
    var unit: String
    var amount: UInt64
    var settlementMode: AgentSettlementMode
    var requiresLocking: AgentPaymentLockingMode?
    var lockPubkey: String?
    var lockSigFlag: UInt8?
    var paymentRequest: String
    var payload: String?
    var nullifiers: [String]
    var notaryReceipts: [String]
    var state: AgentPaymentState
    var details: String?
    let createdAtMs: UInt64
    var updatedAtMs: UInt64
    var expiresAtMs: UInt64

    private enum CodingKeys: String, CodingKey {
        case requestID
        case sessionID
        case peerID
        case paymentID
        case rail
        case mintURL
        case unit
        case amount
        case settlementMode
        case requiresLocking
        case lockPubkey
        case lockSigFlag
        case paymentRequest
        case payload
        case nullifiers
        case notaryReceipts
        case state
        case details
        case createdAtMs
        case updatedAtMs
        case expiresAtMs
    }

    init(
        requestID: String,
        sessionID: String?,
        peerID: String,
        paymentID: String,
        rail: String,
        mintURL: String,
        unit: String,
        amount: UInt64,
        settlementMode: AgentSettlementMode,
        requiresLocking: AgentPaymentLockingMode?,
        lockPubkey: String?,
        lockSigFlag: UInt8?,
        paymentRequest: String,
        payload: String?,
        nullifiers: [String],
        notaryReceipts: [String],
        state: AgentPaymentState,
        details: String?,
        createdAtMs: UInt64,
        updatedAtMs: UInt64,
        expiresAtMs: UInt64
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.peerID = peerID
        self.paymentID = paymentID
        self.rail = rail
        self.mintURL = mintURL
        self.unit = unit
        self.amount = amount
        self.settlementMode = settlementMode
        self.requiresLocking = requiresLocking
        self.lockPubkey = lockPubkey
        self.lockSigFlag = lockSigFlag
        self.paymentRequest = paymentRequest
        self.payload = payload
        self.nullifiers = nullifiers
        self.notaryReceipts = notaryReceipts
        self.state = state
        self.details = details
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.expiresAtMs = expiresAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        peerID = try container.decode(String.self, forKey: .peerID)
        paymentID = try container.decode(String.self, forKey: .paymentID)
        rail = try container.decode(String.self, forKey: .rail)
        mintURL = try container.decode(String.self, forKey: .mintURL)
        unit = try container.decode(String.self, forKey: .unit)
        amount = try container.decode(UInt64.self, forKey: .amount)
        settlementMode = try container.decode(AgentSettlementMode.self, forKey: .settlementMode)
        requiresLocking = try container.decodeIfPresent(AgentPaymentLockingMode.self, forKey: .requiresLocking)
        lockPubkey = try container.decodeIfPresent(String.self, forKey: .lockPubkey)
        lockSigFlag = try container.decodeIfPresent(UInt8.self, forKey: .lockSigFlag)
        paymentRequest = try container.decode(String.self, forKey: .paymentRequest)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        nullifiers = try container.decodeIfPresent([String].self, forKey: .nullifiers) ?? []
        notaryReceipts = try container.decodeIfPresent([String].self, forKey: .notaryReceipts) ?? []
        state = try container.decode(AgentPaymentState.self, forKey: .state)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        createdAtMs = try container.decode(UInt64.self, forKey: .createdAtMs)
        updatedAtMs = try container.decode(UInt64.self, forKey: .updatedAtMs)
        expiresAtMs = try container.decode(UInt64.self, forKey: .expiresAtMs)
    }
}

final class AgentPaymentStore {
    enum ValidationResult: Equatable {
        case accepted
        case duplicateForRequest
        case replayAcrossRequests
        case paymentMismatch
    }

    private struct PersistedState: Codable {
        var records: [String: AgentPaymentRecord] = [:]
        var nullifierToRequestID: [String: String] = [:]
    }

    private let storeURL: URL
    private var state = PersistedState()

    init(storeURL: URL = AgentPaymentStore.defaultStoreURL()) {
        self.storeURL = storeURL
        load()
    }

    func wipeAll() {
        state = PersistedState()
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.removeItem(at: storeURL)
            }
        } catch {
            SecureLogger.error("Failed to wipe payment store: \\(error)", category: .session)
        }
    }

    func recordPaymentRequest(_ record: AgentPaymentRecord) {
        state.records[record.requestID] = record
        save()
    }

    func markPayloadSent(requestID: String, payload: String, nullifiers: [String]) {
        guard var record = state.records[requestID] else { return }
        record.payload = payload
        record.nullifiers = nullifiers
        record.state = .payloadSent
        record.updatedAtMs = nowMs()
        state.records[requestID] = record
        save()
    }

    func cacheIncomingPayload(requestID: String, payload: String, nullifiers: [String]) {
        guard var record = state.records[requestID] else { return }
        record.payload = payload
        if !nullifiers.isEmpty {
            let known = Set(record.nullifiers)
            let additional = nullifiers.filter { !known.contains($0) }
            if !additional.isEmpty {
                record.nullifiers.append(contentsOf: additional)
            }
            for nullifier in nullifiers {
                state.nullifierToRequestID[nullifier] = requestID
            }
        }
        record.updatedAtMs = nowMs()
        state.records[requestID] = record
        save()
    }

    func markReceipt(
        requestID: String,
        status: AgentPaymentReceiptStatus,
        details: String?,
        nullifiers: [String],
        notaryReceipts: [String]? = nil
    ) {
        guard var record = state.records[requestID] else { return }
        record.state = mapReceiptStatus(status)
        record.details = details
        if !nullifiers.isEmpty {
            record.nullifiers = nullifiers
            for nullifier in nullifiers {
                state.nullifierToRequestID[nullifier] = requestID
            }
        }
        if let notaryReceipts {
            record.notaryReceipts = dedupeNotaryReceipts(notaryReceipts)
        }
        record.updatedAtMs = nowMs()
        state.records[requestID] = record
        save()
    }

    func markFailed(requestID: String, details: String) {
        guard var record = state.records[requestID] else { return }
        record.state = .failed
        record.details = details
        record.updatedAtMs = nowMs()
        state.records[requestID] = record
        save()
    }

    func record(for requestID: String) -> AgentPaymentRecord? {
        state.records[requestID]
    }

    func allRecords() -> [AgentPaymentRecord] {
        state.records.values.sorted { lhs, rhs in
            if lhs.updatedAtMs == rhs.updatedAtMs {
                return lhs.requestID < rhs.requestID
            }
            return lhs.updatedAtMs > rhs.updatedAtMs
        }
    }

    func validateIncomingPayload(requestID: String, paymentID: String, nullifiers: [String]) -> ValidationResult {
        if let record = state.records[requestID], record.paymentID != paymentID {
            return .paymentMismatch
        }

        for nullifier in nullifiers {
            if let existingRequest = state.nullifierToRequestID[nullifier] {
                if existingRequest == requestID {
                    return .duplicateForRequest
                }
                return .replayAcrossRequests
            }
        }

        for nullifier in nullifiers {
            state.nullifierToRequestID[nullifier] = requestID
        }

        if var record = state.records[requestID] {
            let known = Set(record.nullifiers)
            let additional = nullifiers.filter { !known.contains($0) }
            if !additional.isEmpty {
                record.nullifiers.append(contentsOf: additional)
                record.updatedAtMs = nowMs()
                state.records[requestID] = record
            }
        }

        save()
        return .accepted
    }

    func offlineOutstandingCount(for peerID: String? = nil) -> Int {
        state.records.values.filter { record in
            if let peerID, record.peerID != peerID { return false }
            return record.state == .acceptedOffline
        }.count
    }

    func pendingOfflineFinalizations() -> [AgentPaymentRecord] {
        state.records.values
            .filter { $0.state == .acceptedOffline }
            .sorted { $0.updatedAtMs < $1.updatedAtMs }
    }

    private func mapReceiptStatus(_ status: AgentPaymentReceiptStatus) -> AgentPaymentState {
        switch status {
        case .acceptedOffline:
            return .acceptedOffline
        case .finalizedOnline:
            return .finalizedOnline
        case .rejected:
            return .rejected
        }
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func dedupeNotaryReceipts(_ receipts: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for receipt in receipts {
            let trimmed = receipt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(trimmed)
        }
        return ordered
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            SecureLogger.error("Failed to load payment store: \(error)", category: .session)
            state = PersistedState()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            SecureLogger.error("Failed to save payment store: \(error)", category: .session)
        }
    }

    private static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("bitchat/agent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("payments.json")
    }
}
