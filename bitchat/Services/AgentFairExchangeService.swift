import Foundation
import CryptoKit
import Security

enum AgentFairExchangeError: LocalizedError, Equatable {
    case invalidFormat
    case invalidEnvelope
    case invalidUnlock
    case requestMismatch
    case paymentMismatch
    case sessionMismatch
    case commitmentMismatch
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "invalid fair-exchange payload format"
        case .invalidEnvelope:
            return "invalid encrypted response envelope"
        case .invalidUnlock:
            return "invalid fair-exchange unlock token"
        case .requestMismatch:
            return "fair-exchange request mismatch"
        case .paymentMismatch:
            return "fair-exchange payment mismatch"
        case .sessionMismatch:
            return "fair-exchange session mismatch"
        case .commitmentMismatch:
            return "fair-exchange commitment mismatch"
        case .decryptFailed:
            return "failed to decrypt fair-exchange response"
        }
    }
}

struct AgentFairExchangePreparedOffer {
    let offer: String
    let unlockToken: String
    let commitment: String
}

struct AgentFairExchangeOfferEnvelope: Codable, Equatable {
    let version: UInt8
    let requestID: String
    let paymentID: String
    let sessionID: String?
    let algorithm: String
    let ciphertext: String
    let commitment: String
}

struct AgentFairExchangeUnlockEnvelope: Codable, Equatable {
    let version: UInt8
    let requestID: String
    let paymentID: String
    let sessionID: String?
    let key: String
    let commitment: String
}

final class AgentFairExchangeService {
    static let offerPrefix = "aoffer1:"
    static let unlockPrefix = "aunlock1:"
    static let chunkPrefix = "afex1:"
    private static let algorithm = "chacha20poly1305"
    private static let keyLengthBytes = 32
    private static let nonceLengthBytes = 12

    func prepareOffer(
        plaintext: String,
        requestID: String,
        paymentID: String,
        sessionID: String?
    ) throws -> AgentFairExchangePreparedOffer {
        let keyData = try randomBytes(count: Self.keyLengthBytes)
        let nonceData = try randomBytes(count: Self.nonceLengthBytes)
        let key = SymmetricKey(data: keyData)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let plaintextData = Data(plaintext.utf8)
        let aad = aadData(requestID: requestID, paymentID: paymentID, sessionID: sessionID)

        let sealed = try ChaChaPoly.seal(plaintextData, using: key, nonce: nonce, authenticating: aad)
        let combined = sealed.combined

        let commitment = combined.sha256Fingerprint()
        let offerEnvelope = AgentFairExchangeOfferEnvelope(
            version: 1,
            requestID: requestID,
            paymentID: paymentID,
            sessionID: sessionID,
            algorithm: Self.algorithm,
            ciphertext: combined.base64EncodedString(),
            commitment: commitment
        )
        let unlockEnvelope = AgentFairExchangeUnlockEnvelope(
            version: 1,
            requestID: requestID,
            paymentID: paymentID,
            sessionID: sessionID,
            key: keyData.base64EncodedString(),
            commitment: commitment
        )

        let offer = try encodeEnvelope(offerEnvelope, prefix: Self.offerPrefix)
        let unlock = try encodeEnvelope(unlockEnvelope, prefix: Self.unlockPrefix)
        return AgentFairExchangePreparedOffer(offer: offer, unlockToken: unlock, commitment: commitment)
    }

    func decrypt(
        offer: String,
        unlockToken: String,
        requestID: String,
        paymentID: String,
        sessionID: String?
    ) throws -> String {
        let offerEnvelope: AgentFairExchangeOfferEnvelope = try decodeEnvelope(offer, prefix: Self.offerPrefix)
        let unlockEnvelope: AgentFairExchangeUnlockEnvelope = try decodeEnvelope(unlockToken, prefix: Self.unlockPrefix)

        guard offerEnvelope.requestID == requestID, unlockEnvelope.requestID == requestID else {
            throw AgentFairExchangeError.requestMismatch
        }
        guard offerEnvelope.paymentID == paymentID, unlockEnvelope.paymentID == paymentID else {
            throw AgentFairExchangeError.paymentMismatch
        }
        if offerEnvelope.sessionID != sessionID || unlockEnvelope.sessionID != sessionID {
            throw AgentFairExchangeError.sessionMismatch
        }

        guard offerEnvelope.algorithm == Self.algorithm else {
            throw AgentFairExchangeError.invalidEnvelope
        }
        guard offerEnvelope.commitment == unlockEnvelope.commitment else {
            throw AgentFairExchangeError.commitmentMismatch
        }

        guard let ciphertext = Data(base64Encoded: offerEnvelope.ciphertext),
              let keyData = Data(base64Encoded: unlockEnvelope.key),
              keyData.count == Self.keyLengthBytes else {
            throw AgentFairExchangeError.invalidEnvelope
        }

        guard ciphertext.sha256Fingerprint() == offerEnvelope.commitment else {
            throw AgentFairExchangeError.commitmentMismatch
        }

        let key = SymmetricKey(data: keyData)
        let aad = aadData(requestID: requestID, paymentID: paymentID, sessionID: sessionID)
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(combined: ciphertext)
        } catch {
            throw AgentFairExchangeError.invalidEnvelope
        }

        let plaintextData: Data
        do {
            plaintextData = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw AgentFairExchangeError.decryptFailed
        }
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw AgentFairExchangeError.decryptFailed
        }
        return plaintext
    }

    func chunkedOfferSegments(_ offer: String, maxPacketBytes: Int) -> [String] {
        let prefixBytes = Self.chunkPrefix.lengthOfBytes(using: .utf8)
        let maxChunkBytes = max(1, maxPacketBytes - prefixBytes)
        let chunks = AgentMeshChunker.chunk(text: offer, maxBytes: maxChunkBytes)
        return chunks.map { Self.chunkPrefix + $0 }
    }

    func extractOfferChunkPayload(from chunkContent: String) -> String? {
        guard chunkContent.hasPrefix(Self.chunkPrefix) else { return nil }
        return String(chunkContent.dropFirst(Self.chunkPrefix.count))
    }

    func decodeOfferIfPresent(_ offer: String) -> AgentFairExchangeOfferEnvelope? {
        try? decodeEnvelope(offer, prefix: Self.offerPrefix) as AgentFairExchangeOfferEnvelope
    }

    private func aadData(requestID: String, paymentID: String, sessionID: String?) -> Data {
        let material = "\(requestID)|\(paymentID)|\(sessionID ?? "-")"
        return Data(material.utf8)
    }

    private func encodeEnvelope<T: Encodable>(_ value: T, prefix: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return prefix + data.base64EncodedString()
    }

    private func decodeEnvelope<T: Decodable>(_ value: String, prefix: String) throws -> T {
        guard value.hasPrefix(prefix) else { throw AgentFairExchangeError.invalidFormat }
        let encoded = String(value.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded) else {
            throw AgentFairExchangeError.invalidFormat
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AgentFairExchangeError.invalidEnvelope
        }
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AgentFairExchangeError.invalidUnlock
        }
        return data
    }
}
