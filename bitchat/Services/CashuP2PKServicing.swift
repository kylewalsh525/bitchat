import Foundation

protocol CashuP2PKServicing {
    func relockProofsDirect(
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8
    ) async throws -> CashuP2PKService.RelockResult

    func relockProofsViaGateway(
        requestID: String,
        paymentID: String,
        mintURL: String,
        unit: String,
        proofs: [CashuProof],
        lockPubkey: String,
        lockSigFlag: UInt8,
        sendProxyRequest: @Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket
    ) async throws -> CashuP2PKService.RelockResult

    func validatePayloadLock(payloadEnvelope: CashuPaymentPayloadEnvelope, expectedLockPubkey: String) throws -> Bool

    func signProofsForSpend(proofs: [CashuProof], secretHex: String) throws -> [CashuProof]

    func executeRelockGatewayRequest(_ request: MintProxyRequestPacket) async -> MintProxyResponsePacket
}

extension CashuP2PKService: CashuP2PKServicing {}
