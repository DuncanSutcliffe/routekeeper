//
//  WaypointPickerSheet.swift
//  RouteKeeper
//
//  Presents a searchable list of all saved waypoints so the user can pick
//  one to insert into a route being edited.
//

import SwiftUI

struct WaypointPickerSheet: View {
    /// Called with the chosen waypoint when the user taps a row.
    let onSelect: (WaypointSummary) -> Void

    @State private var waypoints: [WaypointSummary] = []
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    private var filtered: [WaypointSummary] {
        if searchText.isEmpty { return waypoints }
        return waypoints.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { waypoint in
                Button {
                    onSelect(waypoint)
                    dismiss()
                } label: {
                    Text(waypoint.name)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
            .navigationTitle("Add Waypoint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if waypoints.isEmpty {
                    Text("No waypoints saved yet.")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("No waypoints match \(searchText).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
        // TODO: [REFACTOR] WaypointPickerSheet calls DatabaseManager directly from a View.
        // Waypoint fetching belongs in a ViewModel or in LibraryViewModel (which already
        // has loadAvailableWaypoints()). Also uses Task.yield() as a timing workaround —
        // see the known timing bug noted in RouteWaypointSheet.
        .task {
            do {
                await Task.yield()
                waypoints = try await DatabaseManager.shared.fetchAllWaypoints()
            } catch {
                // waypoints stays empty; overlay message is shown.
            }
        }
    }
}
