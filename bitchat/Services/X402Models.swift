import Foundation

struct X402PaymentRequestEnvelope: Codable, Equatable {
    let version: Int
    let paymentID: String
    let requestID: String
    let amount: UInt64
    let unit: String
    let chainID: UInt64
    let tokenAddress: String
    let payTo: String
    let gatewayURL: String
    let expiresAtMs: UInt64
    let sessionID: String?
    let scheme: AgentX402Scheme
    let facilitatorID: String?

    static let prefix = "xreq:"

    init(
        version: Int,
        paymentID: String,
        requestID: String,
        amount: UInt64,
        unit: String,
        chainID: UInt64,
        tokenAddress: String,
        payTo: String,
        gatewayURL: String,
        expiresAtMs: UInt64,
        sessionID: String?,
        scheme: AgentX402Scheme = .exact,
        facilitatorID: String? = "thirdweb"
    ) {
        self.version = version
        self.paymentID = paymentID
        self.requestID = requestID
        self.amount = amount
        self.unit = unit
        self.chainID = chainID
        self.tokenAddress = tokenAddress
        self.payTo = payTo
        self.gatewayURL = gatewayURL
        self.expiresAtMs = expiresAtMs
        self.sessionID = sessionID
        self.scheme = scheme
        self.facilitatorID = facilitatorID
    }

    func encodeString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64URLEncodedString()
    }

    static func decode(from string: String) -> X402PaymentRequestEnvelope? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if raw.hasPrefix(Self.prefix) {
            body = String(raw.dropFirst(Self.prefix.count))
        } else {
            body = raw
        }
        guard let data = Data(base64URLEncoded: body),
              let parsed = try? JSONDecoder().decode(X402PaymentRequestEnvelope.self, from: data) else {
            return nil
        }
        return parsed
    }
}

struct X402PaymentPayloadEnvelope: Codable, Equatable {
    let paymentID: String
    let requestID: String
    let paymentData: String
    let payerAddress: String
    let clientNonce: String
    let createdAtMs: UInt64

    static let prefix = "xpay:"

    init(
        paymentID: String,
        requestID: String,
        paymentData: String,
        payerAddress: String,
        clientNonce: String,
        createdAtMs: UInt64
    ) {
        self.paymentID = paymentID
        self.requestID = requestID
        self.paymentData = paymentData
        self.payerAddress = payerAddress
        self.clientNonce = clientNonce
        self.createdAtMs = createdAtMs
    }

    func encodeString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64URLEncodedString()
    }

    static func decode(from string: String) -> X402PaymentPayloadEnvelope? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.prefix) {
            let body = String(trimmed.dropFirst(Self.prefix.count))
            guard let data = Data(base64URLEncoded: body),
                  let parsed = try? JSONDecoder().decode(X402PaymentPayloadEnvelope.self, from: data) else {
                return nil
            }
            return parsed
        }
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(X402PaymentPayloadEnvelope.self, from: data) {
            return parsed
        }
        return nil
    }
}

func x402PaymentRefHash(paymentID: String, paymentData: String) -> String {
    let material = "\(paymentID)|\(paymentData)"
    return Data(material.utf8).sha256Hex()
}

struct X402WalletPaymentResult: Equatable {
    let paymentData: String
    let payerAddress: String
}

protocol X402GuestWalletPaying: AnyObject {
    func ensureGuestWallet() async throws -> String
    func payX402(
        gatewayURL: String,
        paymentID: String,
        requestID: String,
        amount: UInt64,
        chainID: UInt64,
        tokenAddress: String,
        payTo: String
    ) async throws -> X402WalletPaymentResult
    func linkWallet() async throws
    func exportPrivateKey() async throws -> String
    func resetWallet() async
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded: String) {
        var normalized = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }
}
