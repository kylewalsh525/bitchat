//
// AgentMeshFeatureFlags.swift
// bitchat
//
// Lightweight feature flags for agent mesh.
//

import Foundation

struct AgentMeshFeatureFlags: Codable, Equatable {
    var enableRuntime: Bool
    var enableGateway: Bool

    static let enableRuntimeKey = "bitchat.agent.mesh.runtime.enabled"
    static let enableGatewayKey = "bitchat.agent.mesh.gateway.enabled"

    static let defaults = AgentMeshFeatureFlags(enableRuntime: true, enableGateway: true)

    static func load(from defaultsStore: UserDefaults = .standard) -> AgentMeshFeatureFlags {
        let runtime = defaultsStore.object(forKey: enableRuntimeKey) as? Bool ?? defaults.enableRuntime
        let gateway = defaultsStore.object(forKey: enableGatewayKey) as? Bool ?? defaults.enableGateway
        return AgentMeshFeatureFlags(enableRuntime: runtime, enableGateway: gateway)
    }

    func save(to defaultsStore: UserDefaults = .standard) {
        defaultsStore.set(enableRuntime, forKey: Self.enableRuntimeKey)
        defaultsStore.set(enableGateway, forKey: Self.enableGatewayKey)
    }
}
