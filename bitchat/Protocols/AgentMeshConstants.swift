//
// AgentMeshConstants.swift
// bitchat
//
// Centralized constants for agent mesh protocol versioning and limits.
//

import Foundation

enum AgentMeshConstants {
    static let agentInfoVersionV1: UInt8 = 0x01
    static let agentInfoVersionV2: UInt8 = 0x02
    static let agentInfoVersion: UInt8 = agentInfoVersionV2
    static let maxTLVStringBytes: Int = 255
    static let maxAgentPromptBytes: Int = 255
    static let maxAgentResponseBytes: Int = 255
    static let maxPaymentPacketBytes: Int = Int(UInt16.max)
    static let agentResponseAssemblyTimeoutSeconds: TimeInterval = 6
    static let agentResponseStreamRenderIntervalSeconds: TimeInterval = 0.2
}

enum AgentMeshTLV: UInt8 {
    case agentInfo = 0x05
}

enum AgentRequestTLV: UInt8 {
    case requestID = 0x00
    case role = 0x01
    case prompt = 0x02
    case sessionID = 0x03
    case attachmentCount = 0x04
    case senderAlias = 0x05
    case createdAtMs = 0x06
    case ttlMs = 0x07
    case quoteID = 0x08
    case quoteOptionID = 0x09
}

enum AgentResponseTLV: UInt8 {
    case requestID = 0x00
    case content = 0x01
    case isError = 0x02
    case sessionID = 0x03
    case chunkIndex = 0x04
    case chunkTotal = 0x05
    case paymentRequired = 0x06
    case paymentRequest = 0x07
    case paymentError = 0x08
}

enum AgentResponseChunkTLV: UInt8 {
    case requestID = 0x00
    case content = 0x01
    case isError = 0x02
    case sessionID = 0x03
    case index = 0x04
    case isFinal = 0x05
}

enum AgentQuoteRequestTLV: UInt8 {
    case quoteID = 0x00
    case role = 0x01
    case prompt = 0x02
    case estimatedInputTokens = 0x03
    case estimatedOutputTokens = 0x04
    case sentAt = 0x05
    case maxOptions = 0x06
}

enum AgentQuoteResponseTLV: UInt8 {
    case quoteID = 0x00
    case role = 0x01
    case optionsJSON = 0x02
    case expiresAt = 0x03
    case error = 0x04
}

enum AgentPaymentTermsTLV: UInt8 {
    case paymentRail = 0x00
    case settlementMode = 0x01
    case unit = 0x02
    case pricePerRequest = 0x03
    case acceptedMint = 0x04
    case requestTTLSeconds = 0x05
    case priceModel = 0x06
    case pricePerInputToken = 0x07
    case pricePerOutputToken = 0x08
    case minDeposit = 0x09
    case granularityTokens = 0x0A
    case requiresLocking = 0x0B
    case x402ChainID = 0x0C
    case x402TokenAddress = 0x0D
    case x402PayTo = 0x0E
    case x402GatewayURL = 0x0F
    case x402Scheme = 0x10
    case x402FacilitatorID = 0x11
}

enum AgentPaymentPayloadTLV: UInt8 {
    case requestID = 0x00
    case sessionID = 0x01
    case rail = 0x02
    case payload = 0x03
    case sentAt = 0x04
    case clientNonce = 0x05
}

enum AgentPaymentReceiptTLV: UInt8 {
    case requestID = 0x00
    case sessionID = 0x01
    case status = 0x02
    case details = 0x03
    case nullifier = 0x04
    case notaryReceipt = 0x05
    case paymentID = 0x06
    case fairUnlockKey = 0x07
}

enum MintProxyRequestTLV: UInt8 {
    case proxyID = 0x00
    case mintURL = 0x01
    case method = 0x02
    case body = 0x03
    case sentAt = 0x04
}

enum MintProxyResponseTLV: UInt8 {
    case proxyID = 0x00
    case ok = 0x01
    case body = 0x02
    case error = 0x03
}
