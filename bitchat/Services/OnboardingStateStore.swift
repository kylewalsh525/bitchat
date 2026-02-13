import Foundation

@MainActor
final class OnboardingStateStore: ObservableObject {
    private let defaults: UserDefaults
    private let completedKey = "bitchat.onboarding.v1.completed"

    @Published private(set) var isCompleted: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCompleted = defaults.bool(forKey: completedKey)
    }

    func markCompleted() {
        defaults.set(true, forKey: completedKey)
        isCompleted = true
    }

    func resetForTesting() {
        defaults.removeObject(forKey: completedKey)
        isCompleted = false
    }
}

