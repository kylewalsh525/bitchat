//
// AgentResponseAssemblerTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

final class AgentResponseAssemblerTests: XCTestCase {
    func testAssemblesChunksInOrder() {
        var assembler = AgentResponseAssembler()
        let req = "req-1"
        let session = "sess-1"

        _ = assembler.append(
            requestID: req,
            sessionID: session,
            chunkIndex: 2,
            chunkTotal: 2,
            content: "World",
            isError: false
        )
        let result = assembler.append(
            requestID: req,
            sessionID: session,
            chunkIndex: 1,
            chunkTotal: 2,
            content: "Hello ",
            isError: false
        )

        XCTAssertEqual(result?.content, "Hello World")
        XCTAssertEqual(result?.isError, false)
    }

    func testFlushIfExpiredReturnsPartial() {
        var assembler = AgentResponseAssembler()
        let req = "req-2"
        let session = "sess-2"

        _ = assembler.append(
            requestID: req,
            sessionID: session,
            chunkIndex: 1,
            chunkTotal: 3,
            content: "Hello ",
            isError: false
        )
        _ = assembler.append(
            requestID: req,
            sessionID: session,
            chunkIndex: 2,
            chunkTotal: 3,
            content: "World",
            isError: false
        )

        let now = Date().addingTimeInterval(10)
        let flushed = assembler.flushIfExpired(
            requestID: req,
            sessionID: session,
            timeout: 1,
            now: now
        )

        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.content, "Hello World")
        XCTAssertEqual(flushed?.received, 2)
        XCTAssertEqual(flushed?.total, 3)
        XCTAssertEqual(flushed?.isError, false)
    }

    func testFlushIfExpiredNoopBeforeTimeout() {
        var assembler = AgentResponseAssembler()
        let req = "req-3"

        _ = assembler.append(
            requestID: req,
            sessionID: nil,
            chunkIndex: 1,
            chunkTotal: 2,
            content: "A",
            isError: false
        )

        let flushed = assembler.flushIfExpired(
            requestID: req,
            sessionID: nil,
            timeout: 120,
            now: Date()
        )

        XCTAssertNil(flushed)
    }

    func testFallsBackToSessionlessBuffer() {
        var assembler = AgentResponseAssembler()
        let req = "req-4"

        _ = assembler.append(
            requestID: req,
            sessionID: nil,
            chunkIndex: 1,
            chunkTotal: 2,
            content: "Hi ",
            isError: false
        )
        let result = assembler.append(
            requestID: req,
            sessionID: "sess-x",
            chunkIndex: 2,
            chunkTotal: 2,
            content: "there",
            isError: false
        )

        XCTAssertEqual(result?.content, "Hi there")
    }
}
