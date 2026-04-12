//
//  ExportSettingsView.swift
//  RouteKeeper
//
//  Export preferences pane shown in the Settings window.
//

import SwiftUI

struct ExportSettingsView: View {
    // TODO: [REFACTOR] Same manual Binding pattern as GeneralSettingsView — use @Bindable.
    var body: some View {
        Form {
            Picker("Default GPX Format", selection: Binding(
                get: { PreferencesManager.shared.defaultExportFormat },
                set: { newValue in
                    PreferencesManager.shared.defaultExportFormat = newValue
                    PreferencesManager.shared.save()
                }
            )) {
                Text("Standard GPX 1.1").tag("standard")
                Text("Garmin GPX 1.1").tag("garmin")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding()
    }
}
