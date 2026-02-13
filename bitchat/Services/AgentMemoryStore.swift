import Foundation
import BitLogger

struct AgentMemoryEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case curated
        case daily(date: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let url: URL
    let lastModified: Date

    var isCurated: Bool {
        if case .curated = kind {
            return true
        }
        return false
    }
}

enum AgentMemoryStoreError: Error, LocalizedError {
    case unknownEntry

    var errorDescription: String? {
        switch self {
        case .unknownEntry:
            return "unknown memory entry"
        }
    }
}

final class AgentMemoryStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL = AgentMemoryStore.defaultRootURL(), fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        ensureDirectories()
    }

    func listEntries() -> [AgentMemoryEntry] {
        ensureDirectories()

        var entries: [AgentMemoryEntry] = []
        entries.append(
            AgentMemoryEntry(
                id: Self.curatedEntryID,
                kind: .curated,
                title: "MEMORY.md",
                url: curatedURL,
                lastModified: modificationDate(for: curatedURL) ?? .distantPast
            )
        )

        let dailyURLs: [URL]
        do {
            dailyURLs = try fileManager.contentsOfDirectory(
                at: dailyDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            SecureLogger.error("Failed to list memory entries: \(error)", category: .session)
            return entries
        }

        let dailyEntries = dailyURLs
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> AgentMemoryEntry? in
                let dateID = url.deletingPathExtension().lastPathComponent
                guard Self.isValidDateID(dateID) else { return nil }
                return AgentMemoryEntry(
                    id: Self.dailyEntryID(for: dateID),
                    kind: .daily(date: dateID),
                    title: dateID,
                    url: url,
                    lastModified: modificationDate(for: url) ?? .distantPast
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.kind, rhs.kind) {
                case (.daily(let leftDate), .daily(let rightDate)):
                    if leftDate == rightDate {
                        return lhs.lastModified > rhs.lastModified
                    }
                    return leftDate > rightDate
                default:
                    return lhs.lastModified > rhs.lastModified
                }
            }

        entries.append(contentsOf: dailyEntries)
        return entries
    }

    func readEntry(id: String) throws -> String {
        guard let url = urlForEntry(id: id) else {
            throw AgentMemoryStoreError.unknownEntry
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return ""
        }

        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeEntry(id: String, content: String) throws {
        guard let url = urlForEntry(id: id) else {
            throw AgentMemoryStoreError.unknownEntry
        }

        ensureDirectories()
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = normalized.data(using: .utf8, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: [.atomic])
    }

    @discardableResult
    func ensureDailyEntry(for date: Date = Date()) throws -> String {
        let dateID = Self.dayFormatter.string(from: date)
        let id = Self.dailyEntryID(for: dateID)
        let url = dailyURL(for: dateID)

        if !fileManager.fileExists(atPath: url.path) {
            let header = "# \(dateID)\n"
            guard let data = header.data(using: .utf8, allowLossyConversion: false) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: [.atomic])
        }

        return id
    }

    @discardableResult
    func appendDaily(note: String, at date: Date = Date()) throws -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try ensureDailyEntry(for: date)
        }

        let id = try ensureDailyEntry(for: date)
        let dateID = Self.dayFormatter.string(from: date)
        let url = dailyURL(for: dateID)
        let existing = (try? readFile(url: url)) ?? ""
        let timestamp = Self.timeFormatter.string(from: date)
        let section = "\n\n## \(timestamp)\n\(trimmed)\n"
        let merged = existing.isEmpty ? "# \(dateID)\n\n## \(timestamp)\n\(trimmed)\n" : existing + section
        guard let data = merged.data(using: .utf8, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: [.atomic])
        return id
    }

    func wipeAllMemory() {
        do {
            if fileManager.fileExists(atPath: curatedURL.path) {
                try fileManager.removeItem(at: curatedURL)
            }
            if fileManager.fileExists(atPath: dailyDirectoryURL.path) {
                try fileManager.removeItem(at: dailyDirectoryURL)
            }
        } catch {
            SecureLogger.error("Failed to wipe memory store: \(error)", category: .session)
        }
        ensureDirectories()
    }

    private func readFile(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func ensureDirectories() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dailyDirectoryURL, withIntermediateDirectories: true)
        } catch {
            SecureLogger.error("Failed to create memory directories: \(error)", category: .session)
        }
    }

    private func urlForEntry(id: String) -> URL? {
        if id == Self.curatedEntryID {
            return curatedURL
        }

        guard id.hasPrefix(Self.dailyPrefix) else { return nil }
        let dateID = String(id.dropFirst(Self.dailyPrefix.count))
        guard Self.isValidDateID(dateID) else { return nil }
        return dailyURL(for: dateID)
    }

    private func dailyURL(for dateID: String) -> URL {
        dailyDirectoryURL.appendingPathComponent("\(dateID).md")
    }

    private func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private var curatedURL: URL {
        rootURL.appendingPathComponent("MEMORY.md")
    }

    private var dailyDirectoryURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true)
    }

    private static let curatedEntryID = "curated"
    private static let dailyPrefix = "daily:"

    private static func dailyEntryID(for dateID: String) -> String {
        dailyPrefix + dateID
    }

    private static func isValidDateID(_ value: String) -> Bool {
        dayFormatter.date(from: value) != nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func defaultRootURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("bitchat/agent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
