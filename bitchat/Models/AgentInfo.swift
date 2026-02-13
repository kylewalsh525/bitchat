//
// AgentInfo.swift
// bitchat
//
// Lightweight agent capability metadata for mesh discovery.
//

import Foundation

enum AgentPaymentRail: String, Codable, CaseIterable {
    case none
    case cashu
    case x402

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = AgentPaymentRail(rawValue: raw) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentSettlementMode: String, Codable, CaseIterable {
    case onlineRequired = "online_required"
    case offlineAccepted = "offline_accepted"
}

enum AgentPaymentPriceModel: String, Codable, CaseIterable {
    case perRequest = "per_request"
    case perToken = "per_token"
}

enum AgentPaymentLockingMode: String, Codable, CaseIterable {
    case none
    case p2pk

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = AgentPaymentLockingMode(rawValue: raw) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentX402Scheme: String, Codable, CaseIterable {
    case exact

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = AgentX402Scheme(rawValue: raw) ?? .exact
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentQuoteAutoPickPolicy: String, Codable, CaseIterable {
    case manual
    case cheapest
    case fastest
    case bestQualityUnderBudget = "best_quality_under_budget"
}

struct AgentQuoteTierPolicy: Codable, Equatable, Hashable {
    var immediateDiscountBps: UInt16
    var standardWaitSeconds: UInt16
    var standardDiscountBps: UInt16
    var economyWaitSeconds: UInt16
    var economyDiscountBps: UInt16

    init(
        immediateDiscountBps: UInt16,
        standardWaitSeconds: UInt16,
        standardDiscountBps: UInt16,
        economyWaitSeconds: UInt16,
        economyDiscountBps: UInt16
    ) {
        self.immediateDiscountBps = immediateDiscountBps
        self.standardWaitSeconds = standardWaitSeconds
        self.standardDiscountBps = standardDiscountBps
        self.economyWaitSeconds = economyWaitSeconds
        self.economyDiscountBps = economyDiscountBps
    }

    static let `default` = AgentQuoteTierPolicy(
        immediateDiscountBps: 0,
        standardWaitSeconds: 15,
        standardDiscountBps: 1_500,
        economyWaitSeconds: 60,
        economyDiscountBps: 3_000
    )

    func sanitized() -> AgentQuoteTierPolicy {
        let immediateDiscount = min(immediateDiscountBps, 9_500)
        let standardWait = max(UInt16(5), min(UInt16(300), standardWaitSeconds))
        let standardDiscount = min(standardDiscountBps, 9_500)
        let minEconomyWait = max(UInt16(standardWait + 5), UInt16(10))
        let economyWait = max(minEconomyWait, min(UInt16(900), economyWaitSeconds))
        let economyDiscount = max(standardDiscount, min(economyDiscountBps, 9_500))
        return AgentQuoteTierPolicy(
            immediateDiscountBps: immediateDiscount,
            standardWaitSeconds: standardWait,
            standardDiscountBps: standardDiscount,
            economyWaitSeconds: economyWait,
            economyDiscountBps: economyDiscount
        )
    }
}

struct AgentNotaryPolicy: Codable, Equatable, Hashable {
    var isNotaryCapable: Bool
    var requiredOfflineSignatures: UInt8
    var collectTimeoutMs: UInt64

    init(isNotaryCapable: Bool, requiredOfflineSignatures: UInt8, collectTimeoutMs: UInt64) {
        self.isNotaryCapable = isNotaryCapable
        self.requiredOfflineSignatures = requiredOfflineSignatures
        self.collectTimeoutMs = collectTimeoutMs
    }

    static let `default` = AgentNotaryPolicy(
        isNotaryCapable: false,
        requiredOfflineSignatures: 0,
        collectTimeoutMs: 1_500
    )

    var effectiveRequiredOfflineSignatures: Int {
        max(0, min(Int(requiredOfflineSignatures), 8))
    }

    var effectiveCollectTimeoutMs: UInt64 {
        let clamped = collectTimeoutMs == 0 ? UInt64(1_500) : collectTimeoutMs
        return max(300, min(15_000, clamped))
    }
}

struct AgentPaymentTerms: Codable, Equatable, Hashable {
    var paymentRail: AgentPaymentRail
    var settlementMode: AgentSettlementMode
    var requiresLocking: AgentPaymentLockingMode?
    var unit: String
    var priceModel: AgentPaymentPriceModel?
    var pricePerRequest: UInt64
    var pricePerInputToken: UInt64?
    var pricePerOutputToken: UInt64?
    var minDeposit: UInt64?
    var granularityTokens: UInt32?
    var acceptedMints: [String]
    var requestTTLSeconds: UInt32
    var x402ChainID: UInt64?
    var x402TokenAddress: String?
    var x402PayTo: String?
    var x402GatewayURL: String?
    var x402FacilitatorID: String?
    var x402Scheme: AgentX402Scheme?

    init(
        paymentRail: AgentPaymentRail,
        settlementMode: AgentSettlementMode,
        requiresLocking: AgentPaymentLockingMode? = nil,
        unit: String,
        priceModel: AgentPaymentPriceModel? = nil,
        pricePerRequest: UInt64,
        pricePerInputToken: UInt64? = nil,
        pricePerOutputToken: UInt64? = nil,
        minDeposit: UInt64? = nil,
        granularityTokens: UInt32? = nil,
        acceptedMints: [String],
        requestTTLSeconds: UInt32,
        x402ChainID: UInt64? = nil,
        x402TokenAddress: String? = nil,
        x402PayTo: String? = nil,
        x402GatewayURL: String? = nil,
        x402FacilitatorID: String? = nil,
        x402Scheme: AgentX402Scheme? = nil
    ) {
        self.paymentRail = paymentRail
        self.settlementMode = settlementMode
        self.requiresLocking = requiresLocking
        self.unit = unit
        self.priceModel = priceModel
        self.pricePerRequest = pricePerRequest
        self.pricePerInputToken = pricePerInputToken
        self.pricePerOutputToken = pricePerOutputToken
        self.minDeposit = minDeposit
        self.granularityTokens = granularityTokens
        self.acceptedMints = acceptedMints
        self.requestTTLSeconds = requestTTLSeconds
        self.x402ChainID = x402ChainID
        self.x402TokenAddress = x402TokenAddress
        self.x402PayTo = x402PayTo
        self.x402GatewayURL = x402GatewayURL
        self.x402FacilitatorID = x402FacilitatorID
        self.x402Scheme = x402Scheme
    }

    static let disabled = AgentPaymentTerms(
        paymentRail: .none,
        settlementMode: .onlineRequired,
        requiresLocking: AgentPaymentLockingMode.none,
        unit: "",
        priceModel: .perRequest,
        pricePerRequest: 0,
        pricePerInputToken: nil,
        pricePerOutputToken: nil,
        minDeposit: nil,
        granularityTokens: nil,
        acceptedMints: [],
        requestTTLSeconds: 0,
        x402ChainID: nil,
        x402TokenAddress: nil,
        x402PayTo: nil,
        x402GatewayURL: nil,
        x402FacilitatorID: nil,
        x402Scheme: nil
    )

    var effectivePriceModel: AgentPaymentPriceModel {
        if let priceModel {
            return priceModel
        }
        if (pricePerInputToken ?? 0) > 0 || (pricePerOutputToken ?? 0) > 0 {
            return .perToken
        }
        return .perRequest
    }

    var usesPerTokenPricing: Bool {
        effectivePriceModel == .perToken
    }

    var effectiveGranularityTokens: UInt32 {
        let fallback: UInt32 = 64
        let value = granularityTokens ?? fallback
        return max(1, min(4096, value))
    }

    var effectiveMinimumDeposit: UInt64 {
        minDeposit ?? 0
    }

    var isEnabled: Bool {
        guard paymentRail != .none else { return false }
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch paymentRail {
        case .none:
            return false
        case .cashu:
            switch effectivePriceModel {
            case .perRequest:
                return pricePerRequest > 0
            case .perToken:
                return (pricePerInputToken ?? 0) > 0 || (pricePerOutputToken ?? 0) > 0
            }
        case .x402:
            let token = (x402TokenAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let payTo = (x402PayTo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let gateway = (x402GatewayURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return pricePerRequest > 0
                && (x402ChainID ?? 0) > 0
                && !token.isEmpty
                && !payTo.isEmpty
                && !gateway.isEmpty
        }
    }

    func sanitized() -> AgentPaymentTerms? {
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mints = acceptedMints
            .map { raw in
                var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                while out.hasSuffix("/") { out.removeLast() }
                return out
            }
            .filter { !$0.isEmpty }
        let dedupedMints = Array(NSOrderedSet(array: mints)) as? [String] ?? mints
        let ttl = requestTTLSeconds == 0 ? UInt32(120) : requestTTLSeconds
        let cleanInputPrice = (pricePerInputToken ?? 0) > 0 ? pricePerInputToken : nil
        let cleanOutputPrice = (pricePerOutputToken ?? 0) > 0 ? pricePerOutputToken : nil
        let hasTokenPricing = (cleanInputPrice ?? 0) > 0 || (cleanOutputPrice ?? 0) > 0
        let resolvedPriceModel: AgentPaymentPriceModel = hasTokenPricing ? .perToken : .perRequest
        let cleanMinDeposit = (minDeposit ?? 0) > 0 ? minDeposit : nil
        let cleanGranularity: UInt32? = hasTokenPricing ? max(1, min(4096, granularityTokens ?? 64)) : nil

        let cleaned: AgentPaymentTerms
        switch paymentRail {
        case .none:
            return nil
        case .cashu:
            let defaultLocking: AgentPaymentLockingMode = settlementMode == .offlineAccepted ? .p2pk : .none
            let locking = requiresLocking ?? defaultLocking
            cleaned = AgentPaymentTerms(
                paymentRail: paymentRail,
                settlementMode: settlementMode,
                requiresLocking: locking,
                unit: trimmedUnit,
                priceModel: resolvedPriceModel,
                pricePerRequest: pricePerRequest,
                pricePerInputToken: cleanInputPrice,
                pricePerOutputToken: cleanOutputPrice,
                minDeposit: cleanMinDeposit,
                granularityTokens: cleanGranularity,
                acceptedMints: dedupedMints,
                requestTTLSeconds: ttl,
                x402ChainID: nil,
                x402TokenAddress: nil,
                x402PayTo: nil,
                x402GatewayURL: nil,
                x402FacilitatorID: nil,
                x402Scheme: nil
            )
        case .x402:
            let chainID = x402ChainID ?? 0
            let token = x402TokenAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let payTo = x402PayTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let gatewayURL = x402GatewayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let facilitator = x402FacilitatorID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "thirdweb"
            let scheme = x402Scheme ?? .exact
            guard chainID > 0, !token.isEmpty, !payTo.isEmpty else { return nil }
            guard !gatewayURL.isEmpty, AgentPaymentTerms.isSupportedGatewayURL(gatewayURL) else { return nil }
            cleaned = AgentPaymentTerms(
                paymentRail: .x402,
                settlementMode: .onlineRequired,
                requiresLocking: AgentPaymentLockingMode.none,
                unit: trimmedUnit,
                priceModel: .perRequest,
                pricePerRequest: pricePerRequest,
                pricePerInputToken: nil,
                pricePerOutputToken: nil,
                minDeposit: nil,
                granularityTokens: nil,
                acceptedMints: [],
                requestTTLSeconds: ttl,
                x402ChainID: chainID,
                x402TokenAddress: token,
                x402PayTo: payTo,
                x402GatewayURL: gatewayURL,
                x402FacilitatorID: facilitator.isEmpty ? "thirdweb" : facilitator,
                x402Scheme: scheme
            )
        }
        return cleaned.isEnabled ? cleaned : nil
    }

    private static func isSupportedGatewayURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}

struct AgentInfo: Codable, Equatable, Hashable {
    let role: String
    let modelId: String
    let qualityScore: UInt8
    let modelHash: String?
    let paymentTerms: AgentPaymentTerms?

    init(role: String, modelId: String, qualityScore: UInt8, modelHash: String?, paymentTerms: AgentPaymentTerms? = nil) {
        self.role = role
        self.modelId = modelId
        self.qualityScore = min(100, qualityScore)
        self.modelHash = modelHash
        self.paymentTerms = paymentTerms?.sanitized()
    }

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
    var paymentTerms: AgentPaymentTerms?
    var quoteTierPolicy: AgentQuoteTierPolicy
    var notaryPolicy: AgentNotaryPolicy

    var info: AgentInfo? {
        guard enabled else { return nil }
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRole.isEmpty, !trimmedModel.isEmpty else { return nil }
        return AgentInfo(
            role: trimmedRole,
            modelId: trimmedModel,
            qualityScore: min(100, qualityScore),
            modelHash: modelHash?.trimmingCharacters(in: .whitespacesAndNewlines),
            paymentTerms: paymentTerms?.sanitized()
        )
    }

    static let `default` = AgentConfig(
        enabled: false,
        role: "general",
        modelId: "local",
        qualityScore: 50,
        modelHash: nil,
        runtime: .default,
        paymentTerms: nil,
        quoteTierPolicy: .default,
        notaryPolicy: .default
    )

    private enum CodingKeys: String, CodingKey {
        case enabled
        case role
        case modelId
        case qualityScore
        case modelHash
        case runtime
        case paymentTerms
        case quoteTierPolicy
        case notaryPolicy
    }

    init(
        enabled: Bool,
        role: String,
        modelId: String,
        qualityScore: UInt8,
        modelHash: String?,
        runtime: AgentRuntimeConfig,
        paymentTerms: AgentPaymentTerms? = nil,
        quoteTierPolicy: AgentQuoteTierPolicy = .default,
        notaryPolicy: AgentNotaryPolicy = .default
    ) {
        self.enabled = enabled
        self.role = role
        self.modelId = modelId
        self.qualityScore = qualityScore
        self.modelHash = modelHash
        self.runtime = runtime
        self.paymentTerms = paymentTerms
        self.quoteTierPolicy = quoteTierPolicy.sanitized()
        self.notaryPolicy = notaryPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "general"
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? "local"
        qualityScore = try container.decodeIfPresent(UInt8.self, forKey: .qualityScore) ?? 50
        modelHash = try container.decodeIfPresent(String.self, forKey: .modelHash)
        runtime = try container.decodeIfPresent(AgentRuntimeConfig.self, forKey: .runtime) ?? .default
        paymentTerms = try container.decodeIfPresent(AgentPaymentTerms.self, forKey: .paymentTerms)
        quoteTierPolicy = (try container.decodeIfPresent(AgentQuoteTierPolicy.self, forKey: .quoteTierPolicy) ?? .default).sanitized()
        notaryPolicy = try container.decodeIfPresent(AgentNotaryPolicy.self, forKey: .notaryPolicy) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(role, forKey: .role)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(qualityScore, forKey: .qualityScore)
        try container.encodeIfPresent(modelHash, forKey: .modelHash)
        try container.encode(runtime, forKey: .runtime)
        try container.encodeIfPresent(paymentTerms?.sanitized(), forKey: .paymentTerms)
        try container.encode(quoteTierPolicy.sanitized(), forKey: .quoteTierPolicy)
        try container.encode(notaryPolicy, forKey: .notaryPolicy)
    }
}
