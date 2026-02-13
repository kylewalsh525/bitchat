import Foundation
import P256K
import Security

final class AgentPaymentLockKeyStore {
    struct LockBinding: Equatable {
        let keyRef: String
        let pubkeyHex: String
        let expiresAtMs: UInt64
        let createdAtMs: UInt64
    }

    enum StoreError: LocalizedError {
        case keyGenerationFailed

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:
                return "failed to generate payment lock key"
            }
        }
    }

    private struct PersistedBinding: Codable {
        let requestID: String
        let paymentID: String
        let keyRef: String
        let pubkeyHex: String
        let secretHex: String
        let expiresAtMs: UInt64
        let createdAtMs: UInt64
    }

    private struct PersistedState: Codable {
        var bindingsByRequestPayment: [String: PersistedBinding] = [:]
    }

    private let keychain: KeychainManagerProtocol
    private let service = "bitchat.agent.payment.lockkeys"
    private let account = "lock-bindings.v1"
    private let lock = NSLock()
    private var state = PersistedState()

    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
        load()
    }

    @discardableResult
    func createLockBinding(requestID: String, paymentID: String, expiresAtMs: UInt64) throws -> (pubkeyHex: String, keyRef: String) {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLocked(nowMs: currentMs(), maxDeletes: 64)

        let key = compositeKey(requestID: requestID, paymentID: paymentID)
        if let existing = state.bindingsByRequestPayment[key] {
            return (existing.pubkeyHex, existing.keyRef)
        }

        let privateKey: P256K.Schnorr.PrivateKey
        do {
            privateKey = try P256K.Schnorr.PrivateKey()
        } catch {
            throw StoreError.keyGenerationFailed
        }

        let secretHex = privateKey.dataRepresentation.hexEncodedString()
        let pubkeyHex = Data(privateKey.xonly.bytes).hexEncodedString()
        let createdAtMs = currentMs()
        let binding = PersistedBinding(
            requestID: requestID,
            paymentID: paymentID,
            keyRef: "alp2pk-\(UUID().uuidString)",
            pubkeyHex: pubkeyHex,
            secretHex: secretHex,
            expiresAtMs: expiresAtMs,
            createdAtMs: createdAtMs
        )
        state.bindingsByRequestPayment[key] = binding
        saveLocked()
        return (pubkeyHex, binding.keyRef)
    }

    func loadBinding(requestID: String, paymentID: String) -> LockBinding? {
        lock.lock()
        defer { lock.unlock() }

        let key = compositeKey(requestID: requestID, paymentID: paymentID)
        guard let binding = state.bindingsByRequestPayment[key] else {
            return nil
        }
        if binding.expiresAtMs > 0, currentMs() >= binding.expiresAtMs {
            state.bindingsByRequestPayment.removeValue(forKey: key)
            saveLocked()
            return nil
        }
        return LockBinding(
            keyRef: binding.keyRef,
            pubkeyHex: binding.pubkeyHex,
            expiresAtMs: binding.expiresAtMs,
            createdAtMs: binding.createdAtMs
        )
    }

    func loadSecret(requestID: String, paymentID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let key = compositeKey(requestID: requestID, paymentID: paymentID)
        guard let binding = state.bindingsByRequestPayment[key] else {
            return nil
        }
        if binding.expiresAtMs > 0, currentMs() >= binding.expiresAtMs {
            state.bindingsByRequestPayment.removeValue(forKey: key)
            saveLocked()
            return nil
        }
        return binding.secretHex
    }

    func delete(requestID: String, paymentID: String) {
        lock.lock()
        defer { lock.unlock() }

        let key = compositeKey(requestID: requestID, paymentID: paymentID)
        guard state.bindingsByRequestPayment.removeValue(forKey: key) != nil else { return }
        saveLocked()
    }

    func pruneExpired(nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000), maxDeletes: Int = 64) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(nowMs: nowMs, maxDeletes: maxDeletes)
    }

    func wipeAllBindings() {
        lock.lock()
        defer { lock.unlock() }
        state = PersistedState()
        keychain.delete(key: account, service: service)
    }

    private func compositeKey(requestID: String, paymentID: String) -> String {
        "\(requestID)|\(paymentID)"
    }

    private func currentMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func pruneExpiredLocked(nowMs: UInt64, maxDeletes: Int) {
        guard !state.bindingsByRequestPayment.isEmpty else { return }

        var removed = 0
        for (key, binding) in state.bindingsByRequestPayment {
            guard binding.expiresAtMs > 0, nowMs >= binding.expiresAtMs else { continue }
            state.bindingsByRequestPayment.removeValue(forKey: key)
            removed += 1
            if removed >= max(1, maxDeletes) {
                break
            }
        }

        if removed > 0 {
            saveLocked()
        }
    }

    private func load() {
        guard let data = keychain.load(key: account, service: service),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            state = PersistedState()
            return
        }
        state = decoded
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        keychain.save(
            key: account,
            data: data,
            service: service,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }
}
