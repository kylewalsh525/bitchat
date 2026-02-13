//
// AgentPaymentStoreTests.swift
// bitchatTests
//

import XCTest
@testable import bitchat

final class AgentPaymentStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPaymentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        storeURL = tempDirectory.appendingPathComponent("payments.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    func testValidateIncomingPayloadDetectsDuplicateForSameRequest() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))

        let first = store.validateIncomingPayload(requestID: "req-1", paymentID: "pay-1", nullifiers: ["n1"])
        XCTAssertEqual(first, .accepted)

        let duplicate = store.validateIncomingPayload(requestID: "req-1", paymentID: "pay-1", nullifiers: ["n1"])
        XCTAssertEqual(duplicate, .duplicateForRequest)
    }

    func testValidateIncomingPayloadDetectsReplayAcrossRequests() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))
        store.recordPaymentRequest(makeRecord(requestID: "req-2", paymentID: "pay-2"))

        store.markReceipt(requestID: "req-1", status: .acceptedOffline, details: nil, nullifiers: ["n1"])

        let replay = store.validateIncomingPayload(requestID: "req-2", paymentID: "pay-2", nullifiers: ["n1"])
        XCTAssertEqual(replay, .replayAcrossRequests)
    }

    func testValidateIncomingPayloadDetectsPaymentMismatch() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))

        let mismatch = store.validateIncomingPayload(requestID: "req-1", paymentID: "pay-2", nullifiers: ["n2"])
        XCTAssertEqual(mismatch, .paymentMismatch)
    }

    func testPendingOfflineFinalizationsReturnsOnlyOfflineAccepted() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))
        store.recordPaymentRequest(makeRecord(requestID: "req-2", paymentID: "pay-2"))
        store.recordPaymentRequest(makeRecord(requestID: "req-3", paymentID: "pay-3"))

        store.markReceipt(requestID: "req-1", status: .acceptedOffline, details: "offline", nullifiers: ["n1"])
        store.markReceipt(requestID: "req-2", status: .finalizedOnline, details: "done", nullifiers: ["n2"])
        store.markReceipt(requestID: "req-3", status: .acceptedOffline, details: "offline", nullifiers: ["n3"])

        let pending = store.pendingOfflineFinalizations()
        XCTAssertEqual(pending.map(\.requestID).sorted(), ["req-1", "req-3"])
        XCTAssertEqual(store.offlineOutstandingCount(), 2)
        XCTAssertEqual(store.offlineOutstandingCount(for: "peer-A"), 2)
    }

    func testValidateIncomingPayloadPersistsNullifiersOnAccept() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))

        let first = store.validateIncomingPayload(requestID: "req-1", paymentID: "pay-1", nullifiers: ["n1", "n2"])
        XCTAssertEqual(first, .accepted)

        let record = store.record(for: "req-1")
        XCTAssertEqual(Set(record?.nullifiers ?? []), Set(["n1", "n2"]))
    }

    func testCacheIncomingPayloadPersistsPayloadWithoutChangingState() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))

        store.cacheIncomingPayload(
            requestID: "req-1",
            payload: "{\"proofs\":[1]}",
            nullifiers: ["n3"]
        )

        let record = store.record(for: "req-1")
        XCTAssertEqual(record?.payload, "{\"proofs\":[1]}")
        XCTAssertEqual(record?.state, .paymentRequested)
        XCTAssertEqual(record?.nullifiers, ["n3"])
    }

    func testMarkReceiptPersistsNotaryReceipts() {
        let store = AgentPaymentStore(storeURL: storeURL)
        store.recordPaymentRequest(makeRecord(requestID: "req-1", paymentID: "pay-1"))

        store.markReceipt(
            requestID: "req-1",
            status: .acceptedOffline,
            details: "offline",
            nullifiers: ["n1"],
            notaryReceipts: ["anr1:a", "anr1:a", "anr1:b"]
        )

        let record = store.record(for: "req-1")
        XCTAssertEqual(record?.state, .acceptedOffline)
        XCTAssertEqual(record?.notaryReceipts, ["anr1:a", "anr1:b"])
    }

    private func makeRecord(requestID: String, paymentID: String) -> AgentPaymentRecord {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        return AgentPaymentRecord(
            requestID: requestID,
            sessionID: "sess-1",
            peerID: "peer-A",
            paymentID: paymentID,
            rail: "cashu",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            settlementMode: .offlineAccepted,
            requiresLocking: .p2pk,
            lockPubkey: "02lockpub",
            lockSigFlag: 1,
            paymentRequest: "creq:test",
            payload: nil,
            nullifiers: [],
            notaryReceipts: [],
            state: .paymentRequested,
            details: nil,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
            expiresAtMs: nowMs + 60_000
        )
    }
}
