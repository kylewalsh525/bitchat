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
    static let compactPrefix = "xr2:"

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
        if let compact = encodeCompactString() {
            return compact
        }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64URLEncodedString()
    }

    static func decode(from string: String) -> X402PaymentRequestEnvelope? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix(Self.compactPrefix) {
            return decodeCompactString(String(raw.dropFirst(Self.compactPrefix.count)))
        }
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

    private func encodeCompactString() -> String? {
        guard !paymentID.isEmpty else { return nil }
        guard !requestID.isEmpty else { return nil }
        guard let gatewayData = gatewayURL.data(using: .utf8), !gatewayData.isEmpty else { return nil }

        var pairs: [String] = []
        pairs.append("p=\(paymentID)")
        pairs.append("r=\(requestID)")
        pairs.append("a=\(amount)")
        pairs.append("u=\(unit)")
        pairs.append("c=\(chainID)")
        pairs.append("t=\(tokenAddress)")
        pairs.append("y=\(payTo)")
        pairs.append("g=\(gatewayData.base64URLEncodedString())")
        pairs.append("e=\(expiresAtMs)")
        pairs.append("h=\(scheme == .exact ? "e" : "e")")
        if let facilitatorID, !facilitatorID.isEmpty {
            pairs.append("f=\(facilitatorID)")
        }
        return Self.compactPrefix + pairs.joined(separator: "&")
    }

    private static func decodeCompactString(_ body: String) -> X402PaymentRequestEnvelope? {
        let map = parseCompactMap(body)
        guard let paymentID = map["p"], !paymentID.isEmpty else { return nil }
        guard let requestID = map["r"], !requestID.isEmpty else { return nil }
        guard let amountRaw = map["a"], let amount = UInt64(amountRaw) else { return nil }
        guard let unit = map["u"], !unit.isEmpty else { return nil }
        guard let chainRaw = map["c"], let chainID = UInt64(chainRaw) else { return nil }
        guard let tokenAddress = map["t"], !tokenAddress.isEmpty else { return nil }
        guard let payTo = map["y"], !payTo.isEmpty else { return nil }
        guard let gatewayEncoded = map["g"],
              let gatewayData = Data(base64URLEncoded: gatewayEncoded),
              let gatewayURL = String(data: gatewayData, encoding: .utf8),
              !gatewayURL.isEmpty else { return nil }
        guard let expiresRaw = map["e"], let expiresAtMs = UInt64(expiresRaw) else { return nil }

        let sessionID: String?
        if let encodedSession = map["q"],
           let sessionData = Data(base64URLEncoded: encodedSession),
           let decodedSession = String(data: sessionData, encoding: .utf8),
           !decodedSession.isEmpty {
            sessionID = decodedSession
        } else {
            sessionID = nil
        }

        let scheme: AgentX402Scheme
        switch map["h"] {
        case "e":
            scheme = .exact
        default:
            scheme = .exact
        }

        return X402PaymentRequestEnvelope(
            version: 2,
            paymentID: paymentID,
            requestID: requestID,
            amount: amount,
            unit: unit,
            chainID: chainID,
            tokenAddress: tokenAddress,
            payTo: payTo,
            gatewayURL: gatewayURL,
            expiresAtMs: expiresAtMs,
            sessionID: sessionID,
            scheme: scheme,
            facilitatorID: map["f"]
        )
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

private func parseCompactMap(_ body: String) -> [String: String] {
    guard !body.isEmpty else { return [:] }
    var map: [String: String] = [:]
    for segment in body.split(separator: "&") {
        let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let key = String(parts[0])
        let value = String(parts[1])
        guard !key.isEmpty else { continue }
        map[key] = value
    }
    return map
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
