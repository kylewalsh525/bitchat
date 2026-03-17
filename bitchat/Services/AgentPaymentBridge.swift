import Foundation
#if canImport(Security)
import Security
#endif

struct AgentOfflineRiskPolicy {
    let maxOfflinePerPeer: Int
    let maxOfflineOutstanding: Int

    static let `default` = AgentOfflineRiskPolicy(maxOfflinePerPeer: 2, maxOfflineOutstanding: 8)
}

struct AgentPaymentRequestMetadata {
    let amountOverride: UInt64?
    let pricingModel: AgentPaymentPriceModel?
    let trancheIndex: UInt32?
    let trancheCount: UInt32?
    let trancheTokenCount: UInt32?
    let outputTokenPrice: UInt64?
    let inputTokenPrice: UInt64?
    let minimumDeposit: UInt64?

    static let `default` = AgentPaymentRequestMetadata(
        amountOverride: nil,
        pricingModel: nil,
        trancheIndex: nil,
        trancheCount: nil,
        trancheTokenCount: nil,
        outputTokenPrice: nil,
        inputTokenPrice: nil,
        minimumDeposit: nil
    )
}

struct AgentPaymentEvaluation {
    let receipt: AgentPaymentReceiptPacket
    let shouldAdvanceFlow: Bool
}

struct AgentOfflineNotaryRequirement {
    let minimumReceipts: Int
    let timeoutMs: UInt64

    static let disabled = AgentOfflineNotaryRequirement(minimumReceipts: 0, timeoutMs: TransportConfig.notaryReceiptCollectTimeoutMs)
}

struct AgentOfflineNotaryCollectionContext {
    let requestID: String
    let paymentID: String
    let mintURL: String
    let unit: String
    let nullifiers: [String]
    let minimumReceipts: Int
    let timeoutMs: UInt64
}

final class AgentPaymentBridge {
    enum BridgeError: LocalizedError {
        case invalidPaymentRequest
        case invalidPaymentPayload
        case requestMismatch
        case sessionMismatch
        case paymentExpired
        case mintNotAccepted
        case insufficientPayment
        case replayDetected
        case paymentMismatch
        case duplicatePayment
        case offlinePolicyExceeded
        case notaryThresholdNotMet
        case missingLockPubkey
        case lockValidationFailed
        case lockSigningUnavailable
        case x402Disabled
        case invalidX402PaymentRequest
        case invalidX402PaymentPayload
        case x402SettlementFailed

        var errorDescription: String? {
            switch self {
            case .invalidPaymentRequest:
                return "invalid payment request"
            case .invalidPaymentPayload:
                return "invalid payment payload"
            case .requestMismatch:
                return "payment request does not match original request"
            case .sessionMismatch:
                return "payment session does not match request"
            case .paymentExpired:
                return "payment request expired"
            case .mintNotAccepted:
                return "mint not accepted"
            case .insufficientPayment:
                return "payment amount is below required price"
            case .replayDetected:
                return "payment replay detected"
            case .paymentMismatch:
                return "payment does not match request terms"
            case .duplicatePayment:
                return "payment payload already accepted"
            case .offlinePolicyExceeded:
                return "offline acceptance cap reached"
            case .notaryThresholdNotMet:
                return "offline notary receipt threshold not met"
            case .missingLockPubkey:
                return "lock-required payment request missing lock pubkey"
            case .lockValidationFailed:
                return "payment lock validation failed"
            case .lockSigningUnavailable:
                return "provider lock signing key unavailable"
            case .x402Disabled:
                return "x402 payments are disabled"
            case .invalidX402PaymentRequest:
                return "invalid x402 payment request"
            case .invalidX402PaymentPayload:
                return "invalid x402 payment payload"
            case .x402SettlementFailed:
                return "x402 settlement failed"
            }
        }
    }

    private let wallet: CashuWalletService
    private let mintClient: CashuMintClient
    private let store: AgentPaymentStore
    private let lockKeyStore: AgentPaymentLockKeyStore
    private let p2pkService: CashuP2PKServicing
    private let x402GatewayClient: X402GatewayClienting
    private let x402Wallet: X402GuestWalletPaying?

    init(
        wallet: CashuWalletService,
        mintClient: CashuMintClient,
        store: AgentPaymentStore,
        lockKeyStore: AgentPaymentLockKeyStore,
        p2pkService: CashuP2PKServicing = CashuP2PKService(),
        x402GatewayClient: X402GatewayClienting = X402GatewayClient(),
        x402Wallet: X402GuestWalletPaying? = nil
    ) {
        self.wallet = wallet
        self.mintClient = mintClient
        self.store = store
        self.lockKeyStore = lockKeyStore
        self.p2pkService = p2pkService
        self.x402GatewayClient = x402GatewayClient
        self.x402Wallet = x402Wallet
    }

    func createPaymentRequest(
        requestID: String,
        sessionID: String?,
        peerID: PeerID,
        terms: AgentPaymentTerms,
        metadata: AgentPaymentRequestMetadata = .default,
        enablePaymentLocking: Bool = true,
        enableX402Payments: Bool = false
    ) -> String? {
        guard let paymentTerms = terms.sanitized() else {
            return nil
        }
        let amount = metadata.amountOverride ?? defaultAmount(for: paymentTerms)
        guard amount > 0 else { return nil }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let expiresAtMs = nowMs + UInt64(paymentTerms.requestTTLSeconds) * 1000
        let paymentID = makePaymentID()
        switch paymentTerms.paymentRail {
        case .none:
            return nil
        case .cashu:
            guard let mintURL = selectPreferredMintURL(from: paymentTerms.acceptedMints) else { return nil }
            guard !mintURL.isEmpty else { return nil }

            lockKeyStore.pruneExpired(nowMs: nowMs, maxDeletes: 32)

            let requestedLocking = paymentTerms.requiresLocking ?? AgentPaymentLockingMode.none
            let lockMode: AgentPaymentLockingMode = enablePaymentLocking ? requestedLocking : .none
            var lockPubkey: String?
            let lockSigFlag: UInt8? = lockMode == .p2pk ? 1 : nil
            if lockMode == .p2pk {
                do {
                    let binding = try lockKeyStore.createLockBinding(
                        requestID: requestID,
                        paymentID: paymentID,
                        expiresAtMs: expiresAtMs
                    )
                    lockPubkey = binding.pubkeyHex
                } catch {
                    return nil
                }
            }

            let envelope = CashuPaymentRequestEnvelope(
                version: 1,
                paymentID: paymentID,
                requestID: requestID,
                mintURL: mintURL,
                unit: paymentTerms.unit,
                amount: amount,
                expiresAtMs: expiresAtMs,
                settlementMode: paymentTerms.settlementMode,
                sessionID: sessionID,
                requiresLocking: lockMode,
                lockPubkey: lockPubkey,
                lockSigFlag: lockSigFlag,
                pricingModel: metadata.pricingModel ?? paymentTerms.effectivePriceModel,
                trancheIndex: metadata.trancheIndex,
                trancheCount: metadata.trancheCount,
                trancheTokenCount: metadata.trancheTokenCount,
                outputTokenPrice: metadata.outputTokenPrice ?? paymentTerms.pricePerOutputToken,
                inputTokenPrice: metadata.inputTokenPrice ?? paymentTerms.pricePerInputToken,
                minimumDeposit: metadata.minimumDeposit ?? paymentTerms.minDeposit
            )

            guard let encoded = envelope.encodeString() else {
                if lockMode == .p2pk {
                    lockKeyStore.delete(requestID: requestID, paymentID: paymentID)
                }
                return nil
            }
            if encoded.utf8.count > AgentMeshConstants.maxTLVStringBytes {
                if lockMode == .p2pk {
                    lockKeyStore.delete(requestID: requestID, paymentID: paymentID)
                }
                return nil
            }
            let record = AgentPaymentRecord(
                requestID: requestID,
                sessionID: sessionID,
                peerID: peerID.id,
                paymentID: paymentID,
                rail: AgentPaymentRail.cashu.rawValue,
                mintURL: mintURL,
                unit: paymentTerms.unit,
                amount: amount,
                settlementMode: paymentTerms.settlementMode,
                requiresLocking: lockMode,
                lockPubkey: lockPubkey,
                lockSigFlag: lockSigFlag,
                paymentRequest: encoded,
                payload: nil,
                nullifiers: [],
                notaryReceipts: [],
                state: .paymentRequested,
                details: nil,
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                expiresAtMs: expiresAtMs
            )
            store.recordPaymentRequest(record)
            return encoded
        case .x402:
            guard enableX402Payments else { return nil }
            guard let chainID = paymentTerms.x402ChainID,
                  let tokenAddress = paymentTerms.x402TokenAddress,
                  let payTo = paymentTerms.x402PayTo,
                  let gatewayURL = paymentTerms.x402GatewayURL else {
                return nil
            }

            let envelope = X402PaymentRequestEnvelope(
                version: 1,
                paymentID: paymentID,
                requestID: requestID,
                amount: amount,
                unit: paymentTerms.unit,
                chainID: chainID,
                tokenAddress: tokenAddress,
                payTo: payTo,
                gatewayURL: gatewayURL,
                expiresAtMs: expiresAtMs,
                sessionID: sessionID,
                scheme: paymentTerms.x402Scheme ?? .exact,
                facilitatorID: paymentTerms.x402FacilitatorID ?? "thirdweb"
            )
            guard let encoded = envelope.encodeString() else { return nil }
            guard encoded.utf8.count <= AgentMeshConstants.maxTLVStringBytes else { return nil }
            let record = AgentPaymentRecord(
                requestID: requestID,
                sessionID: sessionID,
                peerID: peerID.id,
                paymentID: paymentID,
                rail: AgentPaymentRail.x402.rawValue,
                mintURL: gatewayURL,
                unit: paymentTerms.unit,
                amount: amount,
                settlementMode: .onlineRequired,
                requiresLocking: AgentPaymentLockingMode.none,
                lockPubkey: nil,
                lockSigFlag: nil,
                paymentRequest: encoded,
                payload: nil,
                nullifiers: [],
                notaryReceipts: [],
                state: .paymentRequested,
                details: nil,
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                expiresAtMs: expiresAtMs
            )
            store.recordPaymentRequest(record)
            return encoded
        }
    }

    func registerIncomingPaymentRequest(
        requestID: String,
        sessionID: String?,
        peerID: PeerID,
        paymentRequest: String
    ) {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) {
            let record = AgentPaymentRecord(
                requestID: requestID,
                sessionID: sessionID,
                peerID: peerID.id,
                paymentID: envelope.paymentID,
                rail: AgentPaymentRail.cashu.rawValue,
                mintURL: envelope.mintURL,
                unit: envelope.unit,
                amount: envelope.amount,
                settlementMode: envelope.settlementMode,
                requiresLocking: envelope.requiresLocking ?? AgentPaymentLockingMode.none,
                lockPubkey: envelope.lockPubkey,
                lockSigFlag: (envelope.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk ? (envelope.lockSigFlag ?? 1) : nil,
                paymentRequest: paymentRequest,
                payload: nil,
                nullifiers: [],
                notaryReceipts: [],
                state: .paymentRequested,
                details: nil,
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                expiresAtMs: envelope.expiresAtMs
            )
            store.recordPaymentRequest(record)
            return
        }

        if let envelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
            let record = AgentPaymentRecord(
                requestID: requestID,
                sessionID: sessionID,
                peerID: peerID.id,
                paymentID: envelope.paymentID,
                rail: AgentPaymentRail.x402.rawValue,
                mintURL: envelope.gatewayURL,
                unit: envelope.unit,
                amount: envelope.amount,
                settlementMode: .onlineRequired,
                requiresLocking: AgentPaymentLockingMode.none,
                lockPubkey: nil,
                lockSigFlag: nil,
                paymentRequest: paymentRequest,
                payload: nil,
                nullifiers: [],
                notaryReceipts: [],
                state: .paymentRequested,
                details: nil,
                createdAtMs: nowMs,
                updatedAtMs: nowMs,
                expiresAtMs: envelope.expiresAtMs
            )
            store.recordPaymentRequest(record)
        }
    }

    func prepareOutboundPaymentPayload(
        requestID: String,
        sessionID: String?,
        paymentRequest: String,
        enablePaymentLocking: Bool = true,
        enableX402Payments: Bool = false,
        allowGatewayRelockFallback: Bool = false,
        sendProxyRequest: (@Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket)? = nil
    ) async throws -> AgentPaymentPayloadPacket {
        if let envelope = X402PaymentRequestEnvelope.decode(from: paymentRequest) {
            guard enableX402Payments else {
                throw BridgeError.x402Disabled
            }
            guard envelope.requestID == requestID else {
                throw BridgeError.requestMismatch
            }
            if let expectedSessionID = envelope.sessionID,
               sessionID != expectedSessionID {
                throw BridgeError.sessionMismatch
            }
            guard let wallet = x402Wallet else {
                throw BridgeError.invalidX402PaymentRequest
            }

            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            guard nowMs < envelope.expiresAtMs else {
                throw BridgeError.paymentExpired
            }

            let clientNonce = UUID().uuidString
            let payment = try await wallet.payX402(
                gatewayURL: envelope.gatewayURL,
                paymentID: envelope.paymentID,
                requestID: envelope.requestID,
                amount: envelope.amount,
                chainID: envelope.chainID,
                tokenAddress: envelope.tokenAddress,
                payTo: envelope.payTo
            )

            let payloadEnvelope = X402PaymentPayloadEnvelope(
                paymentID: envelope.paymentID,
                requestID: envelope.requestID,
                paymentData: payment.paymentData,
                payerAddress: payment.payerAddress,
                clientNonce: clientNonce,
                createdAtMs: nowMs
            )
            guard let payload = payloadEnvelope.encodeString() else {
                throw BridgeError.invalidX402PaymentPayload
            }
            let paymentRef = x402PaymentRefHash(paymentID: envelope.paymentID, paymentData: payment.paymentData)
            store.markPayloadSent(requestID: requestID, payload: payload, nullifiers: [paymentRef])
            return AgentPaymentPayloadPacket(
                requestID: requestID,
                sessionID: sessionID,
                rail: AgentPaymentRail.x402.rawValue,
                payload: payload,
                sentAt: nowMs,
                clientNonce: clientNonce
            )
        }

        guard let envelope = CashuPaymentRequestEnvelope.decode(from: paymentRequest) else {
            throw BridgeError.invalidPaymentRequest
        }
        guard envelope.requestID == requestID else {
            throw BridgeError.requestMismatch
        }

        lockKeyStore.pruneExpired(maxDeletes: 32)

        let clientNonce = UUID().uuidString
        do {
            let preparedPayload = try wallet.preparePaymentPayload(request: envelope, clientNonce: clientNonce)
            var outboundPayload = preparedPayload
            let lockMode: AgentPaymentLockingMode = enablePaymentLocking ? (envelope.requiresLocking ?? AgentPaymentLockingMode.none) : .none

            if lockMode == .p2pk {
                guard let lockPubkey = envelope.lockPubkey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !lockPubkey.isEmpty else {
                    throw BridgeError.missingLockPubkey
                }

                let lockSigFlag = envelope.lockSigFlag ?? 1
                let relockResult: CashuP2PKService.RelockResult
                do {
                    relockResult = try await p2pkService.relockProofsDirect(
                        mintURL: envelope.mintURL,
                        unit: envelope.unit,
                        proofs: preparedPayload.proofs,
                        lockPubkey: lockPubkey,
                        lockSigFlag: lockSigFlag
                    )
                } catch {
                    if allowGatewayRelockFallback, let sendProxyRequest {
                        relockResult = try await p2pkService.relockProofsViaGateway(
                            requestID: envelope.requestID,
                            paymentID: envelope.paymentID,
                            mintURL: envelope.mintURL,
                            unit: envelope.unit,
                            proofs: preparedPayload.proofs,
                            lockPubkey: lockPubkey,
                            lockSigFlag: lockSigFlag,
                            sendProxyRequest: sendProxyRequest
                        )
                    } else {
                        throw error
                    }
                }

                wallet.replaceReserved(
                    paymentID: envelope.paymentID,
                    mintURL: envelope.mintURL,
                    unit: envelope.unit,
                    proofs: relockResult.proofs
                )

                let relockedNullifiers = relockResult.proofs.map {
                    cashuNullifier(mintURL: envelope.mintURL, unit: envelope.unit, secret: $0.secret)
                }
                outboundPayload = CashuPaymentPayloadEnvelope(
                    paymentID: preparedPayload.paymentID,
                    requestID: preparedPayload.requestID,
                    mintURL: preparedPayload.mintURL,
                    unit: preparedPayload.unit,
                    totalAmount: relockResult.proofs.reduce(0) { $0 + $1.amount },
                    proofs: relockResult.proofs,
                    token: relockResult.token,
                    requiresLocking: .p2pk,
                    lockPubkey: lockPubkey,
                    nullifiers: relockedNullifiers,
                    clientNonce: preparedPayload.clientNonce,
                    createdAtMs: preparedPayload.createdAtMs
                )
            } else {
                outboundPayload = CashuPaymentPayloadEnvelope(
                    paymentID: preparedPayload.paymentID,
                    requestID: preparedPayload.requestID,
                    mintURL: preparedPayload.mintURL,
                    unit: preparedPayload.unit,
                    totalAmount: preparedPayload.totalAmount,
                    proofs: preparedPayload.proofs,
                    token: preparedPayload.token,
                    requiresLocking: lockMode,
                    lockPubkey: nil,
                    nullifiers: preparedPayload.nullifiers,
                    clientNonce: preparedPayload.clientNonce,
                    createdAtMs: preparedPayload.createdAtMs
                )
            }

            guard let payloadJSON = outboundPayload.toJSONString() else {
                throw BridgeError.invalidPaymentPayload
            }

            store.markPayloadSent(requestID: requestID, payload: payloadJSON, nullifiers: outboundPayload.nullifiers)

            return AgentPaymentPayloadPacket(
                requestID: requestID,
                sessionID: sessionID,
                rail: "cashu",
                payload: payloadJSON,
                sentAt: UInt64(Date().timeIntervalSince1970 * 1000),
                clientNonce: clientNonce
            )
        } catch {
            wallet.rollbackReserved(paymentID: envelope.paymentID)
            throw error
        }
    }

    func applyReceipt(_ receipt: AgentPaymentReceiptPacket) {
        guard let record = store.record(for: receipt.requestID) else {
            if let paymentID = receipt.paymentID {
                if receipt.status == .rejected {
                    wallet.rollbackReserved(paymentID: paymentID)
                } else {
                    wallet.commitReserved(paymentID: paymentID)
                }
            }
            return
        }

        let receiptPaymentID = receipt.paymentID ?? record.paymentID
        if receipt.status == .rejected {
            if shouldCommitReservedOnRejection(details: receipt.details) {
                wallet.commitReserved(paymentID: receiptPaymentID)
            } else {
                wallet.rollbackReserved(paymentID: receiptPaymentID)
            }
        } else {
            wallet.commitReserved(paymentID: receiptPaymentID)
        }

        // Ignore stale receipts that do not match the active request payment.
        if let paymentID = receipt.paymentID, paymentID != record.paymentID {
            return
        }

        store.markReceipt(
            requestID: receipt.requestID,
            status: receipt.status,
            details: receipt.details,
            nullifiers: receipt.nullifiers,
            notaryReceipts: receipt.notaryReceipts
        )
    }

    func evaluateIncomingPaymentDetailed(
        packet: AgentPaymentPayloadPacket,
        from peerID: PeerID,
        terms: AgentPaymentTerms,
        enablePaymentLocking: Bool = true,
        enableX402Payments: Bool = false,
        x402GatewayToken: String? = nil,
        offlinePolicy: AgentOfflineRiskPolicy = .default,
        notaryRequirement: AgentOfflineNotaryRequirement = .disabled,
        collectNotaryReceipts: ((AgentOfflineNotaryCollectionContext) async -> [String])? = nil
    ) async -> AgentPaymentEvaluation {
        _ = terms // Keep call-site compatibility while enforcing stored request terms.
        let rail = AgentPaymentRail(rawValue: packet.rail.lowercased()) ?? .none
        if rail == .x402 {
            return await evaluateIncomingX402Payment(
                packet: packet,
                from: peerID,
                enableX402Payments: enableX402Payments,
                x402GatewayToken: x402GatewayToken
            )
        }

        guard rail == .cashu,
              let payloadEnvelope = CashuPaymentPayloadEnvelope.decode(fromJSONString: packet.payload) else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: nil,
                status: .rejected,
                details: BridgeError.invalidPaymentPayload.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        guard payloadEnvelope.requestID == packet.requestID else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.requestMismatch.localizedDescription,
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        guard let record = store.record(for: packet.requestID) else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: "unknown payment request",
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        lockKeyStore.pruneExpired(maxDeletes: 32)

        let reject: (_ details: String?, _ nullifiers: [String]) -> AgentPaymentEvaluation = { details, nullifiers in
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: details,
                nullifiers: nullifiers,
                notaryReceipts: []
            )
            if record.paymentID == payloadEnvelope.paymentID {
                self.store.markReceipt(
                    requestID: packet.requestID,
                    status: .rejected,
                    details: details,
                    nullifiers: nullifiers
                )
                if enablePaymentLocking, (record.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk {
                    self.lockKeyStore.delete(requestID: record.requestID, paymentID: record.paymentID)
                }
            }
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard nowMs < record.expiresAtMs else {
            return reject(BridgeError.paymentExpired.localizedDescription, payloadEnvelope.nullifiers)
        }

        if record.sessionID != packet.sessionID {
            return reject(BridgeError.sessionMismatch.localizedDescription, payloadEnvelope.nullifiers)
        }

        let validated = store.validateIncomingPayload(
            requestID: packet.requestID,
            paymentID: payloadEnvelope.paymentID,
            nullifiers: payloadEnvelope.nullifiers
        )
        switch validated {
        case .duplicateForRequest:
            if let existing = store.record(for: packet.requestID) {
                if let existingStatus = receiptStatus(for: existing.state) {
                    let receipt = AgentPaymentReceiptPacket(
                        requestID: packet.requestID,
                        sessionID: existing.sessionID ?? packet.sessionID,
                        paymentID: payloadEnvelope.paymentID,
                        status: existingStatus,
                        details: existing.details ?? "duplicate payload; returning existing receipt",
                        nullifiers: existing.nullifiers.isEmpty ? payloadEnvelope.nullifiers : existing.nullifiers,
                        notaryReceipts: existing.notaryReceipts
                    )
                    return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
                }
            }
            return reject(BridgeError.duplicatePayment.localizedDescription, payloadEnvelope.nullifiers)
        case .replayAcrossRequests:
            return reject(BridgeError.replayDetected.localizedDescription, payloadEnvelope.nullifiers)
        case .paymentMismatch:
            return reject(BridgeError.paymentMismatch.localizedDescription, payloadEnvelope.nullifiers)
        case .accepted:
            break
        }

        guard payloadEnvelope.mintURL == record.mintURL else {
            return reject(BridgeError.paymentMismatch.localizedDescription, payloadEnvelope.nullifiers)
        }

        guard payloadEnvelope.unit.lowercased() == record.unit.lowercased() else {
            return reject(BridgeError.paymentMismatch.localizedDescription, payloadEnvelope.nullifiers)
        }

        guard payloadEnvelope.totalAmount >= record.amount else {
            return reject(BridgeError.insufficientPayment.localizedDescription, payloadEnvelope.nullifiers)
        }

        let lockingRequired = enablePaymentLocking && (record.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk
        let expectedLockPubkey = record.lockPubkey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if lockingRequired {
            guard !expectedLockPubkey.isEmpty else {
                return reject(BridgeError.missingLockPubkey.localizedDescription, payloadEnvelope.nullifiers)
            }
            guard payloadEnvelope.requiresLocking == .p2pk else {
                return reject(BridgeError.lockValidationFailed.localizedDescription, payloadEnvelope.nullifiers)
            }
            guard let token = payloadEnvelope.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                return reject(BridgeError.lockValidationFailed.localizedDescription, payloadEnvelope.nullifiers)
            }
            guard payloadEnvelope.lockPubkey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedLockPubkey else {
                return reject(BridgeError.lockValidationFailed.localizedDescription, payloadEnvelope.nullifiers)
            }
            do {
                _ = try p2pkService.validatePayloadLock(
                    payloadEnvelope: CashuPaymentPayloadEnvelope(
                        paymentID: payloadEnvelope.paymentID,
                        requestID: payloadEnvelope.requestID,
                        mintURL: payloadEnvelope.mintURL,
                        unit: payloadEnvelope.unit,
                        totalAmount: payloadEnvelope.totalAmount,
                        proofs: payloadEnvelope.proofs,
                        token: token,
                        requiresLocking: payloadEnvelope.requiresLocking,
                        lockPubkey: payloadEnvelope.lockPubkey,
                        nullifiers: payloadEnvelope.nullifiers,
                        clientNonce: payloadEnvelope.clientNonce,
                        createdAtMs: payloadEnvelope.createdAtMs
                    ),
                    expectedLockPubkey: expectedLockPubkey
                )
            } catch {
                return reject(error.localizedDescription, payloadEnvelope.nullifiers)
            }
        }

        // Persist the raw payload so offline-accepted receipts can be finalized later.
        store.cacheIncomingPayload(
            requestID: packet.requestID,
            payload: packet.payload,
            nullifiers: payloadEnvelope.nullifiers
        )

        let outboundForSwap: CashuPaymentPayloadEnvelope
        if lockingRequired {
            guard let secretHex = lockKeyStore.loadSecret(
                requestID: record.requestID,
                paymentID: record.paymentID
            ) else {
                return reject(BridgeError.lockSigningUnavailable.localizedDescription, payloadEnvelope.nullifiers)
            }
            do {
                let signedProofs = try p2pkService.signProofsForSpend(
                    proofs: payloadEnvelope.proofs,
                    secretHex: secretHex
                )
                outboundForSwap = CashuPaymentPayloadEnvelope(
                    paymentID: payloadEnvelope.paymentID,
                    requestID: payloadEnvelope.requestID,
                    mintURL: payloadEnvelope.mintURL,
                    unit: payloadEnvelope.unit,
                    totalAmount: payloadEnvelope.totalAmount,
                    proofs: signedProofs,
                    token: payloadEnvelope.token,
                    requiresLocking: payloadEnvelope.requiresLocking,
                    lockPubkey: payloadEnvelope.lockPubkey,
                    nullifiers: payloadEnvelope.nullifiers,
                    clientNonce: payloadEnvelope.clientNonce,
                    createdAtMs: payloadEnvelope.createdAtMs
                )
            } catch {
                return reject(error.localizedDescription, payloadEnvelope.nullifiers)
            }
        } else {
            outboundForSwap = payloadEnvelope
        }

        do {
            try await mintClient.swap(mintURL: outboundForSwap.mintURL, payload: outboundForSwap)
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .finalizedOnline,
                details: "settled with mint",
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: []
            )
            store.markReceipt(
                requestID: packet.requestID,
                status: .finalizedOnline,
                details: receipt.details,
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: []
            )
            if lockingRequired {
                lockKeyStore.delete(requestID: record.requestID, paymentID: record.paymentID)
            }
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: true)
        } catch {
            let swapFailure = mintSwapFailureMessage(error, mintURL: outboundForSwap.mintURL)
            guard record.settlementMode == .offlineAccepted else {
                return reject(swapFailure, payloadEnvelope.nullifiers)
            }

            let peerOutstanding = store.offlineOutstandingCount(for: peerID.id)
            let totalOutstanding = store.offlineOutstandingCount()
            guard peerOutstanding < offlinePolicy.maxOfflinePerPeer,
                  totalOutstanding < offlinePolicy.maxOfflineOutstanding else {
                return reject(BridgeError.offlinePolicyExceeded.localizedDescription, payloadEnvelope.nullifiers)
            }

            let requiredNotaryCount = max(0, min(notaryRequirement.minimumReceipts, TransportConfig.notaryRequiredSignatureMax))
            var notaryReceipts: [String] = []
            if requiredNotaryCount > 0 {
                guard let collectNotaryReceipts else {
                    return reject(BridgeError.notaryThresholdNotMet.localizedDescription, payloadEnvelope.nullifiers)
                }
                let context = AgentOfflineNotaryCollectionContext(
                    requestID: packet.requestID,
                    paymentID: payloadEnvelope.paymentID,
                    mintURL: payloadEnvelope.mintURL,
                    unit: payloadEnvelope.unit,
                    nullifiers: payloadEnvelope.nullifiers,
                    minimumReceipts: requiredNotaryCount,
                    timeoutMs: max(1, notaryRequirement.timeoutMs)
                )
                notaryReceipts = await collectNotaryReceipts(context)
                if notaryReceipts.count < requiredNotaryCount {
                    let details = "offline notary receipts \(notaryReceipts.count)/\(requiredNotaryCount)"
                    return reject(details, payloadEnvelope.nullifiers)
                }
            }

            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .acceptedOffline,
                details: "accepted offline; pending mint finalization",
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: notaryReceipts
            )
            store.markReceipt(
                requestID: packet.requestID,
                status: .acceptedOffline,
                details: receipt.details,
                nullifiers: payloadEnvelope.nullifiers,
                notaryReceipts: notaryReceipts
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: true)
        }
    }

    func evaluateIncomingPayment(
        packet: AgentPaymentPayloadPacket,
        from peerID: PeerID,
        terms: AgentPaymentTerms,
        enablePaymentLocking: Bool = true,
        enableX402Payments: Bool = false,
        x402GatewayToken: String? = nil,
        offlinePolicy: AgentOfflineRiskPolicy = .default,
        notaryRequirement: AgentOfflineNotaryRequirement = .disabled,
        collectNotaryReceipts: ((AgentOfflineNotaryCollectionContext) async -> [String])? = nil
    ) async -> AgentPaymentReceiptPacket {
        let evaluation = await evaluateIncomingPaymentDetailed(
            packet: packet,
            from: peerID,
            terms: terms,
            enablePaymentLocking: enablePaymentLocking,
            enableX402Payments: enableX402Payments,
            x402GatewayToken: x402GatewayToken,
            offlinePolicy: offlinePolicy,
            notaryRequirement: notaryRequirement,
            collectNotaryReceipts: collectNotaryReceipts
        )
        return evaluation.receipt
    }

    private func evaluateIncomingX402Payment(
        packet: AgentPaymentPayloadPacket,
        from peerID: PeerID,
        enableX402Payments: Bool,
        x402GatewayToken: String?
    ) async -> AgentPaymentEvaluation {
        _ = peerID
        guard enableX402Payments else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: nil,
                status: .rejected,
                details: BridgeError.x402Disabled.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        guard let payloadEnvelope = X402PaymentPayloadEnvelope.decode(from: packet.payload) else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: nil,
                status: .rejected,
                details: BridgeError.invalidX402PaymentPayload.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        guard payloadEnvelope.requestID == packet.requestID else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.requestMismatch.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        guard let record = store.record(for: packet.requestID) else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: "unknown payment request",
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        guard record.rail.lowercased() == AgentPaymentRail.x402.rawValue else {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.paymentMismatch.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        if record.sessionID != packet.sessionID {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.sessionMismatch.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        if nowMs >= record.expiresAtMs {
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.paymentExpired.localizedDescription,
                nullifiers: [],
                notaryReceipts: []
            )
            store.markReceipt(
                requestID: packet.requestID,
                status: .rejected,
                details: BridgeError.paymentExpired.localizedDescription,
                nullifiers: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        let paymentRef = x402PaymentRefHash(paymentID: payloadEnvelope.paymentID, paymentData: payloadEnvelope.paymentData)
        let validation = store.validateIncomingPayload(
            requestID: packet.requestID,
            paymentID: payloadEnvelope.paymentID,
            nullifiers: [paymentRef]
        )
        switch validation {
        case .accepted:
            break
        case .duplicateForRequest:
            if let existing = store.record(for: packet.requestID),
               let existingStatus = receiptStatus(for: existing.state) {
                let receipt = AgentPaymentReceiptPacket(
                    requestID: packet.requestID,
                    sessionID: existing.sessionID ?? packet.sessionID,
                    paymentID: payloadEnvelope.paymentID,
                    status: existingStatus,
                    details: existing.details ?? "duplicate payload; returning existing receipt",
                    nullifiers: existing.nullifiers,
                    notaryReceipts: existing.notaryReceipts
                )
                return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
            }
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.duplicatePayment.localizedDescription,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        case .replayAcrossRequests:
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.replayDetected.localizedDescription,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        case .paymentMismatch:
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: BridgeError.paymentMismatch.localizedDescription,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }

        do {
            let settled = try await x402GatewayClient.settlePayment(
                gatewayURL: record.mintURL,
                paymentID: payloadEnvelope.paymentID,
                paymentData: payloadEnvelope.paymentData,
                requestID: packet.requestID,
                token: x402GatewayToken
            )
            let details: String = {
                if let txHash = settled.txHash, !txHash.isEmpty {
                    return "settled on-chain (\(txHash))"
                }
                return "settled on-chain"
            }()
            store.markReceipt(
                requestID: packet.requestID,
                status: .finalizedOnline,
                details: details,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .finalizedOnline,
                details: details,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: true)
        } catch {
            let details = error.localizedDescription.isEmpty ? BridgeError.x402SettlementFailed.localizedDescription : error.localizedDescription
            store.markReceipt(
                requestID: packet.requestID,
                status: .rejected,
                details: details,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            let receipt = AgentPaymentReceiptPacket(
                requestID: packet.requestID,
                sessionID: packet.sessionID,
                paymentID: payloadEnvelope.paymentID,
                status: .rejected,
                details: details,
                nullifiers: [paymentRef],
                notaryReceipts: []
            )
            return AgentPaymentEvaluation(receipt: receipt, shouldAdvanceFlow: false)
        }
    }

    private func receiptStatus(for state: AgentPaymentState) -> AgentPaymentReceiptStatus? {
        switch state {
        case .acceptedOffline:
            return .acceptedOffline
        case .finalizedOnline:
            return .finalizedOnline
        case .rejected, .failed:
            return .rejected
        case .paymentRequested, .payloadSent:
            return nil
        }
    }

    private func defaultAmount(for terms: AgentPaymentTerms) -> UInt64 {
        if terms.usesPerTokenPricing {
            let output = terms.pricePerOutputToken ?? 0
            let granularity = UInt64(terms.effectiveGranularityTokens)
            let trancheAmount = output > 0 ? output * granularity : 0
            if trancheAmount > 0 {
                return max(terms.effectiveMinimumDeposit, trancheAmount)
            }
            return terms.effectiveMinimumDeposit
        }
        return terms.pricePerRequest
    }

    private func makePaymentID() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func selectPreferredMintURL(from acceptedMints: [String]) -> String? {
        let normalized = acceptedMints
            .map(CashuMintAllowlistStore.normalizeMintURL)
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        let unique = Array(NSOrderedSet(array: normalized)) as? [String] ?? normalized
        if let nonLoopback = unique.first(where: { !isLoopbackMintURL($0) }) {
            return nonLoopback
        }
        return unique.first
    }

    private func isLoopbackMintURL(_ mintURL: String) -> Bool {
        guard let url = URL(string: mintURL), let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost"
    }

    private func mintSwapFailureMessage(_ error: Error, mintURL: String) -> String {
        let reason = error.localizedDescription
        if isLoopbackMintURL(mintURL) {
            return "mint \(mintURL) is local-only or offline (\(reason))"
        }
        return "mint finalize failed at \(mintURL) (\(reason))"
    }

    private func shouldCommitReservedOnRejection(details: String?) -> Bool {
        let normalized = details?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return false }
        if normalized.contains("already spent") {
            return true
        }
        if normalized.contains("payment replay detected") {
            return true
        }
        if normalized.contains("token already spent") {
            return true
        }
        return false
    }

    func finalizePendingOfflinePayments(enablePaymentLocking: Bool = true) async -> Int {
        var finalizedCount = 0
        lockKeyStore.pruneExpired(maxDeletes: 64)
        let pending = store.pendingOfflineFinalizations()
        for record in pending {
            guard let payload = record.payload,
                  let payloadEnvelope = CashuPaymentPayloadEnvelope.decode(fromJSONString: payload) else {
                continue
            }
            var payloadForSwap = payloadEnvelope
            if enablePaymentLocking, (record.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk {
                guard let secretHex = lockKeyStore.loadSecret(
                    requestID: record.requestID,
                    paymentID: record.paymentID
                ) else {
                    continue
                }
                guard let signedProofs = try? p2pkService.signProofsForSpend(
                    proofs: payloadEnvelope.proofs,
                    secretHex: secretHex
                ) else {
                    continue
                }
                payloadForSwap = CashuPaymentPayloadEnvelope(
                    paymentID: payloadEnvelope.paymentID,
                    requestID: payloadEnvelope.requestID,
                    mintURL: payloadEnvelope.mintURL,
                    unit: payloadEnvelope.unit,
                    totalAmount: payloadEnvelope.totalAmount,
                    proofs: signedProofs,
                    token: payloadEnvelope.token,
                    requiresLocking: payloadEnvelope.requiresLocking,
                    lockPubkey: payloadEnvelope.lockPubkey,
                    nullifiers: payloadEnvelope.nullifiers,
                    clientNonce: payloadEnvelope.clientNonce,
                    createdAtMs: payloadEnvelope.createdAtMs
                )
            }
            do {
                try await mintClient.swap(mintURL: payloadForSwap.mintURL, payload: payloadForSwap)
                store.markReceipt(
                    requestID: record.requestID,
                    status: .finalizedOnline,
                    details: "offline receipt finalized",
                    nullifiers: payloadEnvelope.nullifiers,
                    notaryReceipts: record.notaryReceipts
                )
                finalizedCount += 1
                if enablePaymentLocking, (record.requiresLocking ?? AgentPaymentLockingMode.none) == .p2pk {
                    lockKeyStore.delete(requestID: record.requestID, paymentID: record.paymentID)
                }
            } catch {
                continue
            }
        }
        return finalizedCount
    }
}
