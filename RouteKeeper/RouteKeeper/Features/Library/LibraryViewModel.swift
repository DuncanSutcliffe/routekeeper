//
//  LibraryViewModel.swift
//  RouteKeeper
//
//  View model for the library sidebar. Loads folders and lists from the
//  database and exposes them for display.
//

import Foundation
import Observation

/// Provides the library sidebar with folder and list data from the database.
@Observable
@MainActor
final class LibraryViewModel {

    /// All library folders paired with the lists they contain, ordered by `sort_order`.
    private(set) var folderContents: [(folder: ListFolder, lists: [RouteList])] = []

    /// `true` while a database load is in progress.
    private(set) var isLoading = false

    /// The most recent error from a failed load attempt, if any.
    private(set) var loadError: Error?

    /// Fetches folder and list data from the database.
    ///
    /// Clears any previous error, sets `isLoading` during the fetch, and
    /// updates `folderContents` on success or `loadError` on failure.
    func load() async {
        isLoading = true
        loadError = nil
        do {
            folderContents = try await DatabaseManager.shared.fetchFoldersWithLists()
        } catch {
            loadError = error
        }
        isLoading = false
    }
}
