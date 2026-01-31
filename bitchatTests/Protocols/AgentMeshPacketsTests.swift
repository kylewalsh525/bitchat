//
// AgentMeshPacketsTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

final class AgentMeshPacketsTests: XCTestCase {

    func testAgentInfoEncodeDecodeRoundTrip() {
        let info = AgentInfo(role: "general", modelId: "local", qualityScore: 80, modelHash: "abc")
        let data = encodeAgentInfo(info)
        var expected = Data()
        expected.append(AgentMeshConstants.agentInfoVersion)
        expected.append(7)
        expected.append("general".data(using: .utf8)!)
        expected.append(5)
        expected.append("local".data(using: .utf8)!)
        expected.append(80)
        expected.append(3)
        expected.append("abc".data(using: .utf8)!)

        XCTAssertEqual(data, expected)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded, info)
    }

    func testAgentInfoTruncation() {
        let longRole = String(repeating: "r", count: 300)
        let longModel = String(repeating: "m", count: 300)
        let longHash = String(repeating: "h", count: 300)
        let info = AgentInfo(role: longRole, modelId: longModel, qualityScore: 255, modelHash: longHash)

        let data = encodeAgentInfo(info)
        XCTAssertEqual(data.first, AgentMeshConstants.agentInfoVersion)

        let decoded = decodeAgentInfo(data)
        XCTAssertEqual(decoded?.role.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.modelId.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.modelHash?.count, AgentMeshConstants.maxTLVStringBytes)
        XCTAssertEqual(decoded?.qualityScore, 100)
    }

    func testAgentRequestEncodeDecodeTruncation() {
        let longPrompt = String(repeating: "p", count: 300)
        let request = AgentRequestPacket(
            requestID: "req-1",
            role: "general",
            prompt: longPrompt,
            sessionID: "sess-1",
            attachmentCount: nil,
            senderAlias: "anon-1234",
            createdAtMs: 123456789,
            ttlMs: 30000
        )
        guard let data = request.encode() else {
            XCTFail("Failed to encode agent request")
            return
        }

        let decoded = AgentRequestPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.role, "general")
        XCTAssertEqual(decoded?.prompt.count, AgentMeshConstants.maxAgentPromptBytes)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.senderAlias, "anon-1234")
        XCTAssertEqual(decoded?.createdAtMs, 123456789)
        XCTAssertEqual(decoded?.ttlMs, 30000)
    }

    func testAgentResponseEncodeDecodeTruncation() {
        let longContent = String(repeating: "c", count: 300)
        let response = AgentResponsePacket(
            requestID: "req-1",
            content: longContent,
            isError: true,
            sessionID: "sess-1",
            chunkIndex: 1,
            chunkTotal: 2
        )
        guard let data = response.encode() else {
            XCTFail("Failed to encode agent response")
            return
        }

        let decoded = AgentResponsePacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.content.count, AgentMeshConstants.maxAgentResponseBytes)
        XCTAssertEqual(decoded?.isError, true)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.chunkIndex, 1)
        XCTAssertEqual(decoded?.chunkTotal, 2)
    }

    func testAgentChunkerRoundTrip() {
        let text = String(repeating: "👍", count: 120)
        let chunks = AgentMeshChunker.chunk(text: text, maxBytes: 12)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 12 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testAgentResponseAssembler() {
        var assembler = AgentResponseAssembler()
        let first = assembler.append(
            requestID: "req-1",
            sessionID: "sess-1",
            chunkIndex: 1,
            chunkTotal: 2,
            content: "Hello ",
            isError: false
        )
        XCTAssertNil(first)

        let second = assembler.append(
            requestID: "req-1",
            sessionID: "sess-1",
            chunkIndex: 2,
            chunkTotal: 2,
            content: "world",
            isError: false
        )
        XCTAssertEqual(second?.content, "Hello world")
        XCTAssertEqual(second?.isError, false)
    }

    func testAgentResponseChunkEncodeDecode() {
        let longContent = String(repeating: "c", count: 300)
        let packet = AgentResponseChunkPacket(
            requestID: "req-1",
            index: 2,
            isFinal: true,
            content: longContent,
            isError: true,
            sessionID: "sess-1"
        )
        guard let data = packet.encode() else {
            XCTFail("Failed to encode agent response chunk")
            return
        }

        let decoded = AgentResponseChunkPacket.decode(from: data)
        XCTAssertEqual(decoded?.requestID, "req-1")
        XCTAssertEqual(decoded?.index, 2)
        XCTAssertEqual(decoded?.isFinal, true)
        XCTAssertEqual(decoded?.isError, true)
        XCTAssertEqual(decoded?.sessionID, "sess-1")
        XCTAssertEqual(decoded?.content.count, AgentMeshConstants.maxAgentResponseBytes)
    }
}
