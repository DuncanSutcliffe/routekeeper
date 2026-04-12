//
//  GeneralSettingsView.swift
//  RouteKeeper
//
//  General preferences pane shown in the Settings window.
//

import SwiftUI

struct GeneralSettingsView: View {
    // TODO: [REFACTOR] PreferencesManager.shared is accessed via a manually constructed
    // Binding. With @Observable, use @Bindable var prefs = PreferencesManager.shared
    // and bind directly: $prefs.units. The manual get/set Binding is boilerplate that
    // @Bindable eliminates.
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
