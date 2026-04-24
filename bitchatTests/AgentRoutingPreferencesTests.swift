import XCTest
@testable import BitFoundation
@testable import bitchat

@MainActor
private func makeRoutingTestViewModel(knownModelCatalog: AgentKnownModelCatalog) -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let overlayURL = tmpDir.appendingPathComponent("known_models.json")
    let defaults = UserDefaults(suiteName: "AgentRoutingPreferencesTests.\(UUID().uuidString)")!
    let updateService = AgentKnownModelUpdateService(overlayURL: overlayURL, defaults: defaults)

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport,
        knownModelCatalog: knownModelCatalog,
        knownModelUpdateService: updateService
    )
    return (viewModel, transport)
}

final class AgentRoutingPreferencesTests: XCTestCase {
    @MainActor
    func testPreferredKnownBeatsUnknownWhenOtherwiseEqual() {
        let hex = String(repeating: "d", count: 64)
        let known = AgentKnownModel(id: "known-1", name: "Known One", matchers: ["known"], hashes: ["sha256:\(hex)"])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overlayURL = tmp.appendingPathComponent("known_models.json")
        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [known])

        let (viewModel, transport) = makeRoutingTestViewModel(knownModelCatalog: catalog)
        viewModel.agentRequesterPreferences = AgentRequesterPreferences(
            minQualityScore: 0,
            preferKnownModels: true,
            preferredKnownModelIDs: [],
            penalizeUnknownModels: true
        )

        let peerUnknown = BitchatPeer(
            peerID: PeerID(str: "peer-unknown"),
            noisePublicKey: Data(repeating: 0x01, count: 32),
            nickname: "unknown",
            lastSeen: Date(),
            isConnected: true,
            isReachable: true,
            agentInfo: AgentInfo(role: "general", modelId: "mystery", qualityScore: 50, modelHash: nil)
        )
        let peerKnown = BitchatPeer(
            peerID: PeerID(str: "peer-known"),
            noisePublicKey: Data(repeating: 0x02, count: 32),
            nickname: "known",
            lastSeen: Date(),
            isConnected: true,
            isReachable: true,
            agentInfo: AgentInfo(role: "general", modelId: "known-model", qualityScore: 50, modelHash: "ollama:sha256:\(hex)")
        )
        viewModel.allPeers = [peerUnknown, peerKnown]

        let result = viewModel.dispatchAgentRequest(role: "general", prompt: "hi")
        if case .error(let message) = result {
            XCTFail("unexpected error: \(message)")
        }
        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.peerID, peerKnown.peerID)
    }

    @MainActor
    func testMinQualityFloorIsEnforced() {
        let known = AgentKnownModel(id: "known-1", name: "Known One", matchers: ["known"], hashes: [])
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overlayURL = tmp.appendingPathComponent("known_models.json")
        let catalog = AgentKnownModelCatalog(overlayURL: overlayURL, builtIn: [known])

        let (viewModel, transport) = makeRoutingTestViewModel(knownModelCatalog: catalog)
        viewModel.agentRequesterPreferences = AgentRequesterPreferences(
            minQualityScore: 90,
            preferKnownModels: true,
            preferredKnownModelIDs: [],
            penalizeUnknownModels: true
        )

        let peerLow = BitchatPeer(
            peerID: PeerID(str: "peer-low"),
            noisePublicKey: Data(repeating: 0x03, count: 32),
            nickname: "low",
            lastSeen: Date(),
            isConnected: true,
            isReachable: true,
            agentInfo: AgentInfo(role: "general", modelId: "known-model", qualityScore: 80, modelHash: nil)
        )
        let peerHigh = BitchatPeer(
            peerID: PeerID(str: "peer-high"),
            noisePublicKey: Data(repeating: 0x04, count: 32),
            nickname: "high",
            lastSeen: Date(),
            isConnected: true,
            isReachable: true,
            agentInfo: AgentInfo(role: "general", modelId: "mystery", qualityScore: 95, modelHash: nil)
        )
        viewModel.allPeers = [peerLow, peerHigh]

        _ = viewModel.dispatchAgentRequest(role: "general", prompt: "hi")
        XCTAssertEqual(transport.sentAgentRequests.count, 1)
        XCTAssertEqual(transport.sentAgentRequests.first?.peerID, peerHigh.peerID)
    }
}
