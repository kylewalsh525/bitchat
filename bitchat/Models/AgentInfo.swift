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
        modelHash: nil
    )
}
