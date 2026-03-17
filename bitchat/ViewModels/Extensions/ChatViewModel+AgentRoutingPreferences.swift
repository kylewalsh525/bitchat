//
// ChatViewModel+AgentRoutingPreferences.swift
// bitchat
//
// Requester-side routing preferences (known-model hints + min quality floor).
//

import Foundation

extension ChatViewModel {
    private struct AgentPaymentCompatibilitySnapshot {
        let cashuMints: Set<String>
        let x402Ready: Bool
    }

    private enum AgentPaymentCompatibilityIssue {
        case missingCashuMintOverlap(providerMints: [String])
        case x402Unavailable
    }

    @MainActor
    func selectAgentCandidate(role: String, allowAnyRole: Bool, minimumQuality: UInt8) -> BitchatPeer? {
        selectAgentCandidates(role: role, allowAnyRole: allowAnyRole, minimumQuality: minimumQuality, limit: 1).first
    }

    @MainActor
    func selectAgentCandidates(role: String, allowAnyRole: Bool, minimumQuality: UInt8, limit: Int? = nil) -> [BitchatPeer] {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requiredQuality = max(minimumQuality, agentRequesterPreferences.minQualityScore)
        let compatibility = paymentCompatibilitySnapshot()

        let candidates = allPeers.filter { peer in
            guard let info = peer.agentInfo else { return false }
            if paymentCompatibilityIssue(for: info, snapshot: compatibility) != nil {
                return false
            }
            let roleMatch = allowAnyRole || info.normalizedRole == normalizedRole
            return roleMatch
                && info.qualityScore >= requiredQuality
                && paymentFilter.matches(info)
        }

        let reachable = candidates.filter { $0.isConnected || $0.isReachable }
        let sorted = reachable.sorted(by: agentPreferenceSort)
        if let limit, limit > 0 {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    @MainActor
    func hasReachableRoleCandidateIgnoringPaymentCompatibility(
        role: String,
        allowAnyRole: Bool,
        minimumQuality: UInt8
    ) -> Bool {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requiredQuality = max(minimumQuality, agentRequesterPreferences.minQualityScore)

        return allPeers.contains { peer in
            guard peer.isConnected || peer.isReachable else { return false }
            guard let info = peer.agentInfo else { return false }
            let roleMatch = allowAnyRole || info.normalizedRole == normalizedRole
            return roleMatch
                && info.qualityScore >= requiredQuality
                && paymentFilter.matches(info)
        }
    }

    @MainActor
    func isPaymentCompatibleProvider(_ info: AgentInfo) -> Bool {
        paymentCompatibilityIssue(for: info, snapshot: paymentCompatibilitySnapshot()) == nil
    }

    @MainActor
    func paymentCompatibilityError(for info: AgentInfo) -> String {
        let snapshot = paymentCompatibilitySnapshot()
        switch paymentCompatibilityIssue(for: info, snapshot: snapshot) {
        case .missingCashuMintOverlap(let providerMints):
            let providerHint = providerMints.isEmpty ? "none listed" : providerMints.joined(separator: ", ")
            return "provider requires Cashu mint overlap. Provider mints: \(providerHint). Approve/import one of these mints in Wallet, or choose an x402-enabled provider."
        case .x402Unavailable:
            return "provider requires x402 payments. Enable x402 in Requester Preferences and connect a guest wallet in Wallet setup."
        case nil:
            return "provider payment terms are compatible."
        }
    }

    @MainActor
    func resolvedKnownModel(for info: AgentInfo?) -> AgentKnownModelMatch? {
        guard let info else { return nil }
        return knownModelCatalog.resolve(modelId: info.modelId, modelHash: info.modelHash)
    }

    @MainActor
    private func agentPreferenceSort(_ lhs: BitchatPeer, _ rhs: BitchatPeer) -> Bool {
        let lRank = agentPreferenceRank(lhs)
        let rRank = agentPreferenceRank(rhs)

        if lRank.connectedRank != rRank.connectedRank { return lRank.connectedRank > rRank.connectedRank }
        if lRank.reachableRank != rRank.reachableRank { return lRank.reachableRank > rRank.reachableRank }
        if lRank.combinedScore != rRank.combinedScore { return lRank.combinedScore > rRank.combinedScore }
        if lRank.qualityScore != rRank.qualityScore { return lRank.qualityScore > rRank.qualityScore }
        return lRank.stableID < rRank.stableID
    }

    private struct AgentPreferenceRank {
        let connectedRank: Int
        let reachableRank: Int
        let combinedScore: Int
        let qualityScore: Int
        let stableID: String
    }

    @MainActor
    private func agentPreferenceRank(_ peer: BitchatPeer) -> AgentPreferenceRank {
        let info = peer.agentInfo
        let quality = Int(info?.qualityScore ?? 0)
        let railBonus = info.map { agentRailBonus(info: $0) } ?? 0
        let bonus = info.map { agentKnownModelBonus(info: $0) } ?? 0
        let combined = quality + bonus + railBonus
        return AgentPreferenceRank(
            connectedRank: peer.isConnected ? 1 : 0,
            reachableRank: peer.isReachable ? 1 : 0,
            combinedScore: combined,
            qualityScore: quality,
            stableID: peer.peerID.id
        )
    }

    @MainActor
    private func agentKnownModelBonus(info: AgentInfo) -> Int {
        guard agentRequesterPreferences.preferKnownModels else { return 0 }
        let match = knownModelCatalog.resolve(modelId: info.modelId, modelHash: info.modelHash)

        if let match {
            let preferredSet = agentRequesterPreferences.preferredKnownModelIDs
            let inPreferred = preferredSet.isEmpty || preferredSet.contains(match.model.id)
            if inPreferred {
                return match.kind == .hash ? 12 : 8
            }
            return match.kind == .hash ? 4 : 2
        }

        return agentRequesterPreferences.penalizeUnknownModels ? -4 : 0
    }

    @MainActor
    private func agentRailBonus(info: AgentInfo) -> Int {
        guard let terms = info.paymentTerms?.sanitized() else { return 0 }
        if terms.paymentRail == agentRequesterPreferences.defaultPaymentRail {
            return 5
        }
        return -1
    }

    @MainActor
    private func paymentCompatibilitySnapshot() -> AgentPaymentCompatibilitySnapshot {
        var cashuMints = Set(
            cashuMintAllowlistStore.allowedMintURLs
                .map(CashuMintAllowlistStore.normalizeMintURL)
                .filter { !$0.isEmpty }
        )
        let walletMints = cashuWalletService.balancesByMintAndUnit().keys
            .map(CashuMintAllowlistStore.normalizeMintURL)
            .filter { !$0.isEmpty }
        cashuMints.formUnion(walletMints)

        let x402Ready = agentRequesterPreferences.allowX402Payments
            && agentMeshFlags.enableX402Payments
            && thirdwebGuestWalletBridge.isBridgeAvailable
            && thirdwebGuestWalletBridge.configuredClientID() != nil

        return AgentPaymentCompatibilitySnapshot(
            cashuMints: cashuMints,
            x402Ready: x402Ready
        )
    }

    private func paymentCompatibilityIssue(
        for info: AgentInfo,
        snapshot: AgentPaymentCompatibilitySnapshot
    ) -> AgentPaymentCompatibilityIssue? {
        guard let terms = info.paymentTerms?.sanitized() else { return nil }
        switch terms.paymentRail {
        case .none:
            return nil
        case .x402:
            return snapshot.x402Ready ? nil : .x402Unavailable
        case .cashu:
            let providerMints = terms.acceptedMints
                .map(CashuMintAllowlistStore.normalizeMintURL)
                .filter { !$0.isEmpty }
            guard !providerMints.isEmpty else {
                return .missingCashuMintOverlap(providerMints: [])
            }
            let providerSet = Set(providerMints)
            return providerSet.isDisjoint(with: snapshot.cashuMints)
                ? .missingCashuMintOverlap(providerMints: providerMints)
                : nil
        }
    }
}
