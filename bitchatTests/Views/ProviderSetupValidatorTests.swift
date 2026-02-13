import XCTest
@testable import bitchat

final class ProviderSetupValidatorTests: XCTestCase {
    func testValidateGatewayURLAcceptsHTTPAndHTTPS() {
        switch ProviderSetupValidator.validateGatewayURL("http://127.0.0.1:8080/agent/run") {
        case .valid(let normalized):
            XCTAssertTrue(normalized.hasPrefix("http://127.0.0.1:8080"))
        default:
            XCTFail("expected valid HTTP gateway URL")
        }

        switch ProviderSetupValidator.validateGatewayURL("https://gateway.example/agent/run") {
        case .valid(let normalized):
            XCTAssertTrue(normalized.hasPrefix("https://gateway.example"))
        default:
            XCTFail("expected valid HTTPS gateway URL")
        }
    }

    func testValidateGatewayURLRejectsMissingHost() {
        let validation = ProviderSetupValidator.validateGatewayURL("http:///agent/run")
        guard case .invalid(let reason) = validation else {
            return XCTFail("expected invalid validation result")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("host"))
    }

    func testValidateGatewayURLRejectsUnsupportedScheme() {
        let validation = ProviderSetupValidator.validateGatewayURL("ftp://example.com/agent/run")
        guard case .invalid(let reason) = validation else {
            return XCTFail("expected invalid validation result")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("http"))
    }

    func testValidateGatewayURLEmpty() {
        XCTAssertEqual(ProviderSetupValidator.validateGatewayURL("  "), .empty)
    }
}
