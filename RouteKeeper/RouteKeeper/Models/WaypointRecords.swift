//
//  WaypointRecords.swift
//  RouteKeeper
//
//  GRDB record types for the categories and waypoints tables (schema v3).
//
//  Waypoints here are standalone favourite points of interest, independent
//  of the library item system. The `created_at` column is omitted from
//  encode(to:) so that SQLite's default applies on insert.
//

import Foundation
import GRDB

// MARK: - Category

/// A category used to classify favourite waypoints (e.g. Fuel, Hotel, Viewpoint).
///
/// Seeded with twelve defaults on first run; the user cannot create or delete
/// categories in the initial implementation.
struct Category: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"

    var id: Int64?
    var name: String
    /// SF Symbol name used to represent this category in the UI.
    var iconName: String
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""

    init(name: String, iconName: String) {
        self.name = name
        self.iconName = iconName
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconName  = "icon_name"
        case createdAt = "created_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]        = id
        container["name"]      = name
        container["icon_name"] = iconName
        // created_at omitted — database provides default.
    }

    // MARK: Hashable — identity based on id only

    static func == (lhs: Category, rhs: Category) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Waypoint

/// A favourite point of interest stored independently of the library item system.
///
/// Each waypoint belongs to an optional ``Category`` and carries a map colour
/// expressed as a hex string (default `#E8453C`, the standard RouteKeeper red).
struct Waypoint: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "waypoints"

    var id: Int64?
    var name: String
    var latitude: Double
    var longitude: Double
    /// Foreign key to `categories.id`; `nil` means uncategorised.
    var categoryId: Int64?
    /// Map pin colour as a CSS hex string, e.g. `"#E8453C"`.
    var colorHex: String
    var notes: String?
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        categoryId: Int64? = nil,
        colorHex: String = "#E8453C",
        notes: String? = nil
    ) {
        self.name       = name
        self.latitude   = latitude
        self.longitude  = longitude
        self.categoryId = categoryId
        self.colorHex   = colorHex
        self.notes      = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude
        case categoryId = "category_id"
        case colorHex   = "color_hex"
        case notes
        case createdAt  = "created_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]          = id
        container["name"]        = name
        container["latitude"]    = latitude
        container["longitude"]   = longitude
        container["category_id"] = categoryId
        container["color_hex"]   = colorHex
        container["notes"]       = notes
        // created_at omitted — database provides default.
    }

    // MARK: Hashable — identity based on id only

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
