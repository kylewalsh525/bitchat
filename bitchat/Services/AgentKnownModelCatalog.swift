//
// AgentKnownModelCatalog.swift
// bitchat
//
// Built-in + cached mapping from (modelId/modelHash) -> known model identity.
//

import Foundation

struct AgentKnownModel: Codable, Identifiable, Equatable, Hashable {
    /// Stable identifier used for preferences/routing.
    let id: String
    /// User-facing display name.
    let name: String
    /// Case-insensitive substring matchers evaluated against `AgentInfo.modelId`.
    let matchers: [String]
    /// Known artifact digests for this model.
    /// Stored in canonical digest form: `sha256:<hex>`.
    let hashes: [String]
}

enum AgentKnownModelMatchKind: String, Codable {
    case hash
    case matcher
}

struct AgentKnownModelMatch: Equatable {
    let model: AgentKnownModel
    let kind: AgentKnownModelMatchKind
    let matchedValue: String
}

struct AgentKnownModelOverlay: Codable, Equatable {
    var version: Int?
    var models: [AgentKnownModel]
}

final class AgentKnownModelCatalog {
    private let overlayURL: URL
    private let fileManager: FileManager
    private let builtIn: [AgentKnownModel]

    init(
        overlayURL: URL = AgentKnownModelCatalog.defaultOverlayURL(),
        fileManager: FileManager = .default,
        builtIn: [AgentKnownModel] = AgentKnownModelCatalog.builtInModels
    ) {
        self.overlayURL = overlayURL
        self.fileManager = fileManager
        self.builtIn = builtIn
    }

    func allModels() -> [AgentKnownModel] {
        let overlay = loadOverlayModels()

        // Overlay overrides built-in by id (and can also add new ids).
        var map: [String: AgentKnownModel] = [:]
        for model in builtIn {
            map[model.id] = model
        }
        for model in overlay {
            map[model.id] = model
        }

        return map.values.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }

    func resolve(modelId: String?, modelHash: String?) -> AgentKnownModelMatch? {
        let models = allModels()

        if let modelHash, let digest = Self.canonicalDigest(from: modelHash) {
            for model in models {
                if model.hashes.contains(digest) {
                    return AgentKnownModelMatch(model: model, kind: .hash, matchedValue: digest)
                }
            }
        }

        if let modelId {
            let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return nil }
            for model in models {
                for matcher in model.matchers {
                    let needle = matcher.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !needle.isEmpty else { continue }
                    if normalized.contains(needle) {
                        return AgentKnownModelMatch(model: model, kind: .matcher, matchedValue: needle)
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Overlay

    private func loadOverlayModels() -> [AgentKnownModel] {
        guard fileManager.fileExists(atPath: overlayURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: overlayURL)
            let decoded = try JSONDecoder().decode(AgentKnownModelOverlay.self, from: data)
            return decoded.models.map { Self.sanitized($0) }.filter { $0 != nil }.compactMap { $0 }
        } catch {
            return []
        }
    }

    // MARK: - Normalization / Validation

    static func sanitized(_ model: AgentKnownModel) -> AgentKnownModel? {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !name.isEmpty else { return nil }

        let matchers = model.matchers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let hashes = model.hashes.compactMap { canonicalDigest(from: $0) }
        let dedupedHashes = Array(NSOrderedSet(array: hashes)) as? [String] ?? hashes

        return AgentKnownModel(id: id, name: name, matchers: matchers, hashes: dedupedHashes)
    }

    /// Convert `ollama:sha256:<hex>`, `sha256:<hex>`, or raw `<hex>` to canonical `sha256:<hex>`.
    static func canonicalDigest(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return nil }

        func isHex64(_ value: String) -> Bool {
            guard value.count == 64 else { return false }
            return value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
        }

        if trimmed.hasPrefix("ollama:sha256:") {
            let hex = String(trimmed.dropFirst("ollama:sha256:".count))
            guard isHex64(hex) else { return nil }
            return "sha256:\(hex)"
        }

        if trimmed.hasPrefix("sha256:") {
            let hex = String(trimmed.dropFirst("sha256:".count))
            guard isHex64(hex) else { return nil }
            return "sha256:\(hex)"
        }

        if isHex64(trimmed) {
            return "sha256:\(trimmed)"
        }

        return nil
    }

    static func defaultOverlayURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("bitchat/agent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known_models.json")
    }

    // MARK: - Built-In Models

    // NOTE: This list is intentionally small and matcher-based.
    // Hashes are expected to be provided via the overlay update for specific distributions/artifacts.
    private static let builtInModels: [AgentKnownModel] = [
        AgentKnownModel(id: "llama", name: "Llama (family)", matchers: ["llama"], hashes: []),
        AgentKnownModel(id: "qwen", name: "Qwen (family)", matchers: ["qwen"], hashes: []),
        AgentKnownModel(id: "mistral", name: "Mistral (family)", matchers: ["mistral", "mixtral"], hashes: []),
        AgentKnownModel(id: "gemma", name: "Gemma (family)", matchers: ["gemma"], hashes: []),
        AgentKnownModel(id: "phi", name: "Phi (family)", matchers: ["phi"], hashes: []),
        AgentKnownModel(id: "deepseek", name: "DeepSeek (family)", matchers: ["deepseek"], hashes: [])
    ]
}
