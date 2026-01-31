//
// AgentMeshChunker.swift
// bitchat
//
// Splits text into UTF-8 safe chunks for agent responses.
//

import Foundation

enum AgentMeshChunker {
    static func chunk(text: String, maxBytes: Int) -> [String] {
        guard maxBytes > 0 else { return [text] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0

        for character in text {
            let piece = String(character)
            let bytes = piece.utf8.count
            if currentBytes + bytes > maxBytes, !current.isEmpty {
                chunks.append(current)
                current = piece
                currentBytes = bytes
            } else {
                current += piece
                currentBytes += bytes
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [""] : chunks
    }
}
