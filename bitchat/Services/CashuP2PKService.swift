import Foundation

#if canImport(CashuDevKit)
import CashuDevKit
#endif

final class CashuP2PKService {
    struct RelockResult: Equatable {
        let proofs: [CashuProof]
        let token: String?
    }

    enum P2PKError: LocalizedError {
        case cdkUnavailable
        case invalidProof
        case unsupportedUnit
        case relockFailed
        case invalidGatewayResponse
        case missingToken
        case lockMismatch
        case missingLockPubkey

        var errorDescription: String? {
            switch self {
            case .cdkUnavailable:
                return "cashu dev kit is unavailable"
            case .invalidProof:
                return "invalid proof format"
            case .unsupportedUnit:
                return "unsupported currency unit for p2pk relock"
            case .relockFailed:
                return "failed to relock proofs"
            case .invalidGatewayResponse:
                return "invalid relock response from gateway"
            case .missingToken:
                return "missing lock token"
            case .lockMismatch:
                return "payment proofs are not locked to provider key"
            case .missingLockPubkey:
                return "missing lock pubkey"
            }
        }
    }

    private struct RelockGatewayRequestBody: Codable {
        let requestID: String
        let paymentID: String
        let mintURL: String
        let unit: String
        let lockPubkey: String
        let lockSigFlag: UInt8
        let proofs: [CashuProof]
    }

    private struct RelockGatewayResponseBody: Codable {
        let proofs: [CashuProof]
        let token: String?
    }

    func relockProofsDirect(
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8 = 1
    ) async throws -> RelockResult {
        #if canImport(CashuDevKit)
        let wallet = try buildWallet(mintURL: mintURL, unit: unit)
        let inputProofs = try proofs.map(convertToCDKProof)
        let spendingConditions = SpendingConditions.p2pk(
            pubkey: lockPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            conditions: Conditions(
                locktime: nil,
                pubkeys: [],
                refundKeys: [],
                numSigs: nil,
                sigFlag: lockSigFlag == 0 ? 0 : 1,
                numSigsRefund: nil
            )
        )

        guard let swapped = try await wallet.swap(
            amount: nil,
            amountSplitTarget: .none,
            inputProofs: inputProofs,
            spendingConditions: spendingConditions,
            includeFees: true
        ), !swapped.isEmpty else {
            throw P2PKError.relockFailed
        }

        let relockedProofs = swapped.map(convertFromCDKProof)
        let token = CashuTokenParser.exportTokenString(mintURL: mintURL, unit: unit, proofs: relockedProofs)
        return RelockResult(proofs: relockedProofs, token: token)
        #else
        _ = mintURL
        _ = unit
        _ = proofs
        _ = lockPubkey
        _ = lockSigFlag
        throw P2PKError.cdkUnavailable
        #endif
    }

    func relockProofsViaGateway(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8 = 1,
        sendProxyRequest: @Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket
    ) async throws -> RelockResult {
        let payload = RelockGatewayRequestBody(
            requestID: requestID,
            paymentID: paymentID,
            mintURL: mintURL,
            unit: unit,
            lockPubkey: lockPubkey,
            lockSigFlag: lockSigFlag == 0 ? 0 : 1,
            proofs: proofs
        )
        guard let bodyData = try? JSONEncoder().encode(payload),
              let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw P2PKError.invalidProof
        }

        let canonical = "relock|\(requestID)|\(paymentID)|\(mintURL.lowercased())|\(unit.lowercased())|\(lockPubkey.lowercased())|\(bodyData.sha256Fingerprint())"
        let digest = Data(canonical.utf8).sha256Fingerprint()
        let request = MintProxyRequestPacket(
            proxyID: "proxy-relock-\(String(digest.prefix(24)))",
            mintURL: mintURL,
            method: .relock,
            body: bodyString,
            sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        let response = try await sendProxyRequest(request)
        guard response.ok,
              let responseBody = response.body,
              let responseData = responseBody.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RelockGatewayResponseBody.self, from: responseData) else {
            throw P2PKError.invalidGatewayResponse
        }
        guard let token = decoded.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw P2PKError.invalidGatewayResponse
        }

        let result = RelockResult(proofs: decoded.proofs, token: token)

        _ = try validatePayloadLock(
            payloadEnvelope: CashuPaymentPayloadEnvelope(
                paymentID: paymentID,
                requestID: requestID,
                mintURL: mintURL,
                unit: unit,
                totalAmount: decoded.proofs.reduce(0) { $0 + $1.amount },
                proofs: decoded.proofs,
                token: token,
                requiresLocking: .p2pk,
                lockPubkey: lockPubkey,
                nullifiers: decoded.proofs.map { cashuNullifier(mintURL: mintURL, unit: unit, secret: $0.secret) },
                clientNonce: "gateway-relock",
                createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000)
            ),
            expectedLockPubkey: lockPubkey
        )

        return result
    }

    func validatePayloadLock(
        payloadEnvelope: CashuPaymentPayloadEnvelope,
        expectedLockPubkey: String
    ) throws -> Bool {
        #if canImport(CashuDevKit)
        let expected = expectedLockPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else {
            throw P2PKError.missingLockPubkey
        }

        let tokenString: String
        if let token = payloadEnvelope.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            tokenString = token
        } else if let synthesized = CashuTokenParser.exportTokenString(
            mintURL: payloadEnvelope.mintURL,
            unit: payloadEnvelope.unit,
            proofs: payloadEnvelope.proofs
        ) {
            tokenString = synthesized
        } else {
            throw P2PKError.missingToken
        }

        guard let token = try? Token.decode(encodedToken: tokenString) else {
            throw P2PKError.missingToken
        }
        let lockPubkeys = Set(token.p2pkPubkeys().map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard lockPubkeys.contains(expected) else {
            throw P2PKError.lockMismatch
        }
        return true
        #else
        _ = payloadEnvelope
        _ = expectedLockPubkey
        throw P2PKError.cdkUnavailable
        #endif
    }

    func signProofsForSpend(proofs: [CashuProof], secretHex: String) throws -> [CashuProof] {
        #if canImport(CashuDevKit)
        let trimmedSecret = secretHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedSecret.isEmpty else {
            throw P2PKError.invalidProof
        }

        return try proofs.map { proof in
            let cdkProof = try convertToCDKProof(proof)
            let signed = try proofSignP2pk(proof: cdkProof, secretKeyHex: trimmedSecret)
            return convertFromCDKProof(signed)
        }
        #else
        _ = proofs
        _ = secretHex
        throw P2PKError.cdkUnavailable
        #endif
    }

    func executeRelockGatewayRequest(_ request: MintProxyRequestPacket) async -> MintProxyResponsePacket {
        guard let bodyData = request.body.data(using: .utf8),
              let body = try? JSONDecoder().decode(RelockGatewayRequestBody.self, from: bodyData) else {
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: false,
                body: nil,
                error: P2PKError.invalidGatewayResponse.localizedDescription
            )
        }

        do {
            let result = try await relockProofsDirect(
                mintURL: body.mintURL,
                unit: body.unit,
                proofs: body.proofs,
                lockPubkey: body.lockPubkey,
                lockSigFlag: body.lockSigFlag
            )
            guard let token = result.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw P2PKError.invalidGatewayResponse
            }
            let encoded = RelockGatewayResponseBody(proofs: result.proofs, token: token)
            guard let responseData = try? JSONEncoder().encode(encoded),
                  let responseBody = String(data: responseData, encoding: .utf8) else {
                throw P2PKError.invalidGatewayResponse
            }
            return MintProxyResponsePacket(proxyID: request.proxyID, ok: true, body: responseBody, error: nil)
        } catch {
            return MintProxyResponsePacket(
                proxyID: request.proxyID,
                ok: false,
                body: nil,
                error: error.localizedDescription
            )
        }
    }
}

#if canImport(CashuDevKit)

private extension CashuP2PKService {
    func buildWallet(mintURL: String, unit: String) throws -> Wallet {
        let db = try WalletSqliteDatabase.newInMemory()
        let mnemonic = try generateMnemonic()
        return try Wallet(
            mintUrl: mintURL,
            unit: currencyUnit(for: unit),
            mnemonic: mnemonic,
            db: db,
            config: WalletConfig(targetProofCount: nil)
        )
    }

    func currencyUnit(for rawUnit: String) -> CurrencyUnit {
        switch rawUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sat":
            return .sat
        case "msat":
            return .msat
        case "usd":
            return .usd
        case "eur":
            return .eur
        default:
            return .custom(unit: rawUnit)
        }
    }

    func convertToCDKProof(_ proof: CashuProof) throws -> Proof {
        let keysetID = proof.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signature = proof.C?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !proof.secret.isEmpty,
              !keysetID.isEmpty,
              !signature.isEmpty else {
            throw P2PKError.invalidProof
        }

        return Proof(
            amount: Amount(value: proof.amount),
            secret: proof.secret,
            c: signature,
            keysetId: keysetID,
            witness: parseWitness(proof.witness),
            dleq: nil
        )
    }

    func convertFromCDKProof(_ proof: Proof) -> CashuProof {
        CashuProof(
            id: proof.keysetId,
            amount: proof.amount.value,
            secret: proof.secret,
            C: proof.c,
            witness: serializeWitness(proof.witness)
        )
    }

    func parseWitness(_ raw: String?) -> Witness? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let signatures = object["signatures"] as? [String] {
            return .p2pk(signatures: signatures)
        }

        if let preimage = object["preimage"] as? String {
            let signatures = object["signatures"] as? [String]
            return .htlc(preimage: preimage, signatures: signatures)
        }

        return nil
    }

    func serializeWitness(_ witness: Witness?) -> String? {
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
}

#endif

