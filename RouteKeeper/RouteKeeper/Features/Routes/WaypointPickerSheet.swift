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
    /// When non-nil, the waypoint with this `itemId` is excluded from the list
    /// so the user cannot pick the same point for both start and end.
    var excludingId: Int64? = nil
    /// Title shown in the sheet navigation bar. Defaults to `"Add Waypoint"`.
    var title: String = "Add Waypoint"

    @State private var sections: [WaypointListSection] = []
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    /// Sections after applying the exclusion filter and the search query.
    ///
    /// Search is a case- and diacritic-insensitive OR match across name, category
    /// name, notes, and list name. List-name matching uses a two-pass approach:
    /// waypoints whose itemId appears in any section whose list name matches are
    /// included in **all** their sections, not just the matching one.
    /// Sections with no remaining waypoints are dropped.
    private var filteredSections: [WaypointListSection] {
        // Pass 1: when search is active, collect itemIds that match via list name
        // so they can be surfaced in every section they belong to.
        var matchedViaListName: Set<Int64> = []
        if !searchText.isEmpty {
            let foldedTerm = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            for section in sections {
                let foldedList = section.listName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if foldedList.contains(foldedTerm) {
                    for wp in section.waypoints {
                        matchedViaListName.insert(wp.itemId)
                    }
                }
            }

            // Pass 2: filter each section, applying exclusion then search criteria.
            return sections.compactMap { section in
                var waypoints = section.waypoints
                if let excluded = excludingId {
                    waypoints = waypoints.filter { $0.itemId != excluded }
                }
                waypoints = waypoints.filter { wp in
                    func matches(_ s: String) -> Bool {
                        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                         .contains(foldedTerm)
                    }
                    return matchedViaListName.contains(wp.itemId) ||
                           matches(wp.name) ||
                           (wp.categoryName.map(matches) ?? false) ||
                           (wp.notes.map(matches) ?? false)
                }
                guard !waypoints.isEmpty else { return nil }
                return WaypointListSection(
                    listId:     section.listId,
                    listName:   section.listName,
                    folderName: section.folderName,
                    waypoints:  waypoints
                )
            }
        }

        // No search term — apply exclusion only.
        return sections.compactMap { section in
            let waypoints = excludingId.map { id in section.waypoints.filter { $0.itemId != id } }
                            ?? section.waypoints
            guard !waypoints.isEmpty else { return nil }
            return WaypointListSection(
                listId:     section.listId,
                listName:   section.listName,
                folderName: section.folderName,
                waypoints:  waypoints
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Full-width search field pinned below the navigation title.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List {
                    ForEach(filteredSections) { section in
                        Section {
                            ForEach(section.waypoints) { waypoint in
                                Button {
                                    onSelect(waypoint)
                                    dismiss()
                                } label: {
                                    waypointRow(waypoint)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.listName)
                                if let folder = section.folderName {
                                    Text(folder)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if sections.isEmpty {
                        Text("No waypoints saved yet.")
                            .foregroundStyle(.secondary)
                    } else if filteredSections.isEmpty {
                        Text("No waypoints match \"\(searchText)\".")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
        .task {
            do {
                await Task.yield()
                sections = try await DatabaseManager.shared.fetchWaypointsByList()
            } catch {
                // sections stays empty; overlay message is shown.
            }
        }
    }

    // MARK: - Row view

    private func waypointRow(_ waypoint: WaypointSummary) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(itemHex: waypoint.colorHex.isEmpty ? "#1A73E8" : waypoint.colorHex))
                .frame(width: 12, height: 12)
            Image(systemName: waypoint.categoryIconName ?? "mappin")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(waypoint.name)
                    .foregroundStyle(.primary)
                if let catName = waypoint.categoryName {
                    Text(catName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
