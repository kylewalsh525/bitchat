import XCTest
@testable import bitchat

final class X402ModelsTests: XCTestCase {
    func testRequestEnvelopeRoundTrip() {
        let envelope = X402PaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-1",
            requestID: "req-1",
            amount: 250,
            unit: "usdc",
            chainID: 8453,
            tokenAddress: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            payTo: "0xfeed00000000000000000000000000000000beef",
            gatewayURL: "https://gateway.example",
            expiresAtMs: 1_700_000_000_000,
            sessionID: "sess-1",
            scheme: .exact,
            facilitatorID: "thirdweb"
        )

        guard let encoded = envelope.encodeString(),
              let decoded = X402PaymentRequestEnvelope.decode(from: encoded) else {
            XCTFail("expected x402 request round-trip")
            return
        }

        XCTAssertEqual(decoded, envelope)
    }

    func testPayloadEnvelopeRoundTrip() {
        let envelope = X402PaymentPayloadEnvelope(
            paymentID: "pay-1",
            requestID: "req-1",
            paymentData: "proof-data",
            payerAddress: "0x123",
            clientNonce: "nonce-1",
            createdAtMs: 1_700_000_000_000
        )

        guard let encoded = envelope.encodeString(),
              let decoded = X402PaymentPayloadEnvelope.decode(from: encoded) else {
            XCTFail("expected x402 payload round-trip")
            return
        }

        XCTAssertEqual(decoded, envelope)
    }

    func testPayloadEnvelopeDecodesRawJSONFallback() {
        let raw = """
        {
          "paymentID": "pay-2",
          "requestID": "req-2",
          "paymentData": "blob",
          "payerAddress": "0xabc",
          "clientNonce": "nonce-2",
          "createdAtMs": 1700000000000
        }
        """
        let decoded = X402PaymentPayloadEnvelope.decode(from: raw)
        XCTAssertEqual(decoded?.paymentID, "pay-2")
        XCTAssertEqual(decoded?.requestID, "req-2")
        XCTAssertEqual(decoded?.paymentData, "blob")
    }

    func testPaymentRefHashIsDeterministic() {
        let first = x402PaymentRefHash(paymentID: "pay-1", paymentData: "abc")
        let second = x402PaymentRefHash(paymentID: "pay-1", paymentData: "abc")
        let different = x402PaymentRefHash(paymentID: "pay-1", paymentData: "xyz")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
    }
}
