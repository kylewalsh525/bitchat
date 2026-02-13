import XCTest
@testable import bitchat

final class CashuMintAllowlistStoreTests: XCTestCase {
    func testNormalizeTrimsAndRemovesTrailingSlash() {
        XCTAssertEqual(CashuMintAllowlistStore.normalizeMintURL(" https://mint.example/ "), "https://mint.example")
        XCTAssertEqual(CashuMintAllowlistStore.normalizeMintURL("https://mint.example////"), "https://mint.example")
        XCTAssertEqual(CashuMintAllowlistStore.normalizeMintURL(""), "")
    }

    func testAllowAndRevokePersists() {
        let defaults = UserDefaults(suiteName: "CashuMintAllowlistStoreTests.\(UUID().uuidString)")!
        let store = CashuMintAllowlistStore(defaults: defaults)
        XCTAssertFalse(store.isAllowed(mintURL: "https://mint.example"))

        store.allow(mintURL: "https://mint.example/")
        XCTAssertTrue(store.isAllowed(mintURL: "https://mint.example"))

        let reloaded = CashuMintAllowlistStore(defaults: defaults)
        XCTAssertTrue(reloaded.isAllowed(mintURL: "https://mint.example"))

        reloaded.revoke(mintURL: "https://mint.example")
        XCTAssertFalse(reloaded.isAllowed(mintURL: "https://mint.example"))
    }

    func testWalletFailsClosedWhenMintNotApproved() throws {
        let keychain = MockKeychain()
        let defaults = UserDefaults(suiteName: "CashuMintAllowlistStoreTests.wallet.\(UUID().uuidString)")!
        let allowlist = CashuMintAllowlistStore(defaults: defaults)
        let wallet = CashuWalletService(keychain: keychain, allowlist: allowlist)

        let request = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-1",
            requestID: "req-1",
            mintURL: "https://mint.example/",
            unit: "sat",
            amount: 1,
            expiresAtMs: 1,
            settlementMode: .onlineRequired,
            sessionID: nil,
            pricingModel: .perRequest,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )

        XCTAssertThrowsError(try wallet.preparePaymentPayload(request: request, clientNonce: "n")) { error in
            guard let walletError = error as? CashuWalletService.WalletError else {
                XCTFail("expected wallet error")
                return
            }
            switch walletError {
            case .mintsNotAllowed:
                break
            default:
                XCTFail("expected mintsNotAllowed, got \(walletError)")
            }
        }

        allowlist.allow(mintURL: "https://mint.example")
        XCTAssertThrowsError(try wallet.preparePaymentPayload(request: request, clientNonce: "n")) { error in
            guard let walletError = error as? CashuWalletService.WalletError else {
                XCTFail("expected wallet error")
                return
            }
            switch walletError {
            case .insufficientBalance:
                break
            default:
                XCTFail("expected insufficientBalance after mint approval, got \(walletError)")
            }
        }
    }
}

