//
// AgentResponseAssembler.swift
// bitchat
//
// Reassembles chunked agent responses.
//

import Foundation

struct AgentResponseAssembler {
    private struct Key: Hashable {
        let requestID: String
        let sessionID: String?
    }

    private struct Buffer {
        var total: Int
        var chunks: [Int: String]
        var isError: Bool
        var createdAt: Date
        var updatedAt: Date
    }

    private var buffers: [Key: Buffer] = [:]

    mutating func append(
        requestID: String,
        sessionID: String?,
        chunkIndex: Int,
        chunkTotal: Int,
        content: String,
        isError: Bool
    ) -> (content: String, isError: Bool)? {
        guard chunkIndex > 0, chunkTotal > 0 else {
            return (content, isError)
        }

        let key = Key(requestID: requestID, sessionID: sessionID)
        var existingBuffer = buffers[key]
        if existingBuffer == nil, sessionID != nil {
            let fallbackKey = Key(requestID: requestID, sessionID: nil)
            if let fallback = buffers.removeValue(forKey: fallbackKey) {
                existingBuffer = fallback
            }
        }
        var buffer = existingBuffer ?? Buffer(
            total: chunkTotal,
            chunks: [:],
            isError: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        buffer.total = max(buffer.total, chunkTotal)
        buffer.chunks[chunkIndex] = content
        buffer.isError = buffer.isError || isError
        buffer.updatedAt = Date()
        buffers[key] = buffer

        guard buffer.chunks.count >= buffer.total else { return nil }
        let full = (1...buffer.total).compactMap { buffer.chunks[$0] }.joined()
        buffers.removeValue(forKey: key)
        return (full, buffer.isError)
    }

    mutating func flushIfExpired(
        requestID: String,
        sessionID: String?,
        timeout: TimeInterval,
        now: Date = Date()
    ) -> (content: String, isError: Bool, received: Int, total: Int)? {
        let key = Key(requestID: requestID, sessionID: sessionID)
        guard let buffer = buffers[key] else { return nil }
        guard now.timeIntervalSince(buffer.updatedAt) >= timeout else { return nil }
        let received = buffer.chunks.count
        let content = (1...buffer.total).compactMap { buffer.chunks[$0] }.joined()
        buffers.removeValue(forKey: key)
        return (content, buffer.isError, received, buffer.total)
    }
}
