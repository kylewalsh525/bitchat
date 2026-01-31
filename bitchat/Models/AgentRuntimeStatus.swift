//
// AgentRuntimeStatus.swift
// bitchat
//

import Foundation

struct AgentRuntimeStatus: Equatable {
    var lastGatewaySuccessAt: Date?
    var lastGatewayErrorAt: Date?
    var lastGatewayError: String?

    mutating func recordSuccess(at date: Date = Date()) {
        lastGatewaySuccessAt = date
        lastGatewayErrorAt = nil
        lastGatewayError = nil
    }

    mutating func recordFailure(_ message: String, at date: Date = Date()) {
        lastGatewayErrorAt = date
        lastGatewayError = message
    }
}
