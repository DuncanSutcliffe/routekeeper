//
//  ExportFormatSheet.swift
//  RouteKeeper
//
//  A small modal sheet that lets the user choose between Standard GPX 1.1 and
//  Garmin GPX 1.1 before the macOS save panel is presented.
//

import SwiftUI

struct ExportFormatSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Default filename stem shown in the save panel (without extension).
    let defaultFilename: String
    /// Called with the chosen format after the sheet is dismissed.
    let onExport: (GPXFormat) -> Void

    @State private var selectedFormat: GPXFormat = PreferencesManager.shared.defaultExportFormat == "garmin"
        ? .garmin : .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a format for the exported GPX file.")
                .fixedSize(horizontal: false, vertical: true)

            Picker("Format", selection: $selectedFormat) {
                Text("Standard GPX 1.1").tag(GPXFormat.standard)
                Text("Garmin GPX 1.1").tag(GPXFormat.garmin)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(formatDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export") {
                    let format = selectedFormat
                    dismiss()
                    // Brief delay so the sheet finishes its dismissal animation
                    // before the NSSavePanel blocks the main thread.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        onExport(format)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var formatDescription: String {
        switch selectedFormat {
        case .standard:
            return "Compatible with most mapping applications and GPS devices."
        case .garmin:
            return "Includes Garmin extensions for shaping points. " +
                   "Use for Garmin devices and Basecamp."
        }
    }

}
