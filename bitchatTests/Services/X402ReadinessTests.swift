import XCTest
@testable import bitchat

final class X402ReadinessTests: XCTestCase {
    func testDisabledWhenPreferenceOff() {
        let state = X402ReadinessEvaluator.evaluate(
            allowX402Payments: false,
            bridgeAvailable: true,
            walletAddress: "0xabc"
        )
        XCTAssertEqual(state, .disabled)
    }

    func testBridgeUnavailableState() {
        let state = X402ReadinessEvaluator.evaluate(
            allowX402Payments: true,
            bridgeAvailable: false,
            walletAddress: "0xabc"
        )
        XCTAssertEqual(state, .bridgeUnavailable)
    }

    func testMissingGuestWalletWhenNoAddressState() {
        let state = X402ReadinessEvaluator.evaluate(
            allowX402Payments: true,
            bridgeAvailable: true,
            walletAddress: "   "
        )
        XCTAssertEqual(state, .missingGuestWallet)
    }

    func testMissingGuestWalletState() {
        let state = X402ReadinessEvaluator.evaluate(
            allowX402Payments: true,
            bridgeAvailable: true,
            walletAddress: nil
        )
        XCTAssertEqual(state, .missingGuestWallet)
    }

    func testReadyState() {
        let state = X402ReadinessEvaluator.evaluate(
            allowX402Payments: true,
            bridgeAvailable: true,
            walletAddress: "0xabc"
        )

        guard case .ready(let address) = state else {
            XCTFail("expected ready state")
            return
        }
        XCTAssertEqual(address, "0xabc")
        XCTAssertTrue(state.isReady)
    }
}
