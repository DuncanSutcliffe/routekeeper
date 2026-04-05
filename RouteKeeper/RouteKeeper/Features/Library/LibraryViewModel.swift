//
//  LibraryViewModel.swift
//  RouteKeeper
//
//  View model for the library sidebar. Loads folders, lists, and list
//  contents from the database and exposes them for display.
//

import Foundation
import Observation

/// Provides the library sidebar with folder, list, and item data from the database.
@Observable
@MainActor
final class LibraryViewModel {

    // MARK: - Published state

    /// All library folders paired with the lists they contain.
    private(set) var folderContents: [(folder: ListFolder, lists: [RouteList])] = []

    /// Items belonging to the currently selected list.
    private(set) var listItems: [Item] = []

    /// IDs of folders currently expanded in the top panel.
    /// Populated with all folder IDs when folders are loaded so everything
    /// starts expanded.
    var expandedFolderIDs: Set<Int64> = []

    /// `true` while a folder/list load is in progress.
    private(set) var isLoading = false

    /// The most recent error from a failed load attempt, if any.
    private(set) var loadError: Error?

    // MARK: - Folder / list loading

    /// Fetches folder and list data from the database.
    ///
    /// - Parameters:
    ///   - sortColumn: Column to sort `list_folders` by (`"name"` or `"created_at"`).
    ///   - ascending: Sort direction.
    func load(sortColumn: String = "sort_order", ascending: Bool = true) async {
        isLoading = true
        loadError = nil
        do {
            var contents = try await DatabaseManager.shared.fetchFoldersWithLists(
                sortColumn: sortColumn,
                ascending: ascending
            )
            // Append the system Unclassified folder last, outside the sort order.
            contents.append((folder: .unclassified, lists: [.unclassified]))
            folderContents = contents
            // Default all folders (including Unclassified) to expanded on load.
            let ids = Set(folderContents.compactMap(\.folder.id))
            // Preserve any existing expansion choices; only add newly seen IDs.
            expandedFolderIDs.formUnion(ids)
        } catch {
            loadError = error
        }
        isLoading = false
    }

    // MARK: - Item loading

    /// Fetches the items belonging to `list` and stores them in `listItems`.
    ///
    /// When `list` is the sentinel ``RouteList/unclassified`` (id == -1),
    /// queries for items with no membership row instead of the normal join.
    func loadItems(for list: RouteList) async {
        do {
            if list.id == -1 {
                listItems = try await DatabaseManager.shared.fetchUnclassifiedItems()
            } else {
                guard let listId = list.id else { return }
                listItems = try await DatabaseManager.shared.fetchItems(for: listId)
            }
        } catch {
            listItems = []
        }
    }

    /// Clears the item list (called when no list is selected).
    func clearItems() {
        listItems = []
    }
}
