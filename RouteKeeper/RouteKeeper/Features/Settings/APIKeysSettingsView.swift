//
//  APIKeysSettingsView.swift
//  RouteKeeper
//
//  API Keys preferences pane shown in the Settings window.
//

import SwiftUI

struct APIKeysSettingsView: View {

    @Environment(APIKeysManager.self) private var apiKeysManager

    @State private var showMapTilerKey    = false
    @State private var showWhat3WordsKey  = false

    var body: some View {
        @Bindable var manager = apiKeysManager

        Form {
            Section("API Keys") {
                keyRow(
                    label: "MapTiler",
                    value: $manager.mapTilerKey,
                    isVisible: $showMapTilerKey,
                    hint: "Required for map tiles. Get a free key at maptiler.com"
                )

                keyRow(
                    label: "What3Words",
                    value: $manager.what3WordsKey,
                    isVisible: $showWhat3WordsKey,
                    hint: "Requires a paid What3Words Business plan. Get a key at what3words.com"
                )
            }

            Section {
                Button("Save") {
                    apiKeysManager.save()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480)
    }

    @ViewBuilder
    private func keyRow(
        label: String,
        value: Binding<String>,
        isVisible: Binding<Bool>,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .frame(width: 100, alignment: .leading)
                if isVisible.wrappedValue {
                    TextField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
