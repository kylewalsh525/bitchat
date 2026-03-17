import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var showsCloseButton: Bool = true
    var onOpenAgentSettings: (() -> Void)? = nil
    var onOpenAgentPreferences: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    private var settingsAction: (() -> Void)? {
        if let onOpenSettings { return onOpenSettings }
        if let onOpenAgentSettings { return onOpenAgentSettings }
        if let onOpenAgentPreferences { return onOpenAgentPreferences }
        return nil
    }

    private var featureItems: [AppInfoFeatureInfo] {
        [
            Strings.Features.offlineComm,
            Strings.Features.encryption,
            Strings.Features.extendedRange,
            Strings.Features.favorites,
            Strings.Features.geohash,
            Strings.Features.mentions
        ]
    }

    private var privacyItems: [AppInfoFeatureInfo] {
        [
            Strings.Privacy.noTracking,
            Strings.Privacy.ephemeral,
            Strings.Privacy.panic
        ]
    }

    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"

        enum Features {
            static let title: LocalizedStringKey = "app_info.features.title"
            static let offlineComm = AppInfoFeatureInfo(
                icon: "wifi.slash",
                title: "app_info.features.offline.title",
                description: "app_info.features.offline.description"
            )
            static let encryption = AppInfoFeatureInfo(
                icon: "lock.shield",
                title: "app_info.features.encryption.title",
                description: "app_info.features.encryption.description"
            )
            static let extendedRange = AppInfoFeatureInfo(
                icon: "antenna.radiowaves.left.and.right",
                title: "app_info.features.extended_range.title",
                description: "app_info.features.extended_range.description"
            )
            static let mentions = AppInfoFeatureInfo(
                icon: "at",
                title: "app_info.features.mentions.title",
                description: "app_info.features.mentions.description"
            )
            static let favorites = AppInfoFeatureInfo(
                icon: "star.fill",
                title: "app_info.features.favorites.title",
                description: "app_info.features.favorites.description"
            )
            static let geohash = AppInfoFeatureInfo(
                icon: "number",
                title: "app_info.features.geohash.title",
                description: "app_info.features.geohash.description"
            )
        }

        enum Privacy {
            static let title: LocalizedStringKey = "app_info.privacy.title"
            static let noTracking = AppInfoFeatureInfo(
                icon: "eye.slash",
                title: "app_info.privacy.no_tracking.title",
                description: "app_info.privacy.no_tracking.description"
            )
            static let ephemeral = AppInfoFeatureInfo(
                icon: "shuffle",
                title: "app_info.privacy.ephemeral.title",
                description: "app_info.privacy.ephemeral.description"
            )
            static let panic = AppInfoFeatureInfo(
                icon: "hand.raised.fill",
                title: "app_info.privacy.panic.title",
                description: "app_info.privacy.panic.description"
            )
        }

        enum HowToUse {
            static let title: LocalizedStringKey = "app_info.how_to_use.title"
            static let instructions: [LocalizedStringKey] = [
                "app_info.how_to_use.set_nickname",
                "app_info.how_to_use.change_channels",
                "app_info.how_to_use.open_sidebar",
                "app_info.how_to_use.start_dm",
                "app_info.how_to_use.clear_chat",
                "app_info.how_to_use.commands"
            ]
        }
    }

    var body: some View {
        Form {
            Section {
                SettingsIconRow(
                    icon: "bubble.left.and.bubble.right",
                    title: Strings.appName,
                    subtitle: Strings.tagline
                )
                if let settingsAction {
                    Button("Open settings", action: settingsAction)
                }
            }

            Section(Strings.HowToUse.title) {
                ForEach(Array(Strings.HowToUse.instructions.enumerated()), id: \.offset) { _, instruction in
                    SettingsIconRow(
                        icon: "checkmark.circle",
                        title: instruction
                    )
                }
            }

            Section(Strings.Features.title) {
                ForEach(Array(featureItems.enumerated()), id: \.offset) { _, item in
                    AppInfoFeatureRow(info: item)
                }
            }

            Section(Strings.Privacy.title) {
                ForEach(Array(privacyItems.enumerated()), id: \.offset) { _, item in
                    AppInfoFeatureRow(info: item)
                }
            }
        }
        .navigationTitle("About BitChat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0))
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

private struct AppInfoFeatureRow: View {
    let info: AppInfoFeatureInfo

    var body: some View {
        SettingsIconRow(
            icon: info.icon,
            title: info.title,
            subtitle: info.description
        )
    }
}

#Preview("Default") {
    NavigationStack {
        AppInfoView()
    }
}

#Preview("Dynamic Type XXL") {
    NavigationStack {
        AppInfoView()
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
    }
}

#Preview("Dynamic Type XS") {
    NavigationStack {
        AppInfoView()
            .environment(\.sizeCategory, .extraSmall)
    }
}
