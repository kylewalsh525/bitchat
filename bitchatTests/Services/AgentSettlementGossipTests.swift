import XCTest
@testable import bitchat

@MainActor
final class AgentSettlementGossipTests: XCTestCase {
    func testIngestAnnounceFromMeshSuggestsGlobalForwarding() {
        let receiver = AgentSettlementGossip()
        let publisher = AgentSettlementGossip()
        let announce = publisher.registerAcceptedPayment(
            paymentID: "pay-1",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-1", "n-2"]
        )

        XCTAssertNotNil(announce)
        let result = receiver.ingest(content: announce ?? "", source: .mesh, senderID: "peer-a")

        XCTAssertEqual(result.status, .accepted)
        XCTAssertTrue(result.isSettlement)
        XCTAssertTrue(result.shouldForwardToGlobal)
        XCTAssertFalse(result.shouldForwardToMesh)
        XCTAssertNil(result.conflictNullifier)
    }

    func testIngestAnnounceFromGlobalSuggestsMeshForwarding() {
        let receiver = AgentSettlementGossip()
        let publisher = AgentSettlementGossip()
        let announce = publisher.registerAcceptedPayment(
            paymentID: "pay-global",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-global"]
        )

        XCTAssertNotNil(announce)
        let result = receiver.ingest(content: announce ?? "", source: .global, senderID: "pubkey-a")

        XCTAssertEqual(result.status, .accepted)
        XCTAssertTrue(result.isSettlement)
        XCTAssertTrue(result.shouldForwardToMesh)
        XCTAssertFalse(result.shouldForwardToGlobal)
    }

    func testDuplicateAnnouncementIsIgnored() {
        let receiver = AgentSettlementGossip()
        let publisher = AgentSettlementGossip()
        let announce = publisher.registerAcceptedPayment(
            paymentID: "pay-dup",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-dup"]
        ) ?? ""

        let first = receiver.ingest(content: announce, source: .mesh, senderID: "peer-a")
        let second = receiver.ingest(content: announce, source: .mesh, senderID: "peer-a")

        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(second.status, .duplicate)
        XCTAssertTrue(second.isSettlement)
    }

    func testConflictFromPriorObservationIsDetected() {
        let receiver = AgentSettlementGossip()
        let publisher = AgentSettlementGossip()
        let announce = publisher.registerAcceptedPayment(
            paymentID: "pay-existing",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-conflict"]
        ) ?? ""
        _ = receiver.ingest(content: announce, source: .mesh, senderID: "peer-a")

        let conflict = receiver.firstConflictingNullifier(
            paymentID: "pay-new",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-conflict"]
        )

        XCTAssertEqual(conflict, "n-conflict")
    }

    func testConflictingAnnouncementsProduceConflictSignal() {
        let receiver = AgentSettlementGossip()
        let sourceA = AgentSettlementGossip()
        let sourceB = AgentSettlementGossip()

        let announceA = sourceA.registerAcceptedPayment(
            paymentID: "pay-a",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-shared"]
        ) ?? ""
        let announceB = sourceB.registerAcceptedPayment(
            paymentID: "pay-b",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-shared"]
        ) ?? ""

        let first = receiver.ingest(content: announceA, source: .mesh, senderID: "peer-a")
        let second = receiver.ingest(content: announceB, source: .mesh, senderID: "peer-b")

        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(second.status, .accepted)
        XCTAssertEqual(second.conflictNullifier, "n-shared")
    }

    func testConflictDetectionSurvivesLargeObservationChurn() {
        let receiver = AgentSettlementGossip()

        for index in 0..<9_000 {
            let publisher = AgentSettlementGossip()
            let announce = publisher.registerAcceptedPayment(
                paymentID: "pay-\(index)",
                mintURL: "https://mint.example",
                unit: "sat",
                nullifiers: ["n-\(index)"]
            ) ?? ""
            _ = receiver.ingest(content: announce, source: .mesh, senderID: "peer-\(index)")
        }

        let conflict = receiver.firstConflictingNullifier(
            paymentID: "new-pay",
            mintURL: "https://mint.example",
            unit: "sat",
            nullifiers: ["n-8999"]
        )
        XCTAssertEqual(conflict, "n-8999")
    }
}
