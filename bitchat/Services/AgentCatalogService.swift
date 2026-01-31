//
// AgentCatalogService.swift
// bitchat
//
// Manual, user-triggered discovery for gateway-supported models.
//

import Foundation

struct AgentCatalog: Codable, Equatable {
    let providers: [String]
    let models: [AgentCatalogModel]
}

struct AgentCatalogModel: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let provider: String
    let name: String?
    let sizeBytes: Int?
    let quant: String?
    let contextTokens: Int?
    let qualityScore: UInt8?
}

enum AgentCatalogStatus: Equatable {
    case idle
    case loading
    case loaded(Date)
    case failed(String)
}

enum AgentGatewayHealth: Equatable {
    case idle
    case checking
    case ok(Date)
    case failed(String)
}

enum AgentCatalogError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid gateway URL"
        case .httpStatus(let code):
            return "gateway HTTP \(code)"
        case .emptyResponse:
            return "empty gateway response"
        case .decodeFailed:
            return "failed to decode gateway catalog"
        }
    }
}

final class AgentCatalogService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkHealth(urlString: String) async -> Result<Void, Error> {
        guard let url = makeEndpointURL(base: urlString, path: "/health") else {
            return .failure(AgentCatalogError.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(AgentCatalogError.emptyResponse) }
            guard (200..<300).contains(http.statusCode) else { return .failure(AgentCatalogError.httpStatus(http.statusCode)) }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func fetchCatalog(urlString: String) async -> Result<AgentCatalog, Error> {
        guard let url = makeEndpointURL(base: urlString, path: "/agent/catalog") else {
            return .failure(AgentCatalogError.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(AgentCatalogError.emptyResponse) }
            guard (200..<300).contains(http.statusCode) else { return .failure(AgentCatalogError.httpStatus(http.statusCode)) }
            guard !data.isEmpty else { return .failure(AgentCatalogError.emptyResponse) }
            guard let decoded = try? JSONDecoder().decode(AgentCatalog.self, from: data) else {
                return .failure(AgentCatalogError.decodeFailed)
            }
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    private func makeEndpointURL(base: String, path: String) -> URL? {
        guard let baseURL = URL(string: base) else { return nil }
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = path
        return components.url
    }
}
