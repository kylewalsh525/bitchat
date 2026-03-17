import XCTest
@testable import bitchat

final class CashuTokenParserTests: XCTestCase {
    private let sampleCashuBToken = "cashuBo2F0gaJhaUgAmh8pMlPkHmFwhqNhYRkCAGFzeEA1OTY0MDU5MmMwNjY1MmU3M2QyODc4YTI4OTVkMTNmZDBhMmQ3NTZiODY4N2U0YTYyY2M0N2I2MTVmODIzZDg1YWNYIQPdUCr5uX-6a2TYHhxxO1ldJlc3A-U0BeiLno8v6FIGxqNhYRkBAGFzeEBkYWJjMTMwMTlmZGIyZTkyMDI3NTdmNWUzMzlhYzAwNTAyNThmOGYxYmFkNmUzZjkyM2QzMzg3ZmMyYjZlY2M4YWNYIQNlaRLMsl4tJITmfpR7xCGf7RnhqeyWWr-Ra5KMgWSY9KNhYRiAYXN4QDhlOTczZTYwOGMyNzM5Y2FlYjczYmRlZDRkZWQzMTFkNTdlMDhiMzIyYjdlMDAxYTdjZTE4NzJkOTE5OTA3OTVhY1ghApp8CByhEX6ioOTd6s9dBqud8f2_m7eInc0iblK5IyjQo2FhGEBhc3hAN2RkNDZmYTNmZTcwODg1MjQxYjA1YjFmMTNmYThiNDA3ODRlOWE5YTkzMzBiMzlmYjFmNDI0N2JkMjQyMjlmMmFjWCED5YgxJWuS94w7NEBNBZQCcx3JcQXxIdbPV0AaAjDIqqSjYWEYIGFzeEA3MzQ2YjZhMTQyYTI3YTA2NmE4MTgwZTI3OWFjY2U3YzNjNGUyZGM2NWExZjU1MDYxNzQxZTEzNjEzN2NkNTMzYWNYIQNcP94M2-OBNIRWfU6dlDkWyq2lUlGFkYHCxz8muMLjY6NhYQhhc3hAYjJlYWM3ZmQ1NjM2NDVjZGRjY2M3YTMwZjFjN2NjOGQ4MWM0NDgwMGQyMmY1MmMxZDY4NmUwZDdlNGZlMDcxM2FjWCED5kjSSE4miLjPfpnb_BvxuLncgk1kx4jRExyHXqCT8mhhbXVodHRwOi8vMTI3LjAuMC4xOjMzMzhhdWNzYXQ"

    func testParsesCashuA() {
        let originalProof = CashuProof(id: "proof-id", amount: 10, secret: "secret-1", C: "c1", witness: nil)
        guard let token = CashuTokenParser.exportTokenString(
            mintURL: "https://mint.example",
            unit: "sat",
            proofs: [originalProof]
        ) else {
            XCTFail("failed to create token")
            return
        }
        guard let bundles = CashuTokenParser.parseTokenString(token) else {
            XCTFail("expected token parse")
            return
        }
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(bundles[0].mintURL, "https://mint.example")
        XCTAssertEqual(bundles[0].unit, "sat")
        XCTAssertEqual(bundles[0].proofs.count, 1)
        XCTAssertEqual(bundles[0].proofs[0].amount, 10)
        XCTAssertEqual(bundles[0].proofs[0].secret, "secret-1")
    }

    func testParsesCashuB() {
        #if canImport(CashuDevKit)
        guard let bundles = CashuTokenParser.parseTokenString(sampleCashuBToken) else {
            XCTFail("expected cashuB parse")
            return
        }
        XCTAssertEqual(bundles.count, 1)
        XCTAssertFalse(bundles[0].mintURL.isEmpty)
        XCTAssertFalse(bundles[0].proofs.isEmpty)
        #else
        XCTAssertNil(CashuTokenParser.parseTokenString(sampleCashuBToken))
        #endif
    }

    func testParsesPrefixedCashuBText() {
        let pasted = "1: \(sampleCashuBToken)"
        guard let extracted = CashuTokenParser.extractFirstTokenCandidate(from: pasted) else {
            XCTFail("expected candidate extraction")
            return
        }
        XCTAssertEqual(extracted, sampleCashuBToken)

        #if canImport(CashuDevKit)
        XCTAssertNotNil(CashuTokenParser.parseTokenString(pasted))
        #else
        XCTAssertNil(CashuTokenParser.parseTokenString(pasted))
        #endif
    }

    func testParsesWrappedCashuBText() {
        let midpoint = sampleCashuBToken.index(sampleCashuBToken.startIndex, offsetBy: sampleCashuBToken.count / 2)
        let wrapped = String(sampleCashuBToken[..<midpoint]) + "\n" + String(sampleCashuBToken[midpoint...])
        guard let extracted = CashuTokenParser.extractFirstTokenCandidate(from: wrapped) else {
            XCTFail("expected wrapped token extraction")
            return
        }
        XCTAssertEqual(extracted, sampleCashuBToken)

        #if canImport(CashuDevKit)
        XCTAssertNotNil(CashuTokenParser.parseTokenString(wrapped))
        #else
        XCTAssertNil(CashuTokenParser.parseTokenString(wrapped))
        #endif
    }

    func testRejectsMalformedToken() {
        XCTAssertNil(CashuTokenParser.parseTokenString("cashuB-not-a-real-token"))
        XCTAssertNil(CashuTokenParser.parseTokenString("totally invalid"))
    }
}
