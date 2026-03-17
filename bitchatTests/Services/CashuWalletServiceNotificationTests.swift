import XCTest
@testable import bitchat

final class CashuWalletServiceNotificationTests: XCTestCase {
    private func makeWallet() -> (
        wallet: CashuWalletService,
        allowlist: CashuMintAllowlistStore,
        defaults: UserDefaults,
        keychain: MockKeychain
    ) {
        let suffix = UUID().uuidString
        let suiteName = "CashuWalletServiceNotificationTests.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let allowlist = CashuMintAllowlistStore(defaults: defaults)
        let keychain = MockKeychain()
        allowlist.allow(mintURL: "https://mint.example")
        let wallet = CashuWalletService(keychain: keychain, allowlist: allowlist)
        return (wallet, allowlist, defaults, keychain)
    }

    private func makeCashuToken(mintURL: String = "https://mint.example", secret: String, amount: UInt64) -> String {
        CashuTokenParser.exportTokenString(
            mintURL: mintURL,
            unit: "sat",
            proofs: [CashuProof(amount: amount, secret: secret)]
        ) ?? ""
    }

    private func collectReasons(from wallet: CashuWalletService, _ block: () -> Void) -> [String] {
        var reasons: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .cashuWalletDidUpdate,
            object: wallet,
            queue: nil
        ) { note in
            if let reason = note.userInfo?[WalletNotificationKeys.reason] as? String {
                reasons.append(reason)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        block()
        return reasons
    }

    func testImportTokenEmitsNotificationAndSkipsDuplicateImport() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-import", amount: 10)

        var reasons = collectReasons(from: wallet) {
            let imported = try? wallet.importToken(token)
            XCTAssertEqual(imported, 10)
        }
        XCTAssertEqual(reasons, ["import"])

        reasons = collectReasons(from: wallet) {
            let imported = try? wallet.importToken(token)
            XCTAssertEqual(imported, 0)
        }
        XCTAssertTrue(reasons.isEmpty)
    }

    func testImportTokenAcceptsPrefixedPasteText() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-prefixed", amount: 11)
        let pastedText = "1: \(token)"

        let imported = try? wallet.importToken(pastedText)
        XCTAssertEqual(imported, 11)
        XCTAssertEqual(wallet.balance(), 11)
    }

    func testPreparePaymentPayloadEmitsReserveNotification() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-reserve", amount: 12)
        try? wallet.importToken(token)

        let request = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-reserve",
            requestID: "req-reserve",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 10,
            expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000,
            settlementMode: .onlineRequired,
            sessionID: nil,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )

        var reasons = collectReasons(from: wallet) {
            _ = try? wallet.preparePaymentPayload(request: request, clientNonce: "nonce")
        }
        XCTAssertEqual(reasons, ["reserve"])
    }

    func testCommitReservedEmitsNotification() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-reserve", amount: 12)
        try? wallet.importToken(token)

        let request = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-reserve",
            requestID: "req-reserve",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 10,
            expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000,
            settlementMode: .onlineRequired,
            sessionID: nil,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )
        _ = try? wallet.preparePaymentPayload(request: request, clientNonce: "nonce")

        let reasons = collectReasons(from: wallet) {
            wallet.commitReserved(paymentID: request.paymentID)
        }
        XCTAssertEqual(reasons, ["commit"])
    }

    func testCommitReservedNoopEmitsNothingWhenMissing() {
        let (wallet, _, _, _) = makeWallet()
        let reasons = collectReasons(from: wallet) {
            wallet.commitReserved(paymentID: "missing")
        }
        XCTAssertTrue(reasons.isEmpty)
    }

    func testRollbackReservedEmitsNotification() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-reserve", amount: 12)
        try? wallet.importToken(token)

        let request = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-reserve",
            requestID: "req-reserve",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 10,
            expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000,
            settlementMode: .onlineRequired,
            sessionID: nil,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )
        _ = try? wallet.preparePaymentPayload(request: request, clientNonce: "nonce")
        let reasons = collectReasons(from: wallet) {
            wallet.rollbackReserved(paymentID: request.paymentID)
        }
        XCTAssertEqual(reasons, ["rollback"])
    }

    func testRollbackReservedNoopEmitsNothingWhenMissing() {
        let (wallet, _, _, _) = makeWallet()
        let reasons = collectReasons(from: wallet) {
            wallet.rollbackReserved(paymentID: "missing")
        }
        XCTAssertTrue(reasons.isEmpty)
    }

    func testExportMutationEmitsAndNoopEmitsNothing() {
        let (wallet, _, _, _) = makeWallet()
        let token = makeCashuToken(secret: "proof-export", amount: 20)
        _ = try? wallet.importToken(token)

        var reasons = collectReasons(from: wallet) {
            _ = try? wallet.exportToken(
                mintURL: "https://mint.example/",
                unit: "sat",
                amount: 10
            )
        }
        XCTAssertEqual(reasons, ["export"])

        reasons = collectReasons(from: wallet) {
            _ = try? wallet.exportToken(
                mintURL: "https://mint.example/",
                unit: "sat",
                amount: 100
            )
        }
        XCTAssertTrue(reasons.isEmpty)
    }

    func testReplaceReservedSkipsNoopAndEmitsWhenChanged() {
        let (wallet, _, _, _) = makeWallet()
        let importToken = makeCashuToken(secret: "proof-replace", amount: 40)
        _ = try? wallet.importToken(importToken)

        let request = CashuPaymentRequestEnvelope(
            version: 1,
            paymentID: "pay-replace",
            requestID: "req-replace",
            mintURL: "https://mint.example",
            unit: "sat",
            amount: 10,
            expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000,
            settlementMode: .onlineRequired,
            sessionID: nil,
            pricingModel: nil,
            trancheIndex: nil,
            trancheCount: nil,
            trancheTokenCount: nil,
            outputTokenPrice: nil,
            inputTokenPrice: nil,
            minimumDeposit: nil
        )
        let payload = try? wallet.preparePaymentPayload(request: request, clientNonce: "nonce")
        XCTAssertNotNil(payload)

        let unchanged = payload!.proofs
        let changed = Array(unchanged.dropFirst())

        var reasons = collectReasons(from: wallet) {
            wallet.replaceReserved(paymentID: request.paymentID, mintURL: request.mintURL, unit: request.unit, proofs: unchanged)
        }
        XCTAssertTrue(reasons.isEmpty)

        reasons = collectReasons(from: wallet) {
            wallet.replaceReserved(paymentID: request.paymentID, mintURL: request.mintURL, unit: request.unit, proofs: changed)
        }
        XCTAssertEqual(reasons, ["replace-reserved"])
    }

    func testWipeAllWalletOnlyPostsWhenStateExists() {
        let (wallet, _, _, _) = makeWallet()

        var reasons = collectReasons(from: wallet) {
            wallet.wipeAllWallet()
        }
        XCTAssertTrue(reasons.isEmpty)

        _ = try? wallet.importToken(makeCashuToken(secret: "proof-wipe", amount: 5))
        reasons = collectReasons(from: wallet) {
            wallet.wipeAllWallet()
        }
        XCTAssertEqual(reasons, ["wipe"])
    }
}
