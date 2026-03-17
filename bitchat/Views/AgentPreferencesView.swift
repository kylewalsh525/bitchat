//
// AgentPreferencesView.swift
// bitchat
//
// Back-compat sheet wrapper for requester preferences.
// The primary entrypoint is now Settings -> Agents -> Requester preferences.
//

import SwiftUI

struct AgentPreferencesView: View {
    var body: some View {
        NavigationStack {
            RequesterPreferencesSettingsView()
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 720)
        #endif
    }
}
