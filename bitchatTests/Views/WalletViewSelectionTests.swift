import Foundation
import Testing
@testable import bitchat

struct WalletViewSelectionTests {
    @Test("resolveSelection keeps current value when still available")
    func keepsCurrentSelection() {
        let result = WalletView.resolveSelection(
            current: "https://mint-b.example",
            available: ["https://mint-a.example", "https://mint-b.example"]
        )

        #expect(result == "https://mint-b.example")
    }

    @Test("resolveSelection falls back to first available when current disappears")
    func fallsBackToFirstAvailable() {
        let result = WalletView.resolveSelection(
            current: "https://missing.example",
            available: ["https://mint-a.example", "https://mint-b.example"]
        )

        #expect(result == "https://mint-a.example")
    }

    @Test("resolveSelection uses fallback when nothing available")
    func usesFallbackWhenEmpty() {
        let result = WalletView.resolveSelection(
            current: "",
            available: [],
            fallback: "sat"
        )

        #expect(result == "sat")
    }
}
