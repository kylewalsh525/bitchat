import Foundation

#if canImport(CashuDevKit)
import CashuDevKit
#endif

final class CashuMintClient {
    typealias ProxyRequestHandler = @Sendable (MintProxyRequestPacket) async throws -> MintProxyResponsePacket

    enum MintError: LocalizedError {
        case invalidURL
        case transport(Error)
        case badStatus(Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "invalid mint url"
            case .transport(let error):
                return error.localizedDescription
            case .badStatus(let status, let body):
                if body.isEmpty { return "mint request failed with status \(status)" }
                return "mint request failed (\(status)): \(body)"
            case .malformedResponse:
                return "malformed mint response"
            }
        }
    }

    struct MintInfo: Codable, Equatable {
        let name: String?
        let pubkey: String?
        let version: String?
    }

    struct CheckStateResult: Codable, Equatable {
        let stateByNullifier: [String: String]
    }

    private let session: URLSession
    private let proxyHandlerLock = NSLock()
    private var proxyRequestHandler: ProxyRequestHandler?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configureProxyRequestHandler(_ handler: ProxyRequestHandler?) {
        proxyHandlerLock.lock()
        proxyRequestHandler = handler
        proxyHandlerLock.unlock()
    }

    func info(mintURL: String) async throws -> MintInfo {
        let response = try await performRequest(
            mintURL: mintURL,
            method: "GET",
            candidatePaths: ["/v1/info", "/info"],
            body: nil
        )
        return (try? JSONDecoder().decode(MintInfo.self, from: response.data)) ?? MintInfo(name: nil, pubkey: nil, version: nil)
    }

    func swap(mintURL: String, payload: CashuPaymentPayloadEnvelope) async throws {
        #if canImport(CashuDevKit)
        // Prefer the standards-compliant CDK path first.
        // This avoids legacy /swap schema probes against modern mints.
        if payload.proofs.allSatisfy(hasRequiredSwapFields(_:)) {
            do {
                try await swapViaCDK(mintURL: mintURL, payload: payload)
                return
            } catch let mintError as MintError {
                // Do not retry legacy fallback for definitive client-side mint failures.
                // These should surface directly (for example: token already spent).
                switch mintError {
                case .badStatus(let status, _):
                    if (400..<500).contains(status) {
                        throw mintError
                    }
                case .malformedResponse:
                    throw mintError
                default:
                    break
                }
            } catch {
                // Keep legacy HTTP flow as a compatibility fallback.
            }
        }
        #endif

        let body = [
            "payment_id": payload.paymentID,
            "request_id": payload.requestID,
            "unit": payload.unit,
            "amount": payload.totalAmount,
            "proofs": payload.proofs.map {
                [
                    "id": $0.id as Any,
                    "amount": $0.amount,
                    "secret": $0.secret,
                    "C": $0.C as Any,
                    "witness": $0.witness as Any
                ]
            }
        ] as [String: Any]
        do {
            _ = try await performRequest(
                mintURL: mintURL,
                method: "POST",
                candidatePaths: ["/v1/swap", "/swap"],
                body: body
            )
        } catch let error as MintError {
            // Nutshell/NUT-08 mints require swap payloads in the modern "inputs/outputs" shape.
            // If the legacy request body is rejected for that reason, fall back to CDK swap.
            guard shouldFallbackToCDKSwap(error: error) else {
                throw error
            }
            try await swapViaCDK(mintURL: mintURL, payload: payload)
        }
    }

    func checkState(mintURL: String, nullifiers: [String]) async throws -> CheckStateResult {
        let response = try await performRequest(
            mintURL: mintURL,
            method: "POST",
            candidatePaths: ["/v1/checkstate", "/checkstate"],
            body: ["nullifiers": nullifiers]
        )

        if let parsed = try? JSONDecoder().decode(CheckStateResult.self, from: response.data) {
            return parsed
        }

        if let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
           let states = object["states"] as? [String: String] {
            return CheckStateResult(stateByNullifier: states)
        }

        throw MintError.malformedResponse
    }

    private func performRequest(
        mintURL: String,
        method: String,
        candidatePaths: [String],
        body: [String: Any]?
    ) async throws -> (data: Data, status: Int) {
        guard let baseURL = URL(string: mintURL) else { throw MintError.invalidURL }

        let proxyHandler = currentProxyRequestHandler()
        let proxyMethod = mintProxyMethod(for: method, candidatePaths: candidatePaths)
        let bodyJSON = try bodyJSONString(from: body)

        var lastError: Error?
        var preferredFallbackError: MintError?
        for path in candidatePaths {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            if body != nil {
                request.httpBody = bodyJSON
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw MintError.malformedResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    throw MintError.badStatus(http.statusCode, body: bodyText)
                }
                return (data, http.statusCode)
            } catch {
                lastError = error
                if let mintError = error as? MintError,
                   preferredFallbackError == nil,
                   shouldFallbackToCDKSwap(error: mintError) {
                    preferredFallbackError = mintError
                    // A NUT-08 schema mismatch on /v1/swap means retrying legacy fallback
                    // endpoints (e.g. /swap) cannot succeed. Stop early and let caller
                    // switch to the CDK swap path.
                    break
                }
                if proxyHandler != nil {
                    if let mintError = error as? MintError {
                        if case .badStatus = mintError {
                            continue
                        }
                        break
                    } else {
                        break
                    }
                }
                continue
            }
        }

        if let preferredFallbackError {
            throw preferredFallbackError
        }

        if let proxyHandler, let proxyMethod {
            do {
                let proxyID = stableProxyID(
                    mintURL: mintURL,
                    method: proxyMethod,
                    candidatePaths: candidatePaths,
                    bodyJSON: bodyJSON
                )
                let proxyRequest = MintProxyRequestPacket(
                    proxyID: proxyID,
                    mintURL: mintURL,
                    method: proxyMethod,
                    body: bodyJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                    sentAt: UInt64(Date().timeIntervalSince1970 * 1000)
                )
                let proxyResponse = try await proxyHandler(proxyRequest)
                guard proxyResponse.ok else {
                    throw MintError.badStatus(502, body: proxyResponse.error ?? "mint gateway rejected request")
                }
                let responseBody = proxyResponse.body ?? ""
                if responseBody.utf8.count > TransportConfig.mintGatewayMaxBodyBytes {
                    throw MintError.badStatus(502, body: "mint gateway response too large")
                }
                let data = Data(responseBody.utf8)
                return (data, 200)
            } catch {
                lastError = error
            }
        }

        if let mintError = lastError as? MintError {
            throw mintError
        }
        if let lastError {
            throw MintError.transport(lastError)
        }
        throw MintError.invalidURL
    }

    private func currentProxyRequestHandler() -> ProxyRequestHandler? {
        proxyHandlerLock.lock()
        let handler = proxyRequestHandler
        proxyHandlerLock.unlock()
        return handler
    }

    private func bodyJSONString(from body: [String: Any]?) throws -> Data? {
        guard let body else { return nil }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func mintProxyMethod(for method: String, candidatePaths: [String]) -> MintProxyMethod? {
        let lowerMethod = method.lowercased()
        let joined = candidatePaths.joined(separator: "|").lowercased()
        if joined.contains("checkstate") {
            return .checkstate
        }
        if joined.contains("keysets") {
            return .keysets
        }
        if joined.contains("info") && lowerMethod == "get" {
            return .info
        }
        if lowerMethod == "post" {
            return .swap
        }
        return nil
    }

    private func stableProxyID(
        mintURL: String,
        method: MintProxyMethod,
        candidatePaths: [String],
        bodyJSON: Data?
    ) -> String {
        let canonicalMint = mintURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonicalPaths = candidatePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        let bodyDigest = bodyJSON?.sha256Fingerprint() ?? "none"
        let canonical = "mintProxy:v1|\(method.rawValue)|\(canonicalMint)|\(canonicalPaths)|\(bodyDigest)"
        let digest = Data(canonical.utf8).sha256Fingerprint()
        return "proxy-\(method.rawValue)-\(String(digest.prefix(24)))"
    }

    private func hasRequiredSwapFields(_ proof: CashuProof) -> Bool {
        guard let keysetID = proof.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keysetID.isEmpty,
              let signature = proof.C?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signature.isEmpty,
              !proof.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private func shouldFallbackToCDKSwap(error: MintError) -> Bool {
        guard case .badStatus(let status, let body) = error, status == 422 else {
            return false
        }
        let lowered = body.lowercased()
        return lowered.contains("inputs")
            && lowered.contains("outputs")
            && lowered.contains("field required")
    }

    private func swapViaCDK(mintURL: String, payload: CashuPaymentPayloadEnvelope) async throws {
        #if canImport(CashuDevKit)
        let wallet = try buildWallet(mintURL: mintURL, unit: payload.unit)
        let inputProofs = try payload.proofs.map(convertToCDKProof)
        let swapped = try await wallet.swap(
            amount: nil,
            amountSplitTarget: .none,
            inputProofs: inputProofs,
            spendingConditions: nil,
            includeFees: true
        )
        guard let swapped, !swapped.isEmpty else {
            throw MintError.malformedResponse
        }
        #else
        _ = mintURL
        _ = payload
        throw MintError.badStatus(
            422,
            body: "mint expects NUT-08 swap format and CashuDevKit is unavailable"
        )
        #endif
    }
}

#if canImport(CashuDevKit)
private extension CashuMintClient {
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
            throw MintError.malformedResponse
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
}
#endif
