import Foundation

extension ChatViewModel {
    @MainActor
    func refreshAgentMemoryEntries() {
        let entries = agentMemoryStore.listEntries()
        agentMemoryEntries = entries

        let validIDs = Set(entries.map { $0.id })
        attachedAgentMemoryEntryIDs = attachedAgentMemoryEntryIDs.filter { validIDs.contains($0) }

        if let selected = selectedAgentMemoryEntryID, !validIDs.contains(selected) {
            selectedAgentMemoryEntryID = nil
            selectedAgentMemoryContent = ""
        }

        if selectedAgentMemoryEntryID == nil {
            selectedAgentMemoryEntryID = entries.first?.id
        }

        persistAgentMemoryPreferences()
    }

    @MainActor
    func selectAgentMemoryEntry(_ entryID: String) {
        selectedAgentMemoryEntryID = entryID
        selectedAgentMemoryContent = (try? agentMemoryStore.readEntry(id: entryID)) ?? ""
    }

    @MainActor
    func saveSelectedAgentMemoryEntry() -> CommandResult {
        guard let entryID = selectedAgentMemoryEntryID else {
            return .error(message: "select a memory entry first")
        }
        do {
            try agentMemoryStore.writeEntry(id: entryID, content: selectedAgentMemoryContent)
            agentMemoryLastSavedAt = Date()
            refreshAgentMemoryEntries()
            return .success(message: nil)
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    @MainActor
    func ensureTodayMemoryEntrySelected() -> CommandResult {
        do {
            let entryID = try agentMemoryStore.ensureDailyEntry()
            refreshAgentMemoryEntries()
            selectAgentMemoryEntry(entryID)
            return .success(message: nil)
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    @MainActor
    func appendAgentDailyMemoryNote(_ note: String) -> CommandResult {
        do {
            let entryID = try agentMemoryStore.appendDaily(note: note)
            refreshAgentMemoryEntries()
            selectAgentMemoryEntry(entryID)
            return .success(message: nil)
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    @MainActor
    func setAgentMemoryAutoRecall(enabled: Bool) {
        agentMemoryAutoRecallEnabled = enabled
        persistAgentMemoryPreferences()
    }

    @MainActor
    func toggleAttachedAgentMemoryEntry(entryID: String) {
        if attachedAgentMemoryEntryIDs.contains(entryID) {
            attachedAgentMemoryEntryIDs.remove(entryID)
        } else {
            attachedAgentMemoryEntryIDs.insert(entryID)
        }
        persistAgentMemoryPreferences()
    }

    @MainActor
    func isAgentMemoryEntryAttached(_ entryID: String) -> Bool {
        attachedAgentMemoryEntryIDs.contains(entryID)
    }

    @MainActor
    func wipeAgentMemoryAndSessions() {
        agentMemoryStore.wipeAllMemory()
        attachedAgentMemoryEntryIDs.removeAll()
        selectedAgentMemoryEntryID = nil
        selectedAgentMemoryContent = ""
        agentMemoryLastSavedAt = nil
        wipeAllAgentSessions()
        refreshAgentMemoryEntries()
    }

    @MainActor
    func buildAgentMemoryContext(for prompt: String) -> (context: String, snippets: [AgentMemorySnippet]) {
        var snippets = agentMemoryRecall.manualSnippets(
            entryIDs: attachedAgentMemoryEntryIDs,
            maxSnippetBytes: TransportConfig.agentMemorySnippetMaxBytes
        )

        if agentMemoryAutoRecallEnabled {
            let auto = agentMemoryRecall.recall(
                prompt: prompt,
                excluding: attachedAgentMemoryEntryIDs,
                limit: TransportConfig.agentMemoryRecallMaxSnippets,
                maxSnippetBytes: TransportConfig.agentMemorySnippetMaxBytes
            )
            for candidate in auto {
                if snippets.contains(where: { $0.entryID == candidate.entryID && $0.content == candidate.content }) {
                    continue
                }
                snippets.append(candidate)
            }
        }

        guard !snippets.isEmpty else { return ("", []) }

        var lines: [String] = ["Local memory context (device-only):"]
        for snippet in snippets {
            let source = snippet.source == .manual ? "manual" : "auto"
            lines.append("- [\(source)] \(snippet.entryTitle): \(snippet.content)")
        }

        let joined = lines.joined(separator: "\n")
        let limited = trimMemoryTextToBytes(joined, maxBytes: TransportConfig.agentMemoryContextMaxBytes)
        guard !limited.isEmpty else { return ("", []) }
        return (limited, snippets)
    }

    @MainActor
    func memoryEntryLabel(for entry: AgentMemoryEntry) -> String {
        switch entry.kind {
        case .curated:
            return "Long-term"
        case .daily(let date):
            return date
        }
    }

    private func persistAgentMemoryPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(agentMemoryAutoRecallEnabled, forKey: agentMemoryAutoRecallKey)
        defaults.set(Array(attachedAgentMemoryEntryIDs).sorted(), forKey: agentMemoryAttachedEntriesKey)
    }

    private func trimMemoryTextToBytes(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var used = 0
        var output = ""
        for scalar in text.unicodeScalars {
            let bytes = String(scalar).utf8.count
            if used + bytes > maxBytes { break }
            output.unicodeScalars.append(scalar)
            used += bytes
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
