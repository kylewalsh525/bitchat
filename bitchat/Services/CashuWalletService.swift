import Foundation
import BitFoundation
import Security

final class CashuWalletService {
    enum WalletError: LocalizedError {
        case invalidToken
        case insufficientBalance(required: UInt64, available: UInt64)
        case unsupportedMint
        case mintsNotAllowed([String])

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "invalid cashu token"
            case .insufficientBalance(let required, let available):
                return "insufficient balance (need \(required), have \(available))"
            case .unsupportedMint:
                return "mint is not supported"
            case .mintsNotAllowed(let mints):
                if mints.count == 1 {
                    return "mint is not approved"
                }
                return "mints are not approved"
            }
        }
    }

    private struct StoredProof: Codable, Equatable {
        let mintURL: String
        let unit: String
        let proof: CashuProof

        var fingerprint: String {
            proof.fingerprint
        }
    }

    private struct WalletState: Codable {
        var proofs: [StoredProof] = []
        var reservedByPaymentID: [String: [StoredProof]] = [:]
    }

    private let keychain: KeychainManagerProtocol
    private let allowlist: CashuMintAllowlistStore
    private let service = "bitchat.cashu.wallet"
    private let account = "wallet.v1"
    private var state = WalletState()

    private func postUpdateNotification(reason: String, rail: AgentPaymentRail, requestID: String? = nil) {
        var payload: [String: String] = [
            WalletNotificationKeys.source: "CashuWalletService",
            WalletNotificationKeys.rail: rail.rawValue,
            WalletNotificationKeys.reason: reason
        ]
        if let requestID {
            payload[WalletNotificationKeys.requestID] = requestID
        }
        NotificationCenter.default.post(
            name: .cashuWalletDidUpdate,
            object: self,
            userInfo: payload
        )
    }

    init(keychain: KeychainManagerProtocol, allowlist: CashuMintAllowlistStore) {
        self.keychain = keychain
        self.allowlist = allowlist
        load()
    }

    func importToken(_ token: String) throws -> UInt64 {
        guard let bundles = CashuTokenParser.parseTokenString(token) else {
            throw WalletError.invalidToken
        }

        let uniqueMints = Array(Set(bundles.map { CashuMintAllowlistStore.normalizeMintURL($0.mintURL) }))
            .filter { !$0.isEmpty }
            .sorted()
        let unapproved = uniqueMints.filter { !allowlist.isAllowed(mintURL: $0) }
        if !unapproved.isEmpty {
            throw WalletError.mintsNotAllowed(unapproved)
        }

        let existing = Set(state.proofs.map { $0.fingerprint })
        var next = state.proofs
        var importedAmount: UInt64 = 0

        for bundle in bundles {
            let normalizedMint = CashuMintAllowlistStore.normalizeMintURL(bundle.mintURL)
            for proof in bundle.proofs {
                let stored = StoredProof(mintURL: normalizedMint, unit: bundle.unit, proof: proof)
                if existing.contains(stored.fingerprint) {
                    continue
                }
                next.append(stored)
                importedAmount += proof.amount
            }
        }

        guard next != state.proofs else {
            return 0
        }

        state.proofs = next
        save()
        postUpdateNotification(reason: "import", rail: .cashu)
        return importedAmount
    }

    func exportToken(mintURL: String, unit: String, amount: UInt64) throws -> String {
        let normalizedMint = CashuMintAllowlistStore.normalizeMintURL(mintURL)
        let selected = try selectProofs(mintURL: normalizedMint, unit: unit, amount: amount)
        let selectedFingerprints = Set(selected.map { $0.fingerprint })
        let originalProofs = state.proofs
        state.proofs.removeAll { selectedFingerprints.contains($0.fingerprint) }
        let mutated = originalProofs != state.proofs

        guard let token = CashuTokenParser.exportTokenString(
            mintURL: normalizedMint,
            unit: unit,
            proofs: selected.map { $0.proof }
        ) else {
            state.proofs = originalProofs
            save()
            throw WalletError.invalidToken
        }
        if mutated {
            save()
            postUpdateNotification(reason: "export", rail: .cashu)
        }
        return token
    }

    func balance(mintURL: String? = nil, unit: String? = nil) -> UInt64 {
        state.proofs.reduce(0) { partial, item in
            if let mintURL, item.mintURL != mintURL { return partial }
            if let unit, item.unit != unit { return partial }
            return partial + item.proof.amount
        }
    }

    func availableUnits() -> [String] {
        Array(Set(state.proofs.map { $0.unit })).sorted()
    }

    func preparePaymentPayload(request: CashuPaymentRequestEnvelope, clientNonce: String) throws -> CashuPaymentPayloadEnvelope {
        let normalizedMint = CashuMintAllowlistStore.normalizeMintURL(request.mintURL)
        if !allowlist.isAllowed(mintURL: normalizedMint) {
            throw WalletError.mintsNotAllowed([normalizedMint])
        }

        let selected = try selectProofs(mintURL: normalizedMint, unit: request.unit, amount: request.amount)
        state.reservedByPaymentID[request.paymentID] = selected
        let fingerprints = Set(selected.map { $0.fingerprint })
        state.proofs.removeAll { fingerprints.contains($0.fingerprint) }
        save()

        postUpdateNotification(reason: "reserve", rail: .cashu, requestID: request.paymentID)

        let total = selected.reduce(UInt64(0)) { $0 + $1.proof.amount }
        let nullifiers = selected.map { cashuNullifier(mintURL: $0.mintURL, unit: $0.unit, secret: $0.proof.secret) }

        return CashuPaymentPayloadEnvelope(
            paymentID: request.paymentID,
            requestID: request.requestID,
            mintURL: normalizedMint,
            unit: request.unit,
            totalAmount: total,
            proofs: selected.map { $0.proof },
            nullifiers: nullifiers,
            clientNonce: clientNonce,
            createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func commitReserved(paymentID: String) {
        guard state.reservedByPaymentID[paymentID] != nil else { return }
        state.reservedByPaymentID.removeValue(forKey: paymentID)
        save()
        postUpdateNotification(reason: "commit", rail: .cashu, requestID: paymentID)
    }

    func replaceReserved(paymentID: String, mintURL: String, unit: String, proofs: [CashuProof]) {
        let next = proofs.map {
            StoredProof(mintURL: mintURL, unit: unit, proof: $0)
        }
        if let existing = state.reservedByPaymentID[paymentID], existing == next {
            return
        }
        state.reservedByPaymentID[paymentID] = next
        postUpdateNotification(reason: "replace-reserved", rail: .cashu, requestID: paymentID)
        save()
    }

    func reservedSummary() -> [(paymentID: String, mintURL: String, unit: String, amount: UInt64)] {
        state.reservedByPaymentID.map { paymentID, items in
            let amount = items.reduce(UInt64(0)) { $0 + $1.proof.amount }
            let mint = items.first?.mintURL ?? ""
            let unit = items.first?.unit ?? ""
            return (paymentID: paymentID, mintURL: mint, unit: unit, amount: amount)
        }
        .sorted { lhs, rhs in lhs.paymentID < rhs.paymentID }
    }

    func balancesByMintAndUnit() -> [String: [String: UInt64]] {
        var out: [String: [String: UInt64]] = [:]
        for item in state.proofs {
            out[item.mintURL, default: [:]][item.unit, default: 0] += item.proof.amount
        }
        return out
    }

    func rollbackReserved(paymentID: String) {
        guard let reserved = state.reservedByPaymentID.removeValue(forKey: paymentID) else { return }
        state.proofs.append(contentsOf: reserved)
        postUpdateNotification(reason: "rollback", rail: .cashu, requestID: paymentID)
        save()
    }

    /// Clears all wallet proofs/reservations and removes the persisted keychain payload.
    /// Intended for emergency wipe flows (panic wipe) and tests.
    func wipeAllWallet() {
        let hasState = !state.proofs.isEmpty || !state.reservedByPaymentID.isEmpty
        state = WalletState()
        keychain.delete(key: account, service: service)
        if hasState {
            postUpdateNotification(reason: "wipe", rail: .cashu)
        }
    }

    private func selectProofs(mintURL: String, unit: String, amount: UInt64) throws -> [StoredProof] {
        let normalizedMint = CashuMintAllowlistStore.normalizeMintURL(mintURL)
        let available = state.proofs
            .filter { $0.mintURL == normalizedMint && $0.unit == unit }
            .sorted { lhs, rhs in
                if lhs.proof.amount == rhs.proof.amount {
                    return lhs.fingerprint < rhs.fingerprint
                }
                return lhs.proof.amount < rhs.proof.amount
            }

        var selected: [StoredProof] = []
        var total: UInt64 = 0

        for proof in available.reversed() {
            selected.append(proof)
            total += proof.proof.amount
            if total >= amount { break }
        }

        if total < amount {
            throw WalletError.insufficientBalance(required: amount, available: total)
        }

        return selected
    }

    private func load() {
        guard let data = keychain.load(key: account, service: service),
              let decoded = try? JSONDecoder().decode(WalletState.self, from: data) else {
            state = WalletState()
            return
        }
        state = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        keychain.save(
            key: account,
            data: data,
            service: service,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }
}
