import XCTest
@testable import bitchat

final class SupportBundleExporterTests: XCTestCase {
    @MainActor
    func testExportBundleIsRedacted() async throws {
        await SupportEventLog.shared.clear()
        await SupportEventLog.shared.record(category: "test", message: "cashuA:SHOULD_NOT_APPEAR")
        await SupportEventLog.shared.record(category: "test", message: "payload SHOULD_NOT_APPEAR")

        let keychain = MockKeychain()
        let keychainHelper = MockKeychainHelper()
        let idBridge = NostrIdentityBridge(keychain: keychainHelper)
        let identityManager = MockIdentityManager(keychain)
        let transport = MockTransport()

        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: transport
        )

        var next = viewModel.agentConfig
        next.runtime.gatewayToken = "super-secret-token"
        viewModel.updateAgentConfig(next)

        let exporter = SupportBundleExporter()
        let url = try await exporter.exportBundle(viewModel: viewModel)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("\"payload\""), "support bundle must not include raw payment payloads")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cashuA"), "support bundle must not include bearer tokens")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cashuB"), "support bundle must not include bearer tokens")
        XCTAssertFalse(text.contains("super-secret-token"), "support bundle must not include gateway auth tokens")
    }
}

