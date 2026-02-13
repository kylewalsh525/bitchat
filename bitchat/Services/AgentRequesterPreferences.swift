//
// AgentRequesterPreferences.swift
// bitchat
//
// Local-only requester preferences that influence agent selection/routing.
//

import Foundation

struct AgentRequesterPreferences: Codable, Equatable {
    var minQualityScore: UInt8
    var preferKnownModels: Bool
    var preferredKnownModelIDs: Set<String>
    var penalizeUnknownModels: Bool
    var allowX402Payments: Bool
    var defaultPaymentRail: AgentPaymentRail
    var quoteAutoPickPolicy: AgentQuoteAutoPickPolicy
    var quoteAutoPickBudget: UInt64

    static let defaults = AgentRequesterPreferences(
        minQualityScore: 0,
        preferKnownModels: true,
        preferredKnownModelIDs: [],
        penalizeUnknownModels: true,
        allowX402Payments: false,
        defaultPaymentRail: .cashu,
        quoteAutoPickPolicy: .manual,
        quoteAutoPickBudget: 0
    )

    private static let storageKey = "bitchat.agent.mesh.requester.preferences"

    private enum CodingKeys: String, CodingKey {
        case minQualityScore
        case preferKnownModels
        case preferredKnownModelIDs
        case penalizeUnknownModels
        case allowX402Payments
        case defaultPaymentRail
        case quoteAutoPickPolicy
        case quoteAutoPickBudget
    }

    init(
        minQualityScore: UInt8,
        preferKnownModels: Bool,
        preferredKnownModelIDs: Set<String>,
        penalizeUnknownModels: Bool,
        allowX402Payments: Bool = false,
        defaultPaymentRail: AgentPaymentRail = .cashu,
        quoteAutoPickPolicy: AgentQuoteAutoPickPolicy = .manual,
        quoteAutoPickBudget: UInt64 = 0
    ) {
        self.minQualityScore = min(minQualityScore, 100)
        self.preferKnownModels = preferKnownModels
        self.preferredKnownModelIDs = preferredKnownModelIDs
        self.penalizeUnknownModels = penalizeUnknownModels
        self.allowX402Payments = allowX402Payments
        self.defaultPaymentRail = defaultPaymentRail == .none ? .cashu : defaultPaymentRail
        self.quoteAutoPickPolicy = quoteAutoPickPolicy
        self.quoteAutoPickBudget = min(quoteAutoPickBudget, 100_000_000)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minQualityScore = min(try container.decodeIfPresent(UInt8.self, forKey: .minQualityScore) ?? 0, 100)
        preferKnownModels = try container.decodeIfPresent(Bool.self, forKey: .preferKnownModels) ?? true
        preferredKnownModelIDs = try container.decodeIfPresent(Set<String>.self, forKey: .preferredKnownModelIDs) ?? []
        penalizeUnknownModels = try container.decodeIfPresent(Bool.self, forKey: .penalizeUnknownModels) ?? true
        allowX402Payments = try container.decodeIfPresent(Bool.self, forKey: .allowX402Payments) ?? false
        let decodedRail = try container.decodeIfPresent(AgentPaymentRail.self, forKey: .defaultPaymentRail) ?? .cashu
        defaultPaymentRail = decodedRail == .none ? .cashu : decodedRail
        quoteAutoPickPolicy = try container.decodeIfPresent(AgentQuoteAutoPickPolicy.self, forKey: .quoteAutoPickPolicy) ?? .manual
        quoteAutoPickBudget = min(try container.decodeIfPresent(UInt64.self, forKey: .quoteAutoPickBudget) ?? 0, 100_000_000)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(min(minQualityScore, 100), forKey: .minQualityScore)
        try container.encode(preferKnownModels, forKey: .preferKnownModels)
        try container.encode(preferredKnownModelIDs, forKey: .preferredKnownModelIDs)
        try container.encode(penalizeUnknownModels, forKey: .penalizeUnknownModels)
        try container.encode(allowX402Payments, forKey: .allowX402Payments)
        try container.encode(defaultPaymentRail == .none ? .cashu : defaultPaymentRail, forKey: .defaultPaymentRail)
        try container.encode(quoteAutoPickPolicy, forKey: .quoteAutoPickPolicy)
        try container.encode(min(quoteAutoPickBudget, 100_000_000), forKey: .quoteAutoPickBudget)
    }

    static func load(from defaultsStore: UserDefaults = .standard) -> AgentRequesterPreferences {
        guard let data = defaultsStore.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AgentRequesterPreferences.self, from: data) else {
            return defaults
        }
        return decoded
    }

    func save(to defaultsStore: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaultsStore.set(data, forKey: Self.storageKey)
    }
}
