import XCTest
@testable import bitchat

final class AgentFairExchangeServiceTests: XCTestCase {
    func testPrepareOfferAndDecryptRoundTrip() throws {
        let service = AgentFairExchangeService()
        let prepared = try service.prepareOffer(
            plaintext: "locked response",
            requestID: "req-1",
            paymentID: "pay-1",
            sessionID: "sess-1"
        )

        let decrypted = try service.decrypt(
            offer: prepared.offer,
            unlockToken: prepared.unlockToken,
            requestID: "req-1",
            paymentID: "pay-1",
            sessionID: "sess-1"
        )

        XCTAssertEqual(decrypted, "locked response")
        XCTAssertNotNil(service.decodeOfferIfPresent(prepared.offer))
    }

    func testChunkedOfferSegmentsRoundTrip() throws {
        let service = AgentFairExchangeService()
        let plaintext = String(repeating: "tokenized-content ", count: 220)
        let prepared = try service.prepareOffer(
            plaintext: plaintext,
            requestID: "req-2",
            paymentID: "pay-2",
            sessionID: "sess-2"
        )

        let chunks = service.chunkedOfferSegments(prepared.offer, maxPacketBytes: AgentMeshConstants.maxTLVStringBytes)
        XCTAssertGreaterThan(chunks.count, 1)
        let payloads = chunks.compactMap(service.extractOfferChunkPayload(from:))
        XCTAssertEqual(payloads.joined(), prepared.offer)
    }

    func testDecryptRejectsMismatchedPaymentID() throws {
        let service = AgentFairExchangeService()
        let prepared = try service.prepareOffer(
            plaintext: "locked response",
            requestID: "req-3",
            paymentID: "pay-3",
            sessionID: "sess-3"
        )

        XCTAssertThrowsError(
            try service.decrypt(
                offer: prepared.offer,
                unlockToken: prepared.unlockToken,
                requestID: "req-3",
                paymentID: "pay-other",
                sessionID: "sess-3"
            )
        ) { error in
            guard let fairError = error as? AgentFairExchangeError else {
                XCTFail("unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(fairError, .paymentMismatch)
        }
    }
}
