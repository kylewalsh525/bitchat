import XCTest
@testable import bitchat

final class AgentRequesterPreferencesTests: XCTestCase {
    func testDecodeLegacyPreferencesDefaultsQuoteFields() throws {
        let legacyJSON = """
        {
          "minQualityScore": 40,
          "preferKnownModels": true,
          "preferredKnownModelIDs": ["known-1"],
          "penalizeUnknownModels": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AgentRequesterPreferences.self, from: legacyJSON)
        XCTAssertEqual(decoded.minQualityScore, 40)
        XCTAssertEqual(decoded.preferKnownModels, true)
        XCTAssertEqual(decoded.preferredKnownModelIDs, Set(["known-1"]))
        XCTAssertEqual(decoded.penalizeUnknownModels, false)
        XCTAssertEqual(decoded.quoteAutoPickPolicy, .manual)
        XCTAssertEqual(decoded.quoteAutoPickBudget, 0)
    }

    func testEncodeDecodeRoundTripPreservesQuoteFields() throws {
        let prefs = AgentRequesterPreferences(
            minQualityScore: 60,
            preferKnownModels: true,
            preferredKnownModelIDs: Set(["m1"]),
            penalizeUnknownModels: true,
            quoteAutoPickPolicy: .bestQualityUnderBudget,
            quoteAutoPickBudget: 120
        )

        let encoded = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AgentRequesterPreferences.self, from: encoded)
        XCTAssertEqual(decoded, prefs)
    }
}
