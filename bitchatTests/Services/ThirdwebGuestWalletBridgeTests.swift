import XCTest
@testable import bitchat

private enum MockThirdwebRuntimeError: LocalizedError {
    case missingResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingResponse(let method):
            return "missing mock response for \(method)"
        }
    }
}

@MainActor
private final class MockThirdwebBridgeRuntime: ThirdwebBridgeRuntimeCalling {
    struct Call: Equatable {
        let method: String
        let args: [String: String]
    }

    private(set) var calls: [Call] = []
    var responses: [String: String] = [:]

    func call(method: String, args: [String: String], timeoutSeconds: TimeInterval) async throws -> String {
        calls.append(Call(method: method, args: args))
        guard let response = responses[method] else {
            throw MockThirdwebRuntimeError.missingResponse(method)
        }
        return response
    }

    func prewarm(timeoutSeconds: TimeInterval) async throws {
        // no-op for tests
    }
}

@MainActor
final class ThirdwebGuestWalletBridgeTests: XCTestCase {
    @MainActor
    private func makeBridge(runtime: ThirdwebBridgeRuntimeCalling) -> (
        bridge: ThirdwebGuestWalletBridge,
        defaults: UserDefaults
    ) {
        let suiteName = "ThirdwebGuestWalletBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let bridge = ThirdwebGuestWalletBridge(defaults: defaults, runtime: runtime)
        bridge.setConfiguredClientID("test-client")
        return (bridge, defaults)
    }

    @MainActor
    private func collectReasons(from bridge: ThirdwebGuestWalletBridge, _ block: () async throws -> Void) async rethrows -> [String] {
        var reasons: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .thirdwebWalletDidUpdate,
            object: bridge,
            queue: nil
        ) { note in
            if let reason = note.userInfo?[WalletNotificationKeys.reason] as? String {
                reasons.append(reason)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await block()
        return reasons
    }

    func testSetConfiguredClientIDEmitsNotification() {
        let suiteName = "ThirdwebGuestWalletBridgeTests.configured.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = MockThirdwebBridgeRuntime()
        let bridge = ThirdwebGuestWalletBridge(defaults: defaults, runtime: runtime)

        var reasons: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .thirdwebWalletDidUpdate,
            object: bridge,
            queue: nil
        ) { note in
            if let reason = note.userInfo?[WalletNotificationKeys.reason] as? String {
                reasons.append(reason)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        bridge.setConfiguredClientID("client")
        XCTAssertEqual(reasons, ["client-id-updated"])
    }

    func testEnsureGuestWalletFailsWithoutClientID() async {
        let suiteName = "ThirdwebGuestWalletBridgeTests.missing-client.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = MockThirdwebBridgeRuntime()
        runtime.responses["ensureGuestWallet"] = "0xabc"
        let bridge = ThirdwebGuestWalletBridge(defaults: defaults, runtime: runtime)

        do {
            _ = try await bridge.ensureGuestWallet()
            XCTFail("expected missing client id")
        } catch {
            guard let bridgeError = error as? ThirdwebGuestWalletError else {
                XCTFail("expected thirdweb error")
                return
            }
            switch bridgeError {
            case .missingClientID:
                break
            default:
                XCTFail("expected missingClientID, got \(bridgeError)")
            }
        }
        XCTAssertTrue(runtime.calls.isEmpty)
    }

    func testEnsureGuestWalletEmitsSuccessNotification() async throws {
        let runtime = MockThirdwebBridgeRuntime()
        runtime.responses["ensureGuestWallet"] = "0xabc"
        let (bridge, _) = makeBridge(runtime: runtime)

        let reasons = try await collectReasons(from: bridge) {
            _ = try await bridge.ensureGuestWallet()
        }
        XCTAssertEqual(reasons, ["ensureGuestWallet-success"])
        XCTAssertEqual(bridge.walletAddress, "0xabc")
        XCTAssertEqual(runtime.calls.count, 1)
        XCTAssertEqual(runtime.calls.first?.method, "ensureGuestWallet")
        XCTAssertEqual(runtime.calls.first?.args["clientID"], "test-client")
    }

    func testPayX402EmitsSuccessNotification() async throws {
        let runtime = MockThirdwebBridgeRuntime()
        runtime.responses["payX402"] = "{\"paymentData\":\"payment-data\",\"payerAddress\":\"0xpayer\"}"
        let (bridge, _) = makeBridge(runtime: runtime)

        let reasons = try await collectReasons(from: bridge) {
            _ = try await bridge.payX402(
                gatewayURL: "https://gateway.test",
                paymentID: "pay-123",
                requestID: "req-123",
                amount: 100,
                chainID: 1,
                tokenAddress: "0xtoken",
                payTo: "0xpay"
            )
        }
        XCTAssertEqual(reasons, ["payX402-success"])
        XCTAssertEqual(bridge.walletAddress, "0xpayer")
        XCTAssertEqual(runtime.calls.last?.method, "payX402")
        XCTAssertEqual(runtime.calls.last?.args["paymentID"], "pay-123")
    }

    func testLinkWalletEmitsSuccessNotification() async throws {
        let runtime = MockThirdwebBridgeRuntime()
        runtime.responses["linkPasskey"] = "linked"
        let (bridge, _) = makeBridge(runtime: runtime)

        let reasons = try await collectReasons(from: bridge) {
            try await bridge.linkWallet()
        }
        XCTAssertEqual(reasons, ["linkWallet-success"])
        XCTAssertTrue(bridge.isLinked)
        XCTAssertEqual(runtime.calls.last?.method, "linkPasskey")
    }

    func testResetWalletEmitsSuccessNotification() async {
        let runtime = MockThirdwebBridgeRuntime()
        runtime.responses["resetWallet"] = "ok"
        let (bridge, _) = makeBridge(runtime: runtime)

        let reasons = await collectReasons(from: bridge) {
            await bridge.resetWallet()
        }
        XCTAssertEqual(reasons, ["resetWallet-success"])
        XCTAssertNil(bridge.walletAddress)
        XCTAssertEqual(runtime.calls.last?.method, "resetWallet")
        XCTAssertFalse(bridge.isLinked)
    }
}
