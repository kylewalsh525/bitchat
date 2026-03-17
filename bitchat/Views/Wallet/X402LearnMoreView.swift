import SwiftUI

struct X402LearnMoreView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var surfaceBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color(.windowBackgroundColor)
        #endif
    }

    var body: some View {
        List {
            Section {
                SettingsIconRow(
                    icon: "globe",
                    title: "What x402 means in plain words",
                    subtitle: "x402 is the online pay flow. We first ask an online provider for a payment request, then we send a wallet payment to let them fulfill your request."
                )
            }

            Section("When You'll See It") {
                SettingsIconRow(
                    icon: "rectangle.stack.badge.plus",
                    title: "Payment choices",
                    subtitle: "When BitChat receives multiple payment options, each choice shows price and an estimated wait time. You pick one option to start."
                )
                SettingsIconRow(
                    icon: "wifi.slash",
                    title: "Online only",
                    subtitle: "x402 needs internet. If you are on Bluetooth-only, use Cashu instead."
                )
            }

            Section("Guest Wallet") {
                SettingsIconRow(
                    icon: "person.crop.circle",
                    title: "What the guest wallet is",
                    subtitle: "A guest wallet is made for this account and only used for x402 payments."
                )
                SettingsIconRow(
                    icon: "key",
                    title: "Where your key lives",
                    subtitle: "BitChat creates the wallet in the secure runtime. In this beta we only surface the wallet address, not private-key text."
                )
                SettingsIconRow(
                    icon: "arrow.counterclockwise",
                    title: "Resetting wallet",
                    subtitle: "Resetting removes local wallet state. Any funds already in that wallet may not be reachable from BitChat after reset."
                )
            }

            Section("Privacy & Tradeoffs") {
                SettingsIconRow(
                    icon: "eye.slash",
                    title: "Less private than Cashu",
                    subtitle: "On-chain payments can reveal your wallet address and transaction history to the payee and the chain."
                )
                SettingsIconRow(
                    icon: "hand.raised",
                    title: "Better for online use",
                    subtitle: "x402 is useful when you have internet and want a quick setup. Cashu is better for offline and for more privacy."
                )
            }

            Section("Links") {
                Link(destination: URL(string: "https://portal.thirdweb.com/typescript/v5/inAppWallet")!) {
                    SettingsIconRow(
                        icon: "link",
                        title: "thirdweb in-app wallet docs",
                        subtitle: "Opens in your browser."
                    )
                }
                Link(destination: URL(string: "https://thirdweb.com/pricing")!) {
                    SettingsIconRow(
                        icon: "dollarsign.circle",
                        title: "thirdweb pricing",
                        subtitle: "Opens in your browser."
                    )
                }
            }

            Section("Troubleshooting") {
                SettingsIconRow(
                    icon: "exclamationmark.triangle",
                    title: "If \"thirdweb failed to start\" shows up",
                    subtitle: "Usually this is network-related (DNS/CDN access) or a missing thirdweb client ID. Check Wallet → x402 status for exact guidance."
                )
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("About x402")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(surfaceBackground)
        .tint(accent)
    }
}

#Preview("x402 learn more") {
    NavigationStack {
        X402LearnMoreView()
    }
}
