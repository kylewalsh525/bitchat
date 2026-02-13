import Foundation

final class CashuMintAllowlistStore: ObservableObject {
    private let defaults: UserDefaults
    private let key = "bitchat.cashu.mint.allowlist.v1"

    @Published private(set) var allowedMintURLs: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.allowedMintURLs = (defaults.array(forKey: key) as? [String] ?? [])
            .map(Self.normalizeMintURL)
            .filter { !$0.isEmpty }
            .uniqued()
            .sorted()
    }

    func isAllowed(mintURL: String) -> Bool {
        let normalized = Self.normalizeMintURL(mintURL)
        guard !normalized.isEmpty else { return false }
        return allowedMintURLs.contains(normalized)
    }

    func allow(mintURL: String) {
        let normalized = Self.normalizeMintURL(mintURL)
        guard !normalized.isEmpty else { return }
        if allowedMintURLs.contains(normalized) { return }
        allowedMintURLs.append(normalized)
        allowedMintURLs = allowedMintURLs.uniqued().sorted()
        persist()
    }

    func revoke(mintURL: String) {
        let normalized = Self.normalizeMintURL(mintURL)
        guard !normalized.isEmpty else { return }
        allowedMintURLs.removeAll { $0 == normalized }
        persist()
    }

    func setAllowed(_ mintURLs: [String]) {
        allowedMintURLs = mintURLs
            .map(Self.normalizeMintURL)
            .filter { !$0.isEmpty }
            .uniqued()
            .sorted()
        persist()
    }

    private func persist() {
        defaults.set(allowedMintURLs, forKey: key)
    }

    static func normalizeMintURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var out = trimmed
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        var out: [Element] = []
        out.reserveCapacity(count)
        for item in self {
            if seen.insert(item).inserted {
                out.append(item)
            }
        }
        return out
    }
}

