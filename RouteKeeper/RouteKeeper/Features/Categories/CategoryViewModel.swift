//
//  CategoryViewModel.swift
//  RouteKeeper
//
//  Observable view model for the category management window.
//  Keeps a sorted list of all categories and their waypoint usage counts,
//  and provides create / update / delete operations backed by DatabaseManager.
//

import Foundation

// MARK: - Shared notification names

extension NSNotification.Name {
    /// Posted after a category is created so waypoint sheets can refresh and
    /// auto-select the new category.  `userInfo["id"]` carries the new Int64 id.
    static let routeKeeperCategoryCreated = NSNotification.Name(
        "routeKeeperCategoryCreated"
    )
    /// Posted after any category change (create / update / delete) so the map
    /// coordinator can re-register category icons with MapLibre.
    static let routeKeeperCategoriesChanged = NSNotification.Name(
        "routeKeeperCategoriesChanged"
    )
}

// MARK: - CategoryViewModel

/// Drives the category management window.
@Observable
@MainActor
final class CategoryViewModel {

    // MARK: State

    /// All categories, sorted alphabetically.
    private(set) var categories: [Category] = []

    /// Waypoint usage count keyed by category id.  A count > 0 means the
    /// category's delete button is disabled.
    private(set) var usageCounts: [Int64: Int] = [:]

    /// Human-readable error set when a database operation fails.
    var errorMessage: String? = nil

    // MARK: Loading

    /// Fetches all categories and their usage counts from the database.
    func load() async {
        do {
            categories   = try await DatabaseManager.shared.fetchCategories()
            usageCounts  = [:]
            for cat in categories {
                guard let catId = cat.id else { continue }
                let count = try await DatabaseManager.shared.fetchCategoryUsageCount(
                    categoryId: catId
                )
                usageCounts[catId] = count
            }
        } catch {
            errorMessage = "Failed to load categories: \(error.localizedDescription)"
        }
    }

    // MARK: Validation

    /// Returns `true` if `name` is already used by another category
    /// (case-insensitive), optionally excluding `excludingId`.
    func isNameTaken(_ name: String, excludingId: Int64? = nil) async -> Bool {
        do {
            return try await DatabaseManager.shared.categoryNameExists(
                name, excludingId: excludingId
            )
        } catch {
            return false
        }
    }

    // MARK: Create

    /// Creates a new user-defined category, refreshes the list, and posts
    /// notifications so the map and waypoint sheets react immediately.
    ///
    /// - Returns: The newly created category, or `nil` on failure.
    @discardableResult
    func createCategory(name: String, iconName: String) async -> Category? {
        do {
            let newCat = try await DatabaseManager.shared.createCategory(
                name: name, iconName: iconName
            )
            await load()
            // Notify waypoint sheets so they can auto-select the new category.
            if let catId = newCat.id {
                NotificationCenter.default.post(
                    name: .routeKeeperCategoryCreated,
                    object: nil,
                    userInfo: ["id": catId]
                )
            }
            // Notify the map coordinator to refresh icon registration.
            NotificationCenter.default.post(
                name: .routeKeeperCategoriesChanged, object: nil
            )
            return newCat
        } catch {
            errorMessage = "Could not create category: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Update

    /// Updates an existing user-defined category and refreshes the list.
    func updateCategory(_ category: Category, name: String, iconName: String) async {
        guard let catId = category.id else { return }
        do {
            try await DatabaseManager.shared.updateCategory(
                id: catId, name: name, iconName: iconName
            )
            await load()
            NotificationCenter.default.post(
                name: .routeKeeperCategoriesChanged, object: nil
            )
        } catch {
            errorMessage = "Could not update category: \(error.localizedDescription)"
        }
    }

    // MARK: Delete

    /// Deletes a user-defined category and refreshes the list.
    ///
    /// The caller is responsible for confirming that the category is not in
    /// use before calling this method (the UI disables the button in that case).
    func deleteCategory(_ category: Category) async {
        guard let catId = category.id else { return }
        do {
            try await DatabaseManager.shared.deleteCategory(id: catId)
            await load()
            NotificationCenter.default.post(
                name: .routeKeeperCategoriesChanged, object: nil
            )
        } catch {
            errorMessage = "Could not delete category: \(error.localizedDescription)"
        }
    }
}
