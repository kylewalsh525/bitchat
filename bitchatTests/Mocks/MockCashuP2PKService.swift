import Foundation
@testable import bitchat

final class MockCashuP2PKService: CashuP2PKServicing {
    var validateBehavior: (CashuPaymentPayloadEnvelope, String) throws -> Bool = { _, _ in true }
    var signBehavior: ([CashuProof], String) throws -> [CashuProof] = { proofs, _ in proofs }
    var relockShouldSucceedWhenProofsPresent: Bool = true

    private struct RelockBody: Decodable {
        let proofs: [CashuProof]
    }

    func relockProofsDirect(
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8
    ) async throws -> CashuP2PKService.RelockResult {
        _ = mintURL
        _ = unit
        _ = lockSigFlag
        let token = "p2pk:\(lockPubkey)"
        return CashuP2PKService.RelockResult(proofs: proofs, token: token)
    }

    func relockProofsViaGateway(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8,
        sendProxyRequest: @Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket
    ) async throws -> CashuP2PKService.RelockResult {
        _ = requestID
        _ = paymentID
        _ = mintURL
        _ = unit
        _ = lockSigFlag
        _ = sendProxyRequest
        let token = "p2pk:\(lockPubkey)"
        return CashuP2PKService.RelockResult(proofs: proofs, token: token)
    }

    func validatePayloadLock(payloadEnvelope: CashuPaymentPayloadEnvelope, expectedLockPubkey: String) throws -> Bool {
        try validateBehavior(payloadEnvelope, expectedLockPubkey)
    }

    func signProofsForSpend(proofs: [CashuProof], secretHex: String) throws -> [CashuProof] {
        try signBehavior(proofs, secretHex)
    }

    func executeRelockGatewayRequest(_ request: MintProxyRequestPacket) async -> MintProxyResponsePacket {
        guard let data = request.body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RelockBody.self, from: data) else {
            return MintProxyResponsePacket(proxyID: request.proxyID, ok: false, body: nil, error: "invalid relock body")
        }
        guard !decoded.proofs.isEmpty else {
            return MintProxyResponsePacket(proxyID: request.proxyID, ok: false, body: nil, error: "no proofs")
        }
        guard relockShouldSucceedWhenProofsPresent else {
            return MintProxyResponsePacket(proxyID: request.proxyID, ok: false, body: nil, error: "relock failed")
        }

        let body = "{\"proofs\":\(String(data: (try? JSONEncoder().encode(decoded.proofs)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"),\"token\":\"p2pk:stub\"}"
        return MintProxyResponsePacket(proxyID: request.proxyID, ok: true, body: body, error: nil)
    }
}
