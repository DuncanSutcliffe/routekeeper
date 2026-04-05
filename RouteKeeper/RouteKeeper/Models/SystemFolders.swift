//
//  SystemFolders.swift
//  RouteKeeper
//
//  Application-layer sentinel values for virtual system folders.
//  These have negative IDs that can never clash with database-generated
//  AUTOINCREMENT IDs (which start at 1). No database rows are created.
//

import Foundation

// MARK: - Unclassified folder

extension ListFolder {
    /// Virtual folder that collects every item with no ``item_list_membership`` row.
    ///
    /// Identified by `id == -1`. Always appended last in the sidebar, outside
    /// the user's sort preference.
    static let unclassified: ListFolder = {
        var f = ListFolder(name: "Unclassified")
        f.id = -1
        return f
    }()
}

// MARK: - Unclassified list

extension RouteList {
    /// Sentinel list that lives inside ``ListFolder.unclassified``.
    ///
    /// When ``LibraryViewModel/loadItems(for:)`` sees `id == -1` it calls
    /// ``DatabaseManager/fetchUnclassifiedItems()`` instead of the normal
    /// membership query.
    static let unclassified: RouteList = {
        var l = RouteList(name: "Unclassified Items")
        l.id = -1
        return l
    }()
}
