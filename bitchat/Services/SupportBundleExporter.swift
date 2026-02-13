import Foundation

@MainActor
final class SupportBundleExporter {
    enum ExportError: LocalizedError {
        case encodeFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .encodeFailed:
                return "failed to encode support bundle"
            case .writeFailed:
                return "failed to write support bundle"
            }
        }
    }

    struct SupportBundle: Codable, Equatable {
        struct AppInfo: Codable, Equatable {
            let bundleID: String?
            let version: String?
            let build: String?
            let platform: String
        }

        struct RedactedRuntimeConfig: Codable, Equatable {
            let mode: AgentRuntimeMode
            let gatewayPreset: AgentGatewayPreset
            let gatewayURL: String
            let timeoutSeconds: UInt32
            let streamResponses: Bool
            let hasGatewayToken: Bool
        }

        struct RedactedAgentConfig: Codable, Equatable {
            let enabled: Bool
            let role: String
            let modelId: String
            let qualityScore: UInt8
            let modelHash: String?
            let runtime: RedactedRuntimeConfig
            let paymentTerms: AgentPaymentTerms?
            let quoteTierPolicy: AgentQuoteTierPolicy
            let notaryPolicy: AgentNotaryPolicy
        }

        struct WalletSummary: Codable, Equatable {
            let allowlistedMints: [String]
            let balancesByMintAndUnit: [String: [String: UInt64]]
            let reserved: [ReservedSummary]

            struct ReservedSummary: Codable, Equatable {
                let paymentIDPrefix: String
                let mintHost: String
                let unit: String
                let amount: UInt64
            }
        }

        struct PaymentSummary: Codable, Equatable {
            let countsByState: [String: Int]
            let records: [PaymentRecordSummary]

            struct PaymentRecordSummary: Codable, Equatable {
                let requestIDPrefix: String
                let sessionIDPrefix: String?
                let peerIDPrefix: String
                let paymentIDPrefix: String
                let rail: String
                let mintHost: String
                let unit: String
                let amount: UInt64
                let settlementMode: AgentSettlementMode
                let requiresLocking: AgentPaymentLockingMode?
                let state: AgentPaymentState
                let createdAtMs: UInt64
                let updatedAtMs: UInt64
                let expiresAtMs: UInt64
                let nullifierCount: Int
                let notaryReceiptCount: Int
            }
        }

        let generatedAtMs: UInt64
        let app: AppInfo
        let featureFlags: AgentMeshFeatureFlags
        let agentConfig: RedactedAgentConfig
        let wallet: WalletSummary
        let payments: PaymentSummary
        let recentEvents: [SupportEvent]
    }

    func exportBundle(viewModel: ChatViewModel) async throws -> URL {
        let bundle = await buildBundle(viewModel: viewModel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle) else {
            throw ExportError.encodeFailed
        }

        let date = Date()
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "bitchat-support-\(stamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            throw ExportError.writeFailed
        }
    }

    private func buildAppInfo() -> SupportBundle.AppInfo {
        let info = Bundle.main.infoDictionary
        let bundleID = Bundle.main.bundleIdentifier
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "unknown"
        #endif
        return SupportBundle.AppInfo(bundleID: bundleID, version: version, build: build, platform: platform)
    }

    private func buildRedactedAgentConfig(_ config: AgentConfig) -> SupportBundle.RedactedAgentConfig {
        let runtime = SupportBundle.RedactedRuntimeConfig(
            mode: config.runtime.mode,
            gatewayPreset: config.runtime.gatewayPreset,
            gatewayURL: config.runtime.gatewayURL,
            timeoutSeconds: config.runtime.timeoutSeconds,
            streamResponses: config.runtime.streamResponses,
            hasGatewayToken: (config.runtime.gatewayToken?.isEmpty == false)
        )
        return SupportBundle.RedactedAgentConfig(
            enabled: config.enabled,
            role: config.role,
            modelId: config.modelId,
            qualityScore: config.qualityScore,
            modelHash: config.modelHash,
            runtime: runtime,
            paymentTerms: config.paymentTerms?.sanitized(),
            quoteTierPolicy: config.quoteTierPolicy.sanitized(),
            notaryPolicy: config.notaryPolicy
        )
    }

    private func buildWalletSummary(viewModel: ChatViewModel) -> SupportBundle.WalletSummary {
        let balances = viewModel.cashuWalletService.balancesByMintAndUnit()
        let reserved = viewModel.cashuWalletService.reservedSummary().map { item in
            let mintHost = URL(string: item.mintURL)?.host ?? item.mintURL
            return SupportBundle.WalletSummary.ReservedSummary(
                paymentIDPrefix: String(item.paymentID.prefix(8)),
                mintHost: mintHost,
                unit: item.unit,
                amount: item.amount
            )
        }
        return SupportBundle.WalletSummary(
            allowlistedMints: viewModel.cashuMintAllowlistStore.allowedMintURLs,
            balancesByMintAndUnit: balances,
            reserved: reserved
        )
    }

    private func buildPaymentSummary(viewModel: ChatViewModel) -> SupportBundle.PaymentSummary {
        let records = viewModel.agentPaymentStore.allRecords()
        var counts: [String: Int] = [:]
        for record in records {
            counts[record.state.rawValue, default: 0] += 1
        }

        let summaries = records.map { record in
            let mintHost = URL(string: record.mintURL)?.host ?? record.mintURL
            return SupportBundle.PaymentSummary.PaymentRecordSummary(
                requestIDPrefix: String(record.requestID.prefix(8)),
                sessionIDPrefix: record.sessionID.map { String($0.prefix(8)) },
                peerIDPrefix: String(record.peerID.prefix(8)),
                paymentIDPrefix: String(record.paymentID.prefix(8)),
                rail: record.rail,
                mintHost: mintHost,
                unit: record.unit,
                amount: record.amount,
                settlementMode: record.settlementMode,
                requiresLocking: record.requiresLocking,
                state: record.state,
                createdAtMs: record.createdAtMs,
                updatedAtMs: record.updatedAtMs,
                expiresAtMs: record.expiresAtMs,
                nullifierCount: record.nullifiers.count,
                notaryReceiptCount: record.notaryReceipts.count
            )
        }

        return SupportBundle.PaymentSummary(countsByState: counts, records: summaries)
    }

    private func buildBundle(viewModel: ChatViewModel) async -> SupportBundle {
        let events = await SupportEventLog.shared.snapshot(limit: 200)
        return SupportBundle(
            generatedAtMs: UInt64(Date().timeIntervalSince1970 * 1000),
            app: buildAppInfo(),
            featureFlags: AgentMeshFeatureFlags.load(),
            agentConfig: buildRedactedAgentConfig(viewModel.agentConfig),
            wallet: buildWalletSummary(viewModel: viewModel),
            payments: buildPaymentSummary(viewModel: viewModel),
            recentEvents: events
        )
    }
}

