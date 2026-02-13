import XCTest
@testable import bitchat

final class CashuModelsTests: XCTestCase {
    func testPaymentRequestEnvelopeRoundTripWithLockFields() {
        let envelope = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-1",
            requestID: "req-1",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 42,
            expiresAtMs: 1_730_000_000_000,
            settlementMode: .offlineAccepted,
            sessionID: "sess-1",
            requiresLocking: .p2pk,
            lockPubkey: "02abc",
            lockSigFlag: 1,
            pricingModel: .perRequest,
            trancheIndex: 1,
            trancheCount: 2,
            trancheTokenCount: 128,
            outputTokenPrice: 3,
            inputTokenPrice: 1,
            minimumDeposit: 2
        )

        guard let encoded = envelope.encodeString(),
              let decoded = CashuPaymentRequestEnvelope.decode(from: encoded) else {
            XCTFail("expected round trip encode/decode")
            return
        }

        XCTAssertEqual(decoded.paymentID, "pay-1")
        XCTAssertEqual(decoded.requestID, "req-1")
        XCTAssertEqual(decoded.sessionID, "sess-1")
        XCTAssertEqual(decoded.requiresLocking, .p2pk)
        XCTAssertEqual(decoded.lockPubkey, "02abc")
        XCTAssertEqual(decoded.lockSigFlag, 1)
    }

    func testPaymentPayloadEnvelopeRoundTripWithLockFields() {
        let envelope = CashuPaymentPayloadEnvelope(
            paymentID: "pay-1",
            requestID: "req-1",
            mintURL: "https://mint.example",
            unit: "sat",
            totalAmount: 50,
            proofs: [CashuProof(id: "id-1", amount: 50, secret: "secret-1", C: "c1", witness: nil)],
            token: "p2pk:02abc",
            requiresLocking: .p2pk,
            lockPubkey: "02abc",
            nullifiers: ["n1"],
            clientNonce: "nonce",
            createdAtMs: 1_730_000_000_100
        )

        guard let encoded = envelope.toJSONString(),
              let decoded = CashuPaymentPayloadEnvelope.decode(fromJSONString: encoded) else {
            XCTFail("expected round trip encode/decode")
            return
        }

        XCTAssertEqual(decoded.paymentID, "pay-1")
        XCTAssertEqual(decoded.token, "p2pk:02abc")
        XCTAssertEqual(decoded.requiresLocking, .p2pk)
        XCTAssertEqual(decoded.lockPubkey, "02abc")
    }

    func testInvalidLockingModeDecodesToNone() throws {
        let rawJSON = """
        {
          "paymentID": "pay-1",
          "requestID": "req-1",
          "mintURL": "https://mint.example",
          "unit": "sat",
          "totalAmount": 1,
          "proofs": [{"amount":1,"secret":"s"}],
          "token": "p2pk:abcd",
          "requiresLocking": "future_mode",
          "lockPubkey": "abcd",
          "nullifiers": ["n1"],
          "clientNonce": "nonce",
          "createdAtMs": 1
        }
        """
        let decoded = try JSONDecoder().decode(CashuPaymentPayloadEnvelope.self, from: Data(rawJSON.utf8))
        XCTAssertEqual(decoded.requiresLocking, .some(.none))
    }
}
