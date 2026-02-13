//
// AgentPreferencesView.swift
// bitchat
//
// Back-compat sheet wrapper for requester preferences.
// The primary entrypoint is now Settings -> Agents -> Requester preferences.
//

import SwiftUI

struct AgentPreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RequesterPreferencesSettingsView()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 720)
        #endif
    }
}

