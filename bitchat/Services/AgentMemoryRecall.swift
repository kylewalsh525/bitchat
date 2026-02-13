import Foundation

struct AgentMemorySnippet: Identifiable, Equatable {
    let id: String
    let entryID: String
    let entryTitle: String
    let content: String
    let score: Int
    let source: Source

    enum Source: String, Equatable {
        case manual
        case auto
    }
}

final class AgentMemoryRecall {
    private let store: AgentMemoryStore

    init(store: AgentMemoryStore) {
        self.store = store
    }

    func manualSnippets(entryIDs: Set<String>, maxSnippetBytes: Int) -> [AgentMemorySnippet] {
        guard !entryIDs.isEmpty else { return [] }
        let entriesByID = Dictionary(uniqueKeysWithValues: store.listEntries().map { ($0.id, $0) })

        return entryIDs
            .sorted()
            .compactMap { entryID -> AgentMemorySnippet? in
                guard let entry = entriesByID[entryID],
                      let content = try? store.readEntry(id: entryID) else {
                    return nil
                }
                let trimmed = trimToBytes(normalizeSnippet(content), maxBytes: maxSnippetBytes)
                guard !trimmed.isEmpty else { return nil }
                return AgentMemorySnippet(
                    id: "manual:\(entryID)",
                    entryID: entryID,
                    entryTitle: entry.title,
                    content: trimmed,
                    score: 1,
                    source: .manual
                )
            }
    }

    func recall(
        prompt: String,
        excluding entryIDs: Set<String>,
        limit: Int,
        maxSnippetBytes: Int
    ) -> [AgentMemorySnippet] {
        let keywords = promptKeywords(prompt)
        guard !keywords.isEmpty, limit > 0 else { return [] }

        let entries = store.listEntries().filter { !entryIDs.contains($0.id) }
        var snippets: [AgentMemorySnippet] = []
        snippets.reserveCapacity(min(limit * 2, entries.count))

        for entry in entries {
            guard let raw = try? store.readEntry(id: entry.id) else { continue }
            let lines = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            var bestLine = ""
            var bestScore = 0
            for line in lines {
                let lineLower = line.lowercased()
                var score = 0
                for keyword in keywords where lineLower.contains(keyword) {
                    score += 1
                }
                if score > bestScore {
                    bestLine = line
                    bestScore = score
                }
            }

            guard bestScore > 0 else { continue }
            let snippetText = trimToBytes(normalizeSnippet(bestLine), maxBytes: maxSnippetBytes)
            guard !snippetText.isEmpty else { continue }

            snippets.append(
                AgentMemorySnippet(
                    id: "auto:\(entry.id):\(stableHash(snippetText))",
                    entryID: entry.id,
                    entryTitle: entry.title,
                    content: snippetText,
                    score: bestScore,
                    source: .auto
                )
            )
        }

        return snippets
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.entryTitle < rhs.entryTitle
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    private func promptKeywords(_ prompt: String) -> [String] {
        let words = prompt
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
            .filter { !Self.stopWords.contains($0) }
        return Array(Set(words)).sorted()
    }

    private func normalizeSnippet(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimToBytes(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var used = 0
        var result = ""
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > maxBytes { break }
            result.unicodeScalars.append(scalar)
            used += size
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stableHash(_ value: String) -> String {
        value.data(using: .utf8)?.sha256Hash().hexEncodedString() ?? UUID().uuidString.lowercased()
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "agent", "also", "and", "any", "are", "can", "from", "have",
        "just", "need", "that", "the", "their", "there", "they", "this", "use", "with", "your"
    ]
}
