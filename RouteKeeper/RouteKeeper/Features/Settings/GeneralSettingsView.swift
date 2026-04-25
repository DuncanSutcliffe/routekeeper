//
//  GeneralSettingsView.swift
//  RouteKeeper
//
//  General preferences pane shown in the Settings window.
//

import SwiftUI

// TODO: [REFACTOR] GeneralSettingsView accesses PreferencesManager.shared directly
// rather than via @Environment. Settings views should receive the manager as an
// @Environment dependency for consistency with APIKeysSettingsView's pattern.
struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Picker("Units", selection: Binding(
                get: { PreferencesManager.shared.units },
                set: { newValue in
                    PreferencesManager.shared.units = newValue
                    PreferencesManager.shared.save()
                }
            )) {
                Text("Metric (km)").tag("metric")
                Text("Imperial (miles)").tag("imperial")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
