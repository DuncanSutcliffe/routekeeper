//
//  LibraryModels.swift
//  RouteKeeper
//
//  Placeholder data models for the library sidebar.
//  These will be replaced by database-backed models once the schema is in place.
//

import Foundation

/// A named collection of routes, waypoints, or tracks.
struct RouteList: Identifiable, Hashable {
    let id: UUID
    let name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A folder that organises one or more lists hierarchically.
struct ListFolder: Identifiable {
    let id: UUID
    let name: String
    let lists: [RouteList]

    init(id: UUID = UUID(), name: String, lists: [RouteList]) {
        self.id = id
        self.name = name
        self.lists = lists
    }
}

// MARK: - Placeholder data

extension ListFolder {
    /// Hardcoded sample folders used while the database layer is not yet wired up.
    static let placeholders: [ListFolder] = [
        ListFolder(name: "Europe Tours", lists: [
            RouteList(name: "Alps Loop 2024"),
            RouteList(name: "Pyrenees Run"),
        ]),
        ListFolder(name: "Day Rides", lists: [
            RouteList(name: "Morning Coastal"),
            RouteList(name: "Peak District Loop"),
        ]),
    ]
}
