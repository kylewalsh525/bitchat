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
    var enablePayments: Bool
    var enablePaymentLocking: Bool
    var enableX402Payments: Bool

    static let enableRuntimeKey = "bitchat.agent.mesh.runtime.enabled"
    static let enableGatewayKey = "bitchat.agent.mesh.gateway.enabled"
    static let enablePaymentsKey = "bitchat.agent.mesh.payments.enabled"
    static let enablePaymentLockingKey = "bitchat.agent.mesh.payment.locking.enabled"
    static let enableX402PaymentsKey = "bitchat.agent.mesh.payment.x402.enabled"

    static let defaults = AgentMeshFeatureFlags(
        enableRuntime: true,
        enableGateway: true,
        enablePayments: true,
        enablePaymentLocking: true,
        enableX402Payments: false
    )

    static func load(from defaultsStore: UserDefaults = .standard) -> AgentMeshFeatureFlags {
        let runtime = defaultsStore.object(forKey: enableRuntimeKey) as? Bool ?? defaults.enableRuntime
        let gateway = defaultsStore.object(forKey: enableGatewayKey) as? Bool ?? defaults.enableGateway
        let payments = defaultsStore.object(forKey: enablePaymentsKey) as? Bool ?? defaults.enablePayments
        let locking = defaultsStore.object(forKey: enablePaymentLockingKey) as? Bool ?? defaults.enablePaymentLocking
        let x402 = defaultsStore.object(forKey: enableX402PaymentsKey) as? Bool ?? defaults.enableX402Payments
        return AgentMeshFeatureFlags(
            enableRuntime: runtime,
            enableGateway: gateway,
            enablePayments: payments,
            enablePaymentLocking: locking,
            enableX402Payments: x402
        )
    }

    func save(to defaultsStore: UserDefaults = .standard) {
        defaultsStore.set(enableRuntime, forKey: Self.enableRuntimeKey)
        defaultsStore.set(enableGateway, forKey: Self.enableGatewayKey)
        defaultsStore.set(enablePayments, forKey: Self.enablePaymentsKey)
        defaultsStore.set(enablePaymentLocking, forKey: Self.enablePaymentLockingKey)
        defaultsStore.set(enableX402Payments, forKey: Self.enableX402PaymentsKey)
    }
}
