//
//  TrackPropertiesSheet.swift
//  RouteKeeper
//
//  Sheet for editing a track's display properties: name, colour, and line style.
//
//  IMPORTANT: Add this file to the Xcode target manually after creating it.
//

import SwiftUI

struct TrackPropertiesSheet: View {
    let trackItemId: Int64
    let initialName: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var trackName:     String = ""
    @State private var selectedColor: String = "#3E515A"
    @State private var selectedStyle: String = "dotted"

    @State private var originalName:  String = ""
    @State private var originalColor: String = "#3E515A"
    @State private var originalStyle: String = "dotted"

    @State private var isSaving       = false
    @State private var showSaveError  = false
    @State private var showDiscardAlert = false

    private var hasUnsavedChanges: Bool {
        trackName.trimmingCharacters(in: .whitespaces) != originalName ||
        selectedColor != originalColor ||
        selectedStyle != originalStyle
    }

    private var canSave: Bool {
        !trackName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Text("Track Properties")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    colourSection
                    lineStyleSection
                }
                .padding(20)
            }

            Divider()

            if showSaveError {
                Text("Save failed. Please try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if hasUnsavedChanges {
                        showDiscardAlert = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                if isSaving {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.leading, 4)
                } else {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .fixedSize()
        .confirmationDialog("Discard changes?", isPresented: $showDiscardAlert,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        }
        .onAppear {
            trackName     = initialName
            originalName  = initialName
            Task { await loadData() }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Track Name",
                  systemImage: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Track name", text: $trackName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Colour", systemImage: "paintpalette")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                ForEach(Track.presetColours, id: \.self) { hex in
                    ColourSwatch(hex: hex, isSelected: selectedColor == hex) {
                        selectedColor = hex
                    }
                }
            }
        }
    }

    private var lineStyleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Line Style", systemImage: "line.diagonal")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("Line Style", selection: $selectedStyle) {
                Text("Dotted").tag("dotted")
                Text("Short dash").tag("short_dash")
                Text("Long dash").tag("long_dash")
                Text("Solid").tag("solid")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Actions

    private func loadData() async {
        do {
            if let track = try await DatabaseManager.shared.fetchTrack(itemId: trackItemId) {
                selectedColor = track.color
                selectedStyle = track.lineStyle
                originalColor = track.color
                originalStyle = track.lineStyle
            }
        } catch {
            // Track unavailable; defaults apply.
        }
    }

    private func save() {
        let trimmed = trackName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            do {
                try await DatabaseManager.shared.updateTrackProperties(
                    itemId:    trackItemId,
                    name:      trimmed,
                    color:     selectedColor,
                    lineStyle: selectedStyle
                )
                onSave()
                dismiss()
            } catch {
                showSaveError = true
                isSaving = false
            }
        }
    }
}
