import XCTest
@testable import bitchat

@MainActor
final class AgentPaymentNotaryServiceTests: XCTestCase {
    func testRequestAndAttestationRoundTrip() {
        // Model the real flow with distinct instances:
        // requester -> notary -> provider (collector).
        let requester = AgentPaymentNotaryService()
        let notary = AgentPaymentNotaryService()
        let provider = AgentPaymentNotaryService()

        let requestContent = requester.makeNotaryRequestContent(
            requestID: "req-1",
            paymentID: "pay-1",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n1", "n2"],
            requesterPeerID: "peer-provider"
        )
        XCTAssertNotNil(requestContent)
        guard let requestContent else {
            XCTFail("missing request content")
            return
        }

        let ingestedRequest = notary.ingest(content: requestContent, source: .mesh, senderID: "peer-provider")
        XCTAssertEqual(ingestedRequest.status, .accepted)
        XCTAssertNotNil(ingestedRequest.request)

        guard let request = ingestedRequest.request else {
            XCTFail("missing parsed request")
            return
        }

        let attestation = notary.makeNotaryAttestationContent(
            request: request,
            room: AgentSettlementGossip.meshRoom,
            notaryPeerID: "peer-notary-a",
            signingPublicKeyHex: "abcd",
            sign: { _ in
                Data([0x01, 0x02, 0x03])
            }
        )
        XCTAssertNotNil(attestation)
        guard let attestation else {
            XCTFail("missing attestation content")
            return
        }

        let ingestedAttestation = provider.ingest(content: attestation, source: .mesh, senderID: "peer-notary-a")
        XCTAssertEqual(ingestedAttestation.status, .accepted)
        XCTAssertNotNil(ingestedAttestation.receipt)
        XCTAssertNotNil(ingestedAttestation.encodedReceipt)

        let selected = provider.selectReceipts(
            requestID: "req-1",
            paymentID: "pay-1",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n1", "n2"],
            minCount: 1,
            validate: { _, _ in true }
        )
        XCTAssertEqual(selected.count, 1)
    }

    func testWaitForReceiptsReturnsMinimumUniqueNotaries() async {
        let requester = AgentPaymentNotaryService()
        let notaryA = AgentPaymentNotaryService()
        let notaryB = AgentPaymentNotaryService()
        let provider = AgentPaymentNotaryService()

        let requestContent = requester.makeNotaryRequestContent(
            requestID: "req-2",
            paymentID: "pay-2",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n3"],
            requesterPeerID: "peer-provider"
        )
        XCTAssertNotNil(requestContent)
        guard let requestContent else {
            XCTFail("missing request")
            return
        }

        let ingestedA = notaryA.ingest(content: requestContent, source: .mesh, senderID: "peer-provider")
        guard let requestA = ingestedA.request else {
            XCTFail("missing parsed request")
            return
        }

        let ingestedB = notaryB.ingest(content: requestContent, source: .mesh, senderID: "peer-provider")
        guard let requestB = ingestedB.request else {
            XCTFail("missing parsed request (notary B)")
            return
        }

        let first = notaryA.makeNotaryAttestationContent(
            request: requestA,
            room: AgentSettlementGossip.meshRoom,
            notaryPeerID: "peer-notary-a",
            signingPublicKeyHex: "aa",
            sign: { _ in Data([0x01]) }
        )
        let second = notaryB.makeNotaryAttestationContent(
            request: requestB,
            room: AgentSettlementGossip.meshRoom,
            notaryPeerID: "peer-notary-b",
            signingPublicKeyHex: "bb",
            sign: { _ in Data([0x02]) }
        )
        if let first {
            _ = provider.ingest(content: first, source: .mesh, senderID: "peer-notary-a")
        } else {
            XCTFail("missing attestation (notary A)")
        }
        if let second {
            _ = provider.ingest(content: second, source: .mesh, senderID: "peer-notary-b")
        } else {
            XCTFail("missing attestation (notary B)")
        }

        let receipts = await provider.waitForReceipts(
            requestID: "req-2",
            paymentID: "pay-2",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n3"],
            minCount: 2,
            timeoutMs: 1_000,
            validate: { _, _ in true }
        )

        XCTAssertEqual(receipts.count, 2)
    }
}
