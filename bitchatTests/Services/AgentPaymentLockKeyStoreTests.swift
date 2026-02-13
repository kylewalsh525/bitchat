import XCTest
@testable import bitchat

final class AgentPaymentLockKeyStoreTests: XCTestCase {
    func testCreateAndLoadBindingAndSecret() throws {
        let store = AgentPaymentLockKeyStore(keychain: MockKeychain())
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let created = try store.createLockBinding(
            requestID: "req-1",
            paymentID: "pay-1",
            expiresAtMs: nowMs + 60_000
        )
        XCTAssertFalse(created.pubkeyHex.isEmpty)
        XCTAssertFalse(created.keyRef.isEmpty)

        let binding = store.loadBinding(requestID: "req-1", paymentID: "pay-1")
        XCTAssertEqual(binding?.pubkeyHex, created.pubkeyHex)
        XCTAssertEqual(binding?.keyRef, created.keyRef)

        let secret = store.loadSecret(requestID: "req-1", paymentID: "pay-1")
        XCTAssertNotNil(secret)
        XCTAssertFalse(secret?.isEmpty ?? true)
    }

    func testCreateReturnsSameBindingForSameRequestPayment() throws {
        let store = AgentPaymentLockKeyStore(keychain: MockKeychain())
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let first = try store.createLockBinding(
            requestID: "req-1",
            paymentID: "pay-1",
            expiresAtMs: nowMs + 60_000
        )
        let second = try store.createLockBinding(
            requestID: "req-1",
            paymentID: "pay-1",
            expiresAtMs: nowMs + 60_000
        )

        XCTAssertEqual(first.pubkeyHex, second.pubkeyHex)
        XCTAssertEqual(first.keyRef, second.keyRef)
    }

    func testDeleteRemovesBindingAndSecret() throws {
        let store = AgentPaymentLockKeyStore(keychain: MockKeychain())
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try store.createLockBinding(
            requestID: "req-1",
            paymentID: "pay-1",
            expiresAtMs: nowMs + 60_000
        )

        store.delete(requestID: "req-1", paymentID: "pay-1")
        XCTAssertNil(store.loadBinding(requestID: "req-1", paymentID: "pay-1"))
        XCTAssertNil(store.loadSecret(requestID: "req-1", paymentID: "pay-1"))
    }

    func testExpiredBindingIsPrunedAndUnavailable() throws {
        let store = AgentPaymentLockKeyStore(keychain: MockKeychain())
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try store.createLockBinding(
            requestID: "req-1",
            paymentID: "pay-1",
            expiresAtMs: nowMs - 1
        )

        store.pruneExpired(nowMs: nowMs, maxDeletes: 10)
        XCTAssertNil(store.loadBinding(requestID: "req-1", paymentID: "pay-1"))
        XCTAssertNil(store.loadSecret(requestID: "req-1", paymentID: "pay-1"))
    }
}
