//
//  LibraryRecords.swift
//  RouteKeeper
//
//  GRDB record types for the list_folders, lists, and item_list_membership tables.
//
//  Replaces the placeholder structs that were in LibraryModels.swift.
//

import Foundation
import GRDB

// MARK: - ListFolder

/// A folder that organises one or more lists hierarchically.
///
/// Folders may be nested: `parentFolderId` references another `ListFolder`,
/// or is `nil` for top-level folders.
struct ListFolder: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "list_folders"

    var id: Int64?
    var name: String
    // TODO: [REFACTOR] parentFolderId is never set or read — folder nesting is not
    // implemented. The column exists in the schema but is dead weight.
    var parentFolderId: Int64?
    var sortOrder: Int
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""
    /// Populated by the database on insert; updated on modification.
    var modifiedAt: String = ""

    init(name: String, parentFolderId: Int64? = nil, sortOrder: Int = 0) {
        self.name = name
        self.parentFolderId = parentFolderId
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentFolderId = "parent_folder_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["parent_folder_id"] = parentFolderId
        container["sort_order"] = sortOrder
        // created_at and modified_at omitted — database provides defaults.
    }
}

// MARK: - RouteList

/// A named collection of routes, waypoints, or tracks.
///
/// Named `RouteList` rather than `List` to avoid colliding with SwiftUI's `List`.
/// Conforms to `Hashable` (identity based on `id`) so it can be used as a
/// `NavigationSplitView` / `List` selection value.
struct RouteList: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lists"

    var id: Int64?
    var name: String
    var folderId: Int64?
    // TODO: [REFACTOR] isSmart and smartRule are never read or written in any UI or
    // database path — dead abstraction for an unimplemented smart-lists feature.
    /// `true` for smart lists (auto-populated by `smartRule`); `false` for manual lists.
    var isSmart: Bool
    var smartRule: String?
    var sortOrder: Int
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""
    /// Populated by the database on insert; updated on modification.
    var modifiedAt: String = ""

    init(
        name: String,
        folderId: Int64? = nil,
        isSmart: Bool = false,
        smartRule: String? = nil,
        sortOrder: Int = 0
    ) {
        self.name = name
        self.folderId = folderId
        self.isSmart = isSmart
        self.smartRule = smartRule
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case folderId = "folder_id"
        case isSmart = "is_smart"
        case smartRule = "smart_rule"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["folder_id"] = folderId
        container["is_smart"] = isSmart
        container["smart_rule"] = smartRule
        container["sort_order"] = sortOrder
        // created_at and modified_at omitted — database provides defaults.
    }

    // MARK: Hashable — identity based on id only

    static func == (lhs: RouteList, rhs: RouteList) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - ItemListMembership

/// Records that an item belongs to a specific list (the junction table).
///
/// A single item can belong to multiple lists simultaneously via this table,
/// without duplicating the item's data.
struct ItemListMembership: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_list_membership"

    var itemId: Int64
    var listId: Int64
    var sortOrder: Int
    /// Populated by the database on insert; read back when fetched.
    var addedAt: String = ""

    init(itemId: Int64, listId: Int64, sortOrder: Int = 0) {
        self.itemId = itemId
        self.listId = listId
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case listId = "list_id"
        case sortOrder = "sort_order"
        case addedAt = "added_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["item_id"] = itemId
        container["list_id"] = listId
        container["sort_order"] = sortOrder
        // added_at omitted — database provides default.
    }
}
