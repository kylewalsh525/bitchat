import XCTest
@testable import bitchat

@MainActor
final class AgentSessionStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        storeURL = tempDirectory.appendingPathComponent("sessions.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        storeURL = nil
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testPaymentStatePersistsAcrossReload() {
        let store = AgentSessionStore(storeURL: storeURL)
        let record = store.createSession(role: "writer", minQuality: 50, modelHash: nil)

        store.updatePaymentState(recordID: record.id, state: .paid)

        let reloaded = AgentSessionStore(storeURL: storeURL)
        let loaded = reloaded.session(for: record.id)
        XCTAssertEqual(loaded?.paymentState, .paid)
        XCTAssertNotNil(loaded?.paymentUpdatedAt)
    }

    func testClearPaymentStateRemovesStoredPaymentMetadata() {
        let store = AgentSessionStore(storeURL: storeURL)
        let record = store.createSession(role: "analyst", minQuality: 10, modelHash: nil)

        store.updatePaymentState(recordID: record.id, state: .acceptedOffline)
        store.clearPaymentState(recordID: record.id)

        let loaded = store.session(for: record.id)
        XCTAssertNil(loaded?.paymentState)
        XCTAssertNil(loaded?.paymentUpdatedAt)
    }

    func testLegacyRecordsWithoutPaymentFieldsStillLoad() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let createdAt = formatter.string(from: now.addingTimeInterval(-600))
        let lastUsedAt = formatter.string(from: now)
        let json = """
        [
          {
            "createdAt" : "\(createdAt)",
            "history" : [
              {
                "content" : "hello",
                "role" : "user"
              }
            ],
            "id" : "legacy-session",
            "lastUsedAt" : "\(lastUsedAt)",
            "minQuality" : 42,
            "modelHash" : null,
            "role" : "writer",
            "title" : "legacy"
          }
        ]
        """
        guard let data = json.data(using: .utf8) else {
            XCTFail("failed to encode fixture")
            return
        }
        try data.write(to: storeURL, options: [.atomic])

        let store = AgentSessionStore(storeURL: storeURL)
        let record = store.session(for: "legacy-session")

        XCTAssertNotNil(record)
        XCTAssertNil(record?.paymentState)
    }
}
