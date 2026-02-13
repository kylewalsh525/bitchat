import XCTest
@testable import bitchat

final class AgentMemoryStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testListEntriesIncludesCuratedAndDailyEntryCreation() throws {
        let store = AgentMemoryStore(rootURL: tempDirectory)
        let fixedDate = ISO8601DateFormatter().date(from: "2025-01-01T12:00:00Z") ?? Date()

        let initial = store.listEntries()
        XCTAssertTrue(initial.contains(where: { $0.id == "curated" }))

        let dailyID = try store.ensureDailyEntry(for: fixedDate)
        XCTAssertTrue(dailyID.hasPrefix("daily:"))

        let entries = store.listEntries()
        XCTAssertTrue(entries.contains(where: { $0.id == dailyID }))
    }

    func testWriteAndReadCuratedMemory() throws {
        let store = AgentMemoryStore(rootURL: tempDirectory)
        let content = "# Personal\n\n- prefers concise answers"

        try store.writeEntry(id: "curated", content: content)
        let loaded = try store.readEntry(id: "curated")

        XCTAssertEqual(loaded, content)
    }

    func testAppendDailyCreatesTimestampedSection() throws {
        let store = AgentMemoryStore(rootURL: tempDirectory)
        let fixedDate = ISO8601DateFormatter().date(from: "2025-01-01T12:00:00Z") ?? Date()

        let dailyID = try store.appendDaily(note: "Investigate payment retries", at: fixedDate)
        let loaded = try store.readEntry(id: dailyID)

        XCTAssertTrue(loaded.contains("# 2025-01-01"))
        XCTAssertTrue(loaded.contains("Investigate payment retries"))
    }

    func testWipeAllMemoryClearsFilesAndKeepsStoreUsable() throws {
        let store = AgentMemoryStore(rootURL: tempDirectory)
        try store.writeEntry(id: "curated", content: "saved")
        _ = try store.appendDaily(note: "daily note", at: Date(timeIntervalSince1970: 1_735_344_000))

        store.wipeAllMemory()

        let curated = try store.readEntry(id: "curated")
        XCTAssertEqual(curated, "")

        let entries = store.listEntries()
        XCTAssertEqual(entries.filter { !$0.isCurated }.count, 0)
    }
}
