import Foundation
#if canImport(CashuDevKit)
import CashuDevKit
#endif

struct CashuProof: Codable, Equatable, Hashable {
    let id: String?
    let amount: UInt64
    let secret: String
    let C: String?
    let witness: String?

    init(id: String? = nil, amount: UInt64, secret: String, C: String? = nil, witness: String? = nil) {
        self.id = id
        self.amount = amount
        self.secret = secret
        self.C = C
        self.witness = witness
    }

    var fingerprint: String {
        secret.data(using: .utf8)?.sha256Hash().hexEncodedString() ?? UUID().uuidString
    }
}

struct CashuMintProofBundle: Codable, Equatable {
    let mintURL: String
    let unit: String
    var proofs: [CashuProof]
}

struct CashuTokenEntry: Codable, Equatable {
    let mint: String
    let proofs: [CashuProof]
    let unit: String?
}

struct CashuTokenEnvelope: Codable, Equatable {
    let token: [CashuTokenEntry]?
    let mint: String?
    let unit: String?
    let proofs: [CashuProof]?
}

struct CashuPaymentRequestEnvelope: Codable, Equatable {
    let version: Int
    let paymentID: String
    let requestID: String
    let mintURL: String
    let unit: String
    let amount: UInt64
    let expiresAtMs: UInt64
    let settlementMode: AgentSettlementMode
    let sessionID: String?
    let requiresLocking: AgentPaymentLockingMode?
    let lockPubkey: String?
    let lockSigFlag: UInt8?
    let pricingModel: AgentPaymentPriceModel?
    let trancheIndex: UInt32?
    let trancheCount: UInt32?
    let trancheTokenCount: UInt32?
    let outputTokenPrice: UInt64?
    let inputTokenPrice: UInt64?
    let minimumDeposit: UInt64?

    static let prefix = "creq:"
    static let compactPrefix = "cr2:"

    init(
        version: Int,
        paymentID: String,
        requestID: String,
        mintURL: String,
        unit: String,
        amount: UInt64,
        expiresAtMs: UInt64,
        settlementMode: AgentSettlementMode,
        sessionID: String?,
        requiresLocking: AgentPaymentLockingMode? = nil,
        lockPubkey: String? = nil,
        lockSigFlag: UInt8? = 1,
        pricingModel: AgentPaymentPriceModel?,
        trancheIndex: UInt32?,
        trancheCount: UInt32?,
        trancheTokenCount: UInt32?,
        outputTokenPrice: UInt64?,
        inputTokenPrice: UInt64?,
        minimumDeposit: UInt64?
    ) {
        self.version = version
        self.paymentID = paymentID
        self.requestID = requestID
        self.mintURL = mintURL
        self.unit = unit
        self.amount = amount
        self.expiresAtMs = expiresAtMs
        self.settlementMode = settlementMode
        self.sessionID = sessionID
        self.requiresLocking = requiresLocking
        self.lockPubkey = lockPubkey
        self.lockSigFlag = lockSigFlag
        self.pricingModel = pricingModel
        self.trancheIndex = trancheIndex
        self.trancheCount = trancheCount
        self.trancheTokenCount = trancheTokenCount
        self.outputTokenPrice = outputTokenPrice
        self.inputTokenPrice = inputTokenPrice
        self.minimumDeposit = minimumDeposit
    }

    func encodeString() -> String? {
        if let compact = encodeCompactString() {
            return compact
        }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64URLEncodedString()
    }

    static func decode(from string: String) -> CashuPaymentRequestEnvelope? {
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
              let parsed = try? JSONDecoder().decode(CashuPaymentRequestEnvelope.self, from: data) else {
            return nil
        }
        return parsed
    }

    private func encodeCompactString() -> String? {
        guard !paymentID.isEmpty else { return nil }
        guard !requestID.isEmpty else { return nil }
        guard let mintData = mintURL.data(using: .utf8), !mintData.isEmpty else { return nil }

        var pairs: [String] = []
        pairs.append("p=\(paymentID)")
        pairs.append("r=\(requestID)")
        pairs.append("m=\(mintData.base64URLEncodedString())")
        pairs.append("u=\(unit)")
        pairs.append("a=\(amount)")
        pairs.append("e=\(expiresAtMs)")
        pairs.append("s=\(settlementMode == .offlineAccepted ? "f" : "o")")
        pairs.append("l=\((requiresLocking ?? .none) == .p2pk ? "p" : "n")")

        if let lockPubkey, !lockPubkey.isEmpty {
            pairs.append("k=\(lockPubkey)")
        }
        if let lockSigFlag {
            pairs.append("f=\(lockSigFlag)")
        }
        if let pricingModel {
            pairs.append("pm=\(pricingModel == .perToken ? "t" : "r")")
        }
        if let trancheIndex {
            pairs.append("ti=\(trancheIndex)")
        }
        if let trancheCount {
            pairs.append("tc=\(trancheCount)")
        }
        if let trancheTokenCount {
            pairs.append("tt=\(trancheTokenCount)")
        }
        if let outputTokenPrice {
            pairs.append("op=\(outputTokenPrice)")
        }
        if let inputTokenPrice {
            pairs.append("ip=\(inputTokenPrice)")
        }
        if let minimumDeposit {
            pairs.append("md=\(minimumDeposit)")
        }
        return Self.compactPrefix + pairs.joined(separator: "&")
    }

    private static func decodeCompactString(_ body: String) -> CashuPaymentRequestEnvelope? {
        let map = parseCompactMap(body)
        guard let paymentID = map["p"], !paymentID.isEmpty else { return nil }
        guard let requestID = map["r"], !requestID.isEmpty else { return nil }
        guard let mintEncoded = map["m"],
              let mintData = Data(base64URLEncoded: mintEncoded),
              let mintURL = String(data: mintData, encoding: .utf8),
              !mintURL.isEmpty else { return nil }
        guard let unit = map["u"], !unit.isEmpty else { return nil }
        guard let amountRaw = map["a"], let amount = UInt64(amountRaw) else { return nil }
        guard let expiresRaw = map["e"], let expiresAtMs = UInt64(expiresRaw) else { return nil }

        let settlementMode: AgentSettlementMode
        switch map["s"] {
        case "f":
            settlementMode = .offlineAccepted
        default:
            settlementMode = .onlineRequired
        }

        let requiresLocking: AgentPaymentLockingMode?
        switch map["l"] {
        case "p":
            requiresLocking = .p2pk
        default:
            requiresLocking = .none
        }

        let pricingModel: AgentPaymentPriceModel?
        switch map["pm"] {
        case "t":
            pricingModel = .perToken
        case "r":
            pricingModel = .perRequest
        default:
            pricingModel = nil
        }

        let sessionID: String?
        if let encodedSession = map["q"],
           let sessionData = Data(base64URLEncoded: encodedSession),
           let decodedSession = String(data: sessionData, encoding: .utf8),
           !decodedSession.isEmpty {
            sessionID = decodedSession
        } else {
            sessionID = nil
        }

        return CashuPaymentRequestEnvelope(
            version: 2,
            paymentID: paymentID,
            requestID: requestID,
            mintURL: mintURL,
            unit: unit,
            amount: amount,
            expiresAtMs: expiresAtMs,
            settlementMode: settlementMode,
            sessionID: sessionID,
            requiresLocking: requiresLocking,
            lockPubkey: map["k"],
            lockSigFlag: map["f"].flatMap(UInt8.init),
            pricingModel: pricingModel,
            trancheIndex: map["ti"].flatMap(UInt32.init),
            trancheCount: map["tc"].flatMap(UInt32.init),
            trancheTokenCount: map["tt"].flatMap(UInt32.init),
            outputTokenPrice: map["op"].flatMap(UInt64.init),
            inputTokenPrice: map["ip"].flatMap(UInt64.init),
            minimumDeposit: map["md"].flatMap(UInt64.init)
        )
    }
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

struct CashuPaymentPayloadEnvelope: Codable, Equatable {
    let paymentID: String
    let requestID: String
    let mintURL: String
    let unit: String
    let totalAmount: UInt64
    let proofs: [CashuProof]
    let token: String?
    let requiresLocking: AgentPaymentLockingMode?
    let lockPubkey: String?
    let nullifiers: [String]
    let clientNonce: String
    let createdAtMs: UInt64

    init(
        paymentID: String,
        requestID: String,
        mintURL: String,
        unit: String,
        totalAmount: UInt64,
        proofs: [CashuProof],
        token: String? = nil,
        requiresLocking: AgentPaymentLockingMode? = nil,
        lockPubkey: String? = nil,
        nullifiers: [String],
        clientNonce: String,
        createdAtMs: UInt64
    ) {
        self.paymentID = paymentID
        self.requestID = requestID
        self.mintURL = mintURL
        self.unit = unit
        self.totalAmount = totalAmount
        self.proofs = proofs
        self.token = token
        self.requiresLocking = requiresLocking
        self.lockPubkey = lockPubkey
        self.nullifiers = nullifiers
        self.clientNonce = clientNonce
        self.createdAtMs = createdAtMs
    }

    func toJSONString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSONString json: String) -> CashuPaymentPayloadEnvelope? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CashuPaymentPayloadEnvelope.self, from: data) else {
            return nil
        }
        return parsed
    }
}

enum CashuTokenParser {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b",
        options: [.caseInsensitive]
    )

    static func extractFirstTokenCandidate(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = normalizedExplicitSchemeToken(from: trimmed) {
            return direct
        }

        if let decoded = trimmed.removingPercentEncoding,
           let fromDecodedScheme = normalizedExplicitSchemeToken(from: decoded) {
            return fromDecodedScheme
        }

        let containsHardBreak = trimmed.contains("\n") || trimmed.contains("\r") || trimmed.contains("\t")
        if containsHardBreak {
            // Some copy/paste paths wrap long tokens across lines.
            let compacted = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            if let compactedScheme = normalizedExplicitSchemeToken(from: compacted) {
                return compactedScheme
            }
            if let compactedMatch = firstRegexMatch(in: compacted) {
                return compactedMatch
            }
        }

        if let match = firstRegexMatch(in: trimmed) {
            return match
        }

        if let decoded = trimmed.removingPercentEncoding,
           let match = firstRegexMatch(in: decoded) {
            return match
        }

        return nil
    }

    static func parseTokenString(_ token: String, fallbackUnit: String = "sat") -> [CashuMintProofBundle]? {
        guard let rawCandidate = extractFirstTokenCandidate(from: token) else { return nil }
        guard let normalized = normalizePrefix(rawCandidate) else { return nil }

        if normalized.hasPrefix("cashuB") {
            return parseCashuB(normalized, fallbackUnit: fallbackUnit)
        }

        guard normalized.hasPrefix("cashuA") else { return nil }
        let encoded = String(normalized.dropFirst("cashuA".count))
        guard let data = Data(base64URLEncoded: encoded),
              let envelope = try? JSONDecoder().decode(CashuTokenEnvelope.self, from: data) else {
            return nil
        }

        if let tokenEntries = envelope.token {
            let bundles = tokenEntries.map {
                CashuMintProofBundle(
                    mintURL: $0.mint,
                    unit: ($0.unit ?? envelope.unit ?? fallbackUnit).lowercased(),
                    proofs: $0.proofs
                )
            }
            return bundles.isEmpty ? nil : bundles
        }

        if let mint = envelope.mint, let proofs = envelope.proofs {
            return [CashuMintProofBundle(
                mintURL: mint,
                unit: (envelope.unit ?? fallbackUnit).lowercased(),
                proofs: proofs
            )]
        }

        return nil
    }

    private static func firstRegexMatch(in input: String) -> String? {
        let range = NSRange(location: 0, length: (input as NSString).length)
        guard let match = tokenPattern.firstMatch(in: input, options: [], range: range),
              let swiftRange = Range(match.range, in: input) else {
            return nil
        }
        return String(input[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedExplicitSchemeToken(from input: String) -> String? {
        let lower = input.lowercased()
        guard lower.hasPrefix("cashu:") else { return nil }
        let payload = String(input.dropFirst("cashu:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }
        if payload.hasPrefix("cashuA") || payload.hasPrefix("cashuB") {
            return payload
        }
        if let decoded = payload.removingPercentEncoding,
           (decoded.hasPrefix("cashuA") || decoded.hasPrefix("cashuB")) {
            return decoded
        }
        return nil
    }

    private static func normalizePrefix(_ token: String) -> String? {
        guard token.count >= 6 else { return nil }
        let prefix = String(token.prefix(6)).lowercased()
        let remainder = String(token.dropFirst(6))
        switch prefix {
        case "cashua":
            return "cashuA" + remainder
        case "cashub":
            return "cashuB" + remainder
        default:
            return nil
        }
    }

#if canImport(CashuDevKit)
    private static func parseCashuB(_ token: String, fallbackUnit: String) -> [CashuMintProofBundle]? {
        guard let decoded = try? Token.decode(encodedToken: token) else { return nil }
        guard let mintURL = (try? decoded.mintUrl().url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mintURL.isEmpty else {
            return nil
        }
        guard let proofs = try? decoded.proofsSimple(), !proofs.isEmpty else { return nil }

        let converted = proofs.map { proof in
            CashuProof(
                id: proof.keysetId,
                amount: proof.amount.value,
                secret: proof.secret,
                C: proof.c,
                witness: serializeWitness(proof.witness)
            )
        }

        let unit = mapCurrencyUnit(decoded.unit(), fallbackUnit: fallbackUnit).lowercased()
        return [CashuMintProofBundle(mintURL: mintURL, unit: unit, proofs: converted)]
    }

    private static func mapCurrencyUnit(_ unit: CurrencyUnit?, fallbackUnit: String) -> String {
        guard let unit else { return fallbackUnit }
        switch unit {
        case .sat:
            return "sat"
        case .msat:
            return "msat"
        case .usd:
            return "usd"
        case .eur:
            return "eur"
        case .auth:
            return "auth"
        case .custom(let value):
            return value
        }
    }

    private static func serializeWitness(_ witness: Witness?) -> String? {
        guard let witness else { return nil }
        switch witness {
        case .p2pk(let signatures):
            let object: [String: Any] = ["signatures": signatures]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let encoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return encoded
        case .htlc(let preimage, let signatures):
            var object: [String: Any] = ["preimage": preimage]
            if let signatures {
                object["signatures"] = signatures
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let encoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return encoded
        }
    }
#else
    private static func parseCashuB(_ token: String, fallbackUnit: String) -> [CashuMintProofBundle]? {
        _ = token
        _ = fallbackUnit
        return nil
    }
#endif

    static func exportTokenString(mintURL: String, unit: String, proofs: [CashuProof]) -> String? {
        let envelope = CashuTokenEnvelope(
            token: [CashuTokenEntry(mint: mintURL, proofs: proofs, unit: unit)],
            mint: nil,
            unit: unit,
            proofs: nil
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return "cashuA" + data.base64URLEncodedString()
    }
}

func cashuNullifier(mintURL: String, unit: String, secret: String) -> String {
    let material = "\(mintURL)|\(unit)|\(secret)"
    return material.data(using: .utf8)?.sha256Hash().hexEncodedString() ?? UUID().uuidString
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
