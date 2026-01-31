//
// AgentMeshConstants.swift
// bitchat
//
// Centralized constants for agent mesh protocol versioning and limits.
//

import Foundation

enum AgentMeshConstants {
    static let agentInfoVersion: UInt8 = 0x01
    static let maxTLVStringBytes: Int = 255
    static let maxAgentPromptBytes: Int = 255
    static let maxAgentResponseBytes: Int = 255
    static let agentResponseAssemblyTimeoutSeconds: TimeInterval = 6
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
}

enum AgentResponseTLV: UInt8 {
    case requestID = 0x00
    case content = 0x01
    case isError = 0x02
    case sessionID = 0x03
    case chunkIndex = 0x04
    case chunkTotal = 0x05
}
