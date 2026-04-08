//
//  LibraryViewModel.swift
//  RouteKeeper
//
//  View model for the library sidebar. Loads folders, lists, and list
//  contents from the database and exposes them for display.
//

import Foundation
import GRDB
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

    /// The list whose items are currently shown in the bottom panel.
    ///
    /// Retained so that drag-and-drop operations can refresh the correct list
    /// without the list selection being passed back through the view.
    private(set) var currentList: RouteList?

    /// IDs of folders currently expanded in the top panel.
    /// Populated with all folder IDs when folders are loaded so everything
    /// starts expanded.
    var expandedFolderIDs: Set<Int64> = []

    /// `true` while a folder/list load is in progress.
    private(set) var isLoading = false

    /// The most recent error from a failed load attempt, if any.
    private(set) var loadError: Error?

    /// Human-readable message set when a creation attempt fails due to a
    /// name-uniqueness constraint. Cleared by the sheet on text-field changes.
    var creationError: String?

    /// All waypoint categories, loaded on demand by the New Waypoint sheet.
    private(set) var categories: [Category] = []

    /// Waypoints that have stored coordinates, loaded on demand by the New Route sheet.
    private(set) var availableWaypoints: [Waypoint] = []

    /// Maps each item ID to the set of list IDs the item currently belongs to.
    ///
    /// Populated alongside ``listItems`` by ``loadItems(for:)`` so that context
    /// menus can synchronously determine which target lists to show as disabled.
    private(set) var itemMemberships: [Int64: Set<Int64>] = [:]

    // Remembered so createFolder() can reload with the same sort the user last chose.
    private var currentSortColumn: String = "sort_order"
    private var currentSortAscending: Bool = true

    // MARK: - Folder / list loading

    /// Fetches folder and list data from the database.
    ///
    /// - Parameters:
    ///   - sortColumn: Column to sort `list_folders` by (`"name"` or `"created_at"`).
    ///   - ascending: Sort direction.
    func load(sortColumn: String = "sort_order", ascending: Bool = true) async {
        currentSortColumn = sortColumn
        currentSortAscending = ascending
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

    // MARK: - Folder creation

    /// Creates a new folder with the given name and reloads the folder list.
    ///
    /// Sets `creationError` if the name is already taken.
    func createFolder(name: String) async {
        do {
            try await DatabaseManager.shared.createFolder(name: name)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            creationError = "A folder with that name already exists."
            return
        } catch {
            print("Create folder failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }

    /// Creates a new list inside `folderId` with the given name and reloads the folder list.
    ///
    /// Sets `creationError` if a list with that name already exists in the folder.
    func createList(name: String, folderId: Int64) async {
        do {
            try await DatabaseManager.shared.createList(name: name, folderId: folderId)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            creationError = "A list with that name already exists in this folder."
            return
        } catch {
            print("Create list failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }

    // MARK: - Waypoint creation

    /// Loads all waypoint categories from the database.
    ///
    /// Called from the New Waypoint sheet's `onAppear`. No-op if already loaded.
    func loadCategories() async {
        guard categories.isEmpty else { return }
        do {
            categories = try await DatabaseManager.shared.fetchCategories()
        } catch {
            print("Load categories failed: \(error)")
        }
    }

    /// Loads all waypoints that have stored coordinates from the database.
    ///
    /// Called from the New Route sheet's `onAppear`. Always fetches fresh so
    /// newly created waypoints are visible without restarting the app.
    func loadAvailableWaypoints() async {
        do {
            availableWaypoints = try await DatabaseManager.shared.fetchWaypointsWithCoordinates()
        } catch {
            print("Load available waypoints failed: \(error)")
        }
    }

    /// Creates a new route with the given name, Valhalla geometry, and list memberships.
    ///
    /// Sets `creationError` if a route with that name already exists.
    /// Reloads the sidebar on success.
    func createRoute(name: String, geometry: String, listIds: [Int64]) async {
        do {
            try await DatabaseManager.shared.createRoute(name: name, geometry: geometry, listIds: listIds)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            creationError = "A route with that name already exists."
            return
        } catch {
            print("Create route failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }

    /// Creates a new waypoint and reloads the sidebar.
    ///
    /// Sets `creationError` if a waypoint with that name already exists.
    func createWaypoint(
        name: String,
        latitude: Double,
        longitude: Double,
        categoryId: Int64?,
        colorHex: String,
        notes: String?,
        listIds: [Int64]
    ) async {
        do {
            try await DatabaseManager.shared.createWaypoint(
                name: name,
                latitude: latitude,
                longitude: longitude,
                categoryId: categoryId,
                colorHex: colorHex,
                notes: notes,
                listIds: listIds
            )
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            creationError = "A waypoint with that name already exists."
            return
        } catch {
            print("Create waypoint failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }

    // MARK: - Item loading

    /// Fetches the items belonging to `list` and stores them in `listItems`.
    ///
    /// When `list` is the sentinel ``RouteList/unclassified`` (id == -1),
    /// queries for items with no membership row instead of the normal join.
    func loadItems(for list: RouteList) async {
        currentList = list
        do {
            let items: [Item]
            if list.id == -1 {
                items = try await DatabaseManager.shared.fetchUnclassifiedItems()
            } else {
                guard let listId = list.id else { return }
                items = try await DatabaseManager.shared.fetchItems(for: listId)
            }
            listItems = items
            // Populate the membership lookup so context menus can grey out
            // lists the item already belongs to without an extra DB round-trip.
            var memberships: [Int64: Set<Int64>] = [:]
            for item in items {
                if let id = item.id {
                    memberships[id] = try await DatabaseManager.shared.fetchListIds(for: id)
                }
            }
            itemMemberships = memberships
        } catch {
            listItems = []
            itemMemberships = [:]
        }
    }

    /// Clears the item list (called when no list is selected).
    func clearItems() {
        currentList = nil
        listItems = []
        itemMemberships = [:]
    }

    // MARK: - Drag and drop

    /// Copies `itemId` into `targetList` by inserting a membership row.
    ///
    /// No-op if the item is already a member of the target list.
    /// Refreshes the bottom panel after a successful operation.
    func copyItem(itemId: Int64, toList targetList: RouteList) async {
        guard let targetListId = targetList.id else { return }
        do {
            try await DatabaseManager.shared.copyItemToList(
                itemId: itemId,
                targetListId: targetListId
            )
        } catch {
            print("Copy item to list failed: \(error)")
            return
        }
        if let current = currentList {
            await loadItems(for: current)
        }
    }

    /// Moves `itemId` from `sourceListId` to `targetList` in a single transaction.
    ///
    /// No-op when source and target are the same list.
    /// Refreshes the bottom panel after a successful operation.
    func moveItem(itemId: Int64, fromListId sourceListId: Int64, toList targetList: RouteList) async {
        guard let targetListId = targetList.id, sourceListId != targetListId else { return }
        do {
            try await DatabaseManager.shared.moveItemBetweenLists(
                itemId: itemId,
                sourceListId: sourceListId,
                targetListId: targetListId
            )
        } catch {
            print("Move item between lists failed: \(error)")
            return
        }
        if let current = currentList {
            await loadItems(for: current)
        }
    }

    // MARK: - Item removal and deletion

    /// Removes `itemId` from a single list without deleting the item.
    ///
    /// If this was the item's only membership it will appear in Unclassified.
    /// Refreshes the bottom panel after a successful operation.
    func removeItemFromList(itemId: Int64, listId: Int64) async {
        do {
            try await DatabaseManager.shared.removeItemFromList(itemId: itemId, listId: listId)
        } catch {
            print("Remove item from list failed: \(error)")
            return
        }
        if let current = currentList {
            await loadItems(for: current)
        }
    }

    /// Permanently deletes an item and all its associated data.
    ///
    /// Refreshes the bottom panel after a successful deletion.
    func deleteItem(itemId: Int64) async {
        do {
            try await DatabaseManager.shared.deleteItem(itemId: itemId)
        } catch {
            print("Delete item failed: \(error)")
            return
        }
        if let current = currentList {
            await loadItems(for: current)
        }
    }

    // MARK: - List and folder deletion

    /// Deletes `list` if it is empty, then reloads the folder tree.
    ///
    /// Silently skips deletion if the list still contains items when this
    /// method runs (the caller should pre-verify via the context menu check).
    func deleteList(_ list: RouteList) async {
        guard let listId = list.id else { return }
        do {
            let count = try await DatabaseManager.shared.fetchListItemCount(listId: listId)
            guard count == 0 else { return }
            try await DatabaseManager.shared.deleteList(listId: listId)
        } catch {
            print("Delete list failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }

    /// Deletes `folder` and all its lists if all lists are empty, then reloads the folder tree.
    ///
    /// Silently skips deletion if any list in the folder contains items when
    /// this method runs (the caller should pre-verify via the context menu check).
    func deleteFolder(_ folder: ListFolder) async {
        guard let folderId = folder.id else { return }
        do {
            let hasItems = try await DatabaseManager.shared.folderHasItems(folderId: folderId)
            guard !hasItems else { return }
            try await DatabaseManager.shared.deleteFolder(folderId: folderId)
        } catch {
            print("Delete folder failed: \(error)")
            return
        }
        await load(sortColumn: currentSortColumn, ascending: currentSortAscending)
    }
}
