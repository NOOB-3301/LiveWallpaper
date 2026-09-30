import SwiftUI
import AppKit
import Core

// SCAFFOLD STUB (owner: SETTINGS). Views for the Workshop and Steam Setup tabs, built strictly on the
// WorkshopModel surface in Workshop.swift (owner: STEAM). Layout, states and microcopy: SPEC2.md sections 5.4 to 5.6.
// Every view here must be @MainActor and must not call into Workshop.swift beyond the published surface.

/// Workshop tab: paste field + result card, optional browse grid (needs an API key), setup banner.
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void

    var body: some View {
        // TODO(SETTINGS)
        Text("Steam Workshop")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Steam Setup tab: the checklist (steamcmd, Rosetta, username, login, optional API key) and the licensing note.
@MainActor
struct SteamSetupView: View {
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        // TODO(SETTINGS)
        Text("Steam Setup")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
