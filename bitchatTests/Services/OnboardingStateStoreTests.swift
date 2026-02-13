import XCTest
@testable import bitchat

final class OnboardingStateStoreTests: XCTestCase {
    @MainActor
    func testMarkCompletedPersists() {
        let defaults = UserDefaults(suiteName: "OnboardingStateStoreTests.\(UUID().uuidString)")!
        let store = OnboardingStateStore(defaults: defaults)
        XCTAssertFalse(store.isCompleted)

        store.markCompleted()
        XCTAssertTrue(store.isCompleted)

        let reloaded = OnboardingStateStore(defaults: defaults)
        XCTAssertTrue(reloaded.isCompleted)
    }
}

