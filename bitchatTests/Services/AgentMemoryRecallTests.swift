import XCTest
@testable import bitchat

final class AgentMemoryRecallTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: AgentMemoryStore!
    private var recall: AgentMemoryRecall!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMemoryRecallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = AgentMemoryStore(rootURL: tempDirectory)
        recall = AgentMemoryRecall(store: store)

        try store.writeEntry(id: "curated", content: "Use deterministic request IDs for payments.")
        let day = try store.ensureDailyEntry(for: Date(timeIntervalSince1970: 1_735_344_000))
        try store.writeEntry(id: day, content: "Gateway retries should be idempotent and bounded.")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        store = nil
        recall = nil
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testManualSnippetsIncludeAttachedEntries() {
        let snippets = recall.manualSnippets(entryIDs: ["curated"], maxSnippetBytes: 200)

        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.source, .manual)
        XCTAssertTrue(snippets.first?.content.contains("deterministic") == true)
    }

    func testAutoRecallMatchesPromptKeywords() throws {
        let dayID = try store.ensureDailyEntry(for: Date(timeIntervalSince1970: 1_735_344_000))
        let snippets = recall.recall(
            prompt: "How should gateway retries stay idempotent?",
            excluding: [],
            limit: 2,
            maxSnippetBytes: 200
        )

        XCTAssertFalse(snippets.isEmpty)
        XCTAssertEqual(snippets.first?.source, .auto)
        XCTAssertTrue(snippets.contains(where: { $0.entryID == dayID }))
    }

    func testAutoRecallRespectsExclusions() {
        let snippets = recall.recall(
            prompt: "deterministic payments",
            excluding: ["curated"],
            limit: 2,
            maxSnippetBytes: 200
        )

        XCTAssertFalse(snippets.contains(where: { $0.entryID == "curated" }))
    }
}
