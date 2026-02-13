//
// AgentKnownModelUpdateService.swift
// bitchat
//
// On-demand fetch + cache for known model hash mappings used by routing.
//

import Foundation

enum AgentKnownModelUpdateError: LocalizedError {
    case invalidURL
    case httpsRequired
    case httpStatus(Int)
    case tooLarge(Int)
    case decodeFailed
    case invalidSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid url"
        case .httpsRequired:
            return "https required"
        case .httpStatus(let code):
            return "http \(code)"
        case .tooLarge(let maxBytes):
            return "response too large (max \(maxBytes) bytes)"
        case .decodeFailed:
            return "failed to decode model catalog"
        case .invalidSchema(let message):
            return "invalid schema: \(message)"
        }
    }
}

final class AgentKnownModelUpdateService {
    struct Metadata: Codable, Equatable {
        let urlString: String
        let fetchedAt: Date
        let modelCount: Int
    }

    private let session: URLSession
    private let overlayURL: URL
    private let defaults: UserDefaults
    private let sizeLimitBytes: Int

    private static let sourceURLKey = "bitchat.agent.mesh.known_models.source_url"
    private static let metadataKey = "bitchat.agent.mesh.known_models.last_fetch_metadata"
    private static let lastErrorKey = "bitchat.agent.mesh.known_models.last_fetch_error"

    init(
        session: URLSession = .shared,
        overlayURL: URL = AgentKnownModelCatalog.defaultOverlayURL(),
        defaults: UserDefaults = .standard,
        sizeLimitBytes: Int = 512 * 1024
    ) {
        self.session = session
        self.overlayURL = overlayURL
        self.defaults = defaults
        self.sizeLimitBytes = max(32 * 1024, sizeLimitBytes)
    }

    func storedSourceURL() -> String? {
        defaults.string(forKey: Self.sourceURLKey)
    }

    func storedMetadata() -> Metadata? {
        guard let data = defaults.data(forKey: Self.metadataKey),
              let decoded = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        return decoded
    }

    func storedLastError() -> String? {
        defaults.string(forKey: Self.lastErrorKey)
    }

    func update(from urlString: String) async -> Result<Metadata, Error> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: Self.sourceURLKey)

        guard let url = URL(string: trimmed) else {
            recordFailure(AgentKnownModelUpdateError.invalidURL)
            return .failure(AgentKnownModelUpdateError.invalidURL)
        }
        guard url.scheme?.lowercased() == "https" else {
            recordFailure(AgentKnownModelUpdateError.httpsRequired)
            return .failure(AgentKnownModelUpdateError.httpsRequired)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                recordFailure(AgentKnownModelUpdateError.decodeFailed)
                return .failure(AgentKnownModelUpdateError.decodeFailed)
            }
            guard (200..<300).contains(http.statusCode) else {
                let err = AgentKnownModelUpdateError.httpStatus(http.statusCode)
                recordFailure(err)
                return .failure(err)
            }
            guard data.count <= sizeLimitBytes else {
                let err = AgentKnownModelUpdateError.tooLarge(sizeLimitBytes)
                recordFailure(err)
                return .failure(err)
            }

            guard let decoded = try? JSONDecoder().decode(AgentKnownModelOverlay.self, from: data) else {
                recordFailure(AgentKnownModelUpdateError.decodeFailed)
                return .failure(AgentKnownModelUpdateError.decodeFailed)
            }

            let validated = validateAndCanonicalize(decoded)
            switch validated {
            case .failure(let error):
                recordFailure(error)
                return .failure(error)
            case .success(let overlay):
                try writeOverlay(overlay)
                let meta = Metadata(urlString: trimmed, fetchedAt: Date(), modelCount: overlay.models.count)
                if let metaData = try? JSONEncoder().encode(meta) {
                    defaults.set(metaData, forKey: Self.metadataKey)
                }
                defaults.removeObject(forKey: Self.lastErrorKey)
                return .success(meta)
            }
        } catch {
            recordFailure(error)
            return .failure(error)
        }
    }

    // MARK: - Validation

    private func validateAndCanonicalize(_ overlay: AgentKnownModelOverlay) -> Result<AgentKnownModelOverlay, Error> {
        var seen: Set<String> = []
        var models: [AgentKnownModel] = []
        models.reserveCapacity(overlay.models.count)

        for raw in overlay.models {
            guard let model = AgentKnownModelCatalog.sanitized(raw) else {
                return .failure(AgentKnownModelUpdateError.invalidSchema("model missing id/name"))
            }
            if seen.contains(model.id) {
                return .failure(AgentKnownModelUpdateError.invalidSchema("duplicate model id '\(model.id)'"))
            }
            seen.insert(model.id)
            models.append(model)
        }

        // The overlay is allowed to be empty (built-in list still exists).
        return .success(AgentKnownModelOverlay(version: overlay.version, models: models))
    }

    // MARK: - Persistence

    private func writeOverlay(_ overlay: AgentKnownModelOverlay) throws {
        let dir = overlayURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(overlay)
        try data.write(to: overlayURL, options: [.atomic])
    }

    private func recordFailure(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        defaults.set(message, forKey: Self.lastErrorKey)
    }
}

