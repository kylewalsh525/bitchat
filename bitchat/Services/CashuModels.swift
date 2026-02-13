import Foundation

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
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64URLEncodedString()
    }

    static func decode(from string: String) -> CashuPaymentRequestEnvelope? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func parseTokenString(_ token: String, fallbackUnit: String = "sat") -> [CashuMintProofBundle]? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if trimmed.hasPrefix("cashu:") {
            normalized = String(trimmed.dropFirst("cashu:".count))
        } else {
            normalized = trimmed
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
