//
// AgentInfo.swift
// bitchat
//
// Lightweight agent capability metadata for mesh discovery.
//

import Foundation

struct AgentInfo: Codable, Equatable, Hashable {
    let role: String
    let modelId: String
    let qualityScore: UInt8
    let modelHash: String?

    var normalizedRole: String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct AgentConfig: Codable, Equatable {
    var enabled: Bool
    var role: String
    var modelId: String
    var qualityScore: UInt8
    var modelHash: String?
    var runtime: AgentRuntimeConfig

    var info: AgentInfo? {
        guard enabled else { return nil }
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRole.isEmpty, !trimmedModel.isEmpty else { return nil }
        return AgentInfo(
            role: trimmedRole,
            modelId: trimmedModel,
            qualityScore: min(100, qualityScore),
            modelHash: modelHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static let `default` = AgentConfig(
        enabled: false,
        role: "general",
        modelId: "local",
        qualityScore: 50,
        modelHash: nil,
        runtime: .default
    )

    private enum CodingKeys: String, CodingKey {
        case enabled
        case role
        case modelId
        case qualityScore
        case modelHash
        case runtime
    }

    init(enabled: Bool, role: String, modelId: String, qualityScore: UInt8, modelHash: String?, runtime: AgentRuntimeConfig) {
        self.enabled = enabled
        self.role = role
        self.modelId = modelId
        self.qualityScore = qualityScore
        self.modelHash = modelHash
        self.runtime = runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "general"
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? "local"
        qualityScore = try container.decodeIfPresent(UInt8.self, forKey: .qualityScore) ?? 50
        modelHash = try container.decodeIfPresent(String.self, forKey: .modelHash)
        runtime = try container.decodeIfPresent(AgentRuntimeConfig.self, forKey: .runtime) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(role, forKey: .role)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(qualityScore, forKey: .qualityScore)
        try container.encodeIfPresent(modelHash, forKey: .modelHash)
        try container.encode(runtime, forKey: .runtime)
    }
}
