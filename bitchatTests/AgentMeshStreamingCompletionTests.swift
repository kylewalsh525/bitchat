import XCTest
@testable import BitFoundation
@testable import bitchat

@MainActor
private func makeStreamingTestViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
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
    return (viewModel, transport)
}

final class AgentMeshStreamingCompletionTests: XCTestCase {
    @MainActor
    func testFinalChunkClearsStreamingBufferAndPendingRequest() {
        let (viewModel, _) = makeStreamingTestViewModel()
        let peerID = PeerID(str: "peer-stream-final")
        let requestID = "req-stream-final"
        let sessionID = "sess-stream-final"
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        viewModel.pendingAgentRequests[requestID] = ChatViewModel.AgentRequestContext(
            role: "general",
            targetPeerID: peerID,
            targetNickname: "agent",
            sessionID: sessionID,
            threadID: peerID,
            prompt: "hi",
            attachmentCount: nil,
            senderAlias: "anon",
            quoteID: nil,
            quoteOptionID: nil,
            draftAttachments: [],
            createdAtMs: nowMs,
            ttlMs: 30_000,
            retriesLeft: 2,
            sentAt: Date()
        )

        let chunk = AgentResponseChunkPacket(
            requestID: requestID,
            index: 1,
            isFinal: true,
            content: "hello",
            isError: false,
            sessionID: sessionID
        )
        viewModel.handleAgentResponseChunk(chunk, from: peerID)

        let key = viewModel.agentStreamingContextKey(requestID: requestID, sessionID: sessionID)
        XCTAssertNil(viewModel.agentStreamingBuffers[key])
        XCTAssertNil(viewModel.pendingAgentRequests[requestID])

        let messages = viewModel.privateChats[peerID] ?? []
        XCTAssertTrue(messages.contains(where: { $0.content.contains("hello") }))
    }
}
