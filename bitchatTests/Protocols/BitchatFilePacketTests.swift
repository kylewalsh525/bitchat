//
// BitchatFilePacketTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

final class BitchatFilePacketTests: XCTestCase {
    func testFilePacketContextIDRoundTrip() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = BitchatFilePacket(
            fileName: "file.bin",
            fileSize: UInt64(payload.count),
            mimeType: "application/octet-stream",
            contextID: "session-123",
            content: payload
        )
        guard let encoded = packet.encode() else {
            XCTFail("Failed to encode file packet")
            return
        }

        let decoded = BitchatFilePacket.decode(encoded)
        XCTAssertEqual(decoded?.fileName, "file.bin")
        XCTAssertEqual(decoded?.mimeType, "application/octet-stream")
        XCTAssertEqual(decoded?.contextID, "session-123")
        XCTAssertEqual(decoded?.content, payload)
    }
}
