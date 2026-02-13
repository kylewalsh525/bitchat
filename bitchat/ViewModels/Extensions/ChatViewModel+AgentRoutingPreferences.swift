//
// ChatViewModel+AgentRoutingPreferences.swift
// bitchat
//
// Requester-side routing preferences (known-model hints + min quality floor).
//

import Foundation

extension ChatViewModel {
    @MainActor
    func selectAgentCandidate(role: String, allowAnyRole: Bool, minimumQuality: UInt8) -> BitchatPeer? {
        selectAgentCandidates(role: role, allowAnyRole: allowAnyRole, minimumQuality: minimumQuality, limit: 1).first
    }

    @MainActor
    func selectAgentCandidates(role: String, allowAnyRole: Bool, minimumQuality: UInt8, limit: Int? = nil) -> [BitchatPeer] {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requiredQuality = max(minimumQuality, agentRequesterPreferences.minQualityScore)

        let candidates = allPeers.filter { peer in
            guard let info = peer.agentInfo else { return false }
            if let terms = info.paymentTerms?.sanitized() {
                if terms.paymentRail == .x402 && (!agentRequesterPreferences.allowX402Payments || !agentMeshFlags.enableX402Payments) {
                    return false
                }
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
}
