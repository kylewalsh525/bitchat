import Foundation

struct SupportEvent: Codable, Equatable, Hashable {
    let timestampMs: UInt64
    let category: String
    let message: String
}

actor SupportEventLog {
    static let shared = SupportEventLog()

    private let capacity: Int = 200
    private var events: [SupportEvent] = []

    func record(category: String, message: String) {
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmedCategory.isEmpty, !trimmedMessage.isEmpty else { return }

        let safeMessage = Self.sanitize(trimmedMessage)
        let event = SupportEvent(
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            category: trimmedCategory,
            message: safeMessage
        )

        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func snapshot(limit: Int = 200) -> [SupportEvent] {
        let capped = max(0, min(limit, events.count))
        if capped == events.count { return events }
        return Array(events.suffix(capped))
    }

    func clear() {
        events.removeAll(keepingCapacity: false)
    }

    private static func sanitize(_ message: String) -> String {
        // Best-effort safety net: never intentionally export bearer token contents.
        let patterns = ["cashuA", "cashuB", "creq:", "p2pk:", "proof", "token"]
        var out = message
        for needle in patterns {
            if out.localizedCaseInsensitiveContains(needle) {
                out = "[redacted]"
                break
            }
        }
        if out.count > 400 {
            return String(out.prefix(400)) + "…"
        }
        return out
    }
}

