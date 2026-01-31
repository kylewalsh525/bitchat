//
// AgentSessionAttachment.swift
// bitchat
//
// Lightweight metadata for incoming agent attachments.
//

import Foundation

struct AgentSessionAttachment: Equatable {
    let url: URL
    let fileName: String
    let mimeType: String
    let receivedAt: Date
}
