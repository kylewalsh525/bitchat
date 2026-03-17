import Foundation

enum X402ReadinessState: Equatable {
    case disabled
    case bridgeUnavailable
    case missingGuestWallet
    case ready(address: String)

    var title: String {
        switch self {
        case .disabled:
            return "x402 disabled"
        case .bridgeUnavailable:
            return "x402 unavailable"
        case .missingGuestWallet:
            return "x402 wallet not connected"
        case .ready:
            return "x402 ready"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            return "x402 is off. Turn it on if you want online on-chain payments."
        case .bridgeUnavailable:
            return "This device cannot run the thirdweb bridge right now."
        case .missingGuestWallet:
            return "Next step: connect your guest wallet in Wallet setup."
        case .ready(let address):
            return "Connected guest wallet: \(address)."
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

enum X402ReadinessEvaluator {
    static func evaluate(
        allowX402Payments: Bool,
        bridgeAvailable: Bool,
        walletAddress: String?
    ) -> X402ReadinessState {
        guard allowX402Payments else { return .disabled }
        guard bridgeAvailable else { return .bridgeUnavailable }

        let normalizedWallet = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedWallet.isEmpty else { return .missingGuestWallet }

        return .ready(address: normalizedWallet)
    }
}
