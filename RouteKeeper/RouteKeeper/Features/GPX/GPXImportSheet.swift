//
//  GPXImportSheet.swift
//  RouteKeeper
//
//  Sheet for importing a GPX file into a library list.
//  Accepts an optional preselectedListId to pre-select a list when opened from
//  a list context menu; passing nil (File menu path) leaves the picker at its
//  first entry.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GPXImportSheet: View {
    let viewModel: LibraryViewModel
    /// Pre-select this list when the sheet opens; `nil` defaults to the first available list.
    let preselectedListId: Int64?
    /// Called with the target list after a successful import, so the caller can
    /// update the sidebar selection to show the newly imported content immediately.
    var onImported: ((RouteList) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL?       = nil
    @State private var selectedListId: Int64?  = nil
    @State private var showingNewListSheet     = false
    @State private var isImporting             = false
    @State private var importMessage: String?  = nil
    @State private var importError: String?    = nil

    /// Snapshot of known list IDs taken just before opening the nested NewListSheet,
    /// used to detect which list was newly created on dismiss.
    @State private var knownListIdsSnapshot: Set<Int64> = []

    // MARK: - Helpers

    /// All real (non-sentinel) lists flattened with their folder name.
    private var allListEntries: [(list: RouteList, folderName: String)] {
        viewModel.folderContents
            .filter {
                guard let id = $0.folder.id else { return false }
                return id != -1
            }
            .flatMap { pair in
                pair.lists.map { list in (list: list, folderName: pair.folder.name) }
            }
    }

    private var canImport: Bool {
        selectedURL != nil && selectedListId != nil && !isImporting
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Import GPX")
                .font(.headline)

            // File selection row
            HStack(spacing: 8) {
                Text(selectedURL?.lastPathComponent ?? "No file selected")
                    .foregroundStyle(selectedURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Browse…") { browseForFile() }
            }

            Divider()

            // List picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("Import into:", selection: $selectedListId) {
                    if allListEntries.isEmpty {
                        Text("No lists available").tag(nil as Int64?)
                    }
                    ForEach(allListEntries, id: \.list.id) { entry in
                        Text("\(entry.list.name)  —  \(entry.folderName)")
                            .tag(entry.list.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(allListEntries.isEmpty)

                Button("New List…") {
                    knownListIdsSnapshot = Set(allListEntries.compactMap(\.list.id))
                    showingNewListSheet = true
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }

            // Status / error message
            Group {
                if let msg = importMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let err = importError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(minHeight: 16)

            Divider()

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { doImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let id = preselectedListId {
                selectedListId = id
            } else {
                selectedListId = allListEntries.first?.list.id
            }
        }
        .sheet(isPresented: $showingNewListSheet, onDismiss: {
            // Detect the newly created list by diffing against the pre-sheet snapshot.
            let currentIds = Set(viewModel.folderContents
                .filter {
                    guard let id = $0.folder.id else { return false }
                    return id != -1
                }
                .flatMap(\.lists)
                .compactMap(\.id))
            if let newId = currentIds.subtracting(knownListIdsSnapshot).first {
                selectedListId = newId
            }
        }) {
            NewListSheet(viewModel: viewModel, preselectedFolderID: nil)
        }
    }

    // MARK: - Helpers

    private func importSummary(routes: Int, waypoints: Int, tracks: Int, list: String) -> String {
        var parts: [String] = []
        if routes > 0    { parts.append(routes    == 1 ? "1 route"    : "\(routes) routes") }
        if tracks > 0    { parts.append(tracks    == 1 ? "1 track"    : "\(tracks) tracks") }
        if waypoints > 0 { parts.append(waypoints == 1 ? "1 waypoint" : "\(waypoints) waypoints") }
        let summary = parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
        return "Imported \(summary) into \(list)."
    }

    // MARK: - File picker

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let gpxType  = UTType(filenameExtension: "gpx")
        let xmlType  = UTType(filenameExtension: "xml")
        panel.allowedContentTypes = [gpxType, xmlType].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        selectedURL    = panel.url
        importMessage  = nil
        importError    = nil
    }

    // MARK: - Import

    private func doImport() {
        guard let url = selectedURL, let listId = selectedListId else { return }
        isImporting   = true
        importMessage = nil
        importError   = nil

        Task {
            do {
                let result = try GPXImporter.parse(url: url)
                let (rc, wc, tc, listName) = try await DatabaseManager.shared
                    .importGPXResult(result, into: listId)
                importMessage = importSummary(routes: rc, waypoints: wc, tracks: tc, list: listName)
                await viewModel.reload()
                // Select the imported list in the sidebar so the user sees the
                // new content immediately after the sheet dismisses.
                if let targetList = viewModel.folderContents
                    .flatMap({ $0.lists })
                    .first(where: { $0.id == listId }) {
                    onImported?(targetList)
                }
                isImporting = false
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
                return
            } catch GPXImportError.noContent {
                importError = "No importable content found in this file."
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#Preview {
    GPXImportSheet(viewModel: LibraryViewModel(), preselectedListId: nil)
}
