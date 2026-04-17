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
/// Seeded with twelve defaults on first run. Default categories are read-only
/// in the UI; users may create, edit, and delete their own categories.
struct Category: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"

    var id: Int64?
    var name: String
    /// SF Symbol name used to represent this category in the UI.
    var iconName: String
    /// `true` for the twelve seed categories that ship with the app.
    /// Default categories are read-only — no edit or delete in the UI.
    var isDefault: Bool = false
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""

    init(name: String, iconName: String, isDefault: Bool = false) {
        self.name      = name
        self.iconName  = iconName
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case iconName  = "icon_name"
        case isDefault = "is_default"
        case createdAt = "created_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]         = id
        container["name"]       = name
        container["icon_name"]  = iconName
        container["is_default"] = isDefault ? 1 : 0
        // created_at omitted — database provides default.
    }

    // MARK: Hashable — identity based on id only

    static func == (lhs: Category, rhs: Category) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Waypoint

/// A favourite point of interest stored independently of the library item system.
///
/// The primary key (`item_id`) is also a foreign key to `items.id`, so each
/// waypoint participates in the normal library membership system and can be
/// assigned to one or more lists via `item_list_membership`.
///
/// Each waypoint belongs to an optional ``Category`` and carries a map colour
/// expressed as a hex string (default `#E8453C`, the standard RouteKeeper red).
struct Waypoint: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "waypoints"

    /// Primary key — also the foreign key to `items.id`.
    var itemId: Int64
    /// Satisfies `Identifiable`; backed by `itemId`.
    var id: Int64 { itemId }

    var name: String
    var latitude: Double
    var longitude: Double
    /// Foreign key to `categories.id`; `nil` means uncategorised.
    var categoryId: Int64?
    /// Map pin colour as a CSS hex string, e.g. `"#E8453C"`.
    var colorHex: String
    var notes: String?
    /// Elevation in metres, fetched from the MapTiler Elevation API on creation
    /// or when the location is changed in the edit sheet. `nil` when unknown.
    var elevation: Double?

    // MARK: Address fields (from Nominatim; all nullable)

    var addressHouseNumber: String? = nil
    var addressRoad: String? = nil
    var addressSuburb: String? = nil
    var addressNeighbourhood: String? = nil
    var addressCity: String? = nil
    var addressMunicipality: String? = nil
    var addressCounty: String? = nil
    var addressStateDistrict: String? = nil
    var addressState: String? = nil
    var addressPostcode: String? = nil
    var addressCountry: String? = nil
    var addressCountryCode: String? = nil

    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""

    init(
        itemId: Int64,
        name: String,
        latitude: Double,
        longitude: Double,
        categoryId: Int64? = nil,
        colorHex: String = "#E8453C",
        notes: String? = nil,
        elevation: Double? = nil
    ) {
        self.itemId     = itemId
        self.name       = name
        self.latitude   = latitude
        self.longitude  = longitude
        self.categoryId = categoryId
        self.colorHex   = colorHex
        self.notes      = notes
        self.elevation  = elevation
    }

    enum CodingKeys: String, CodingKey {
        case itemId     = "item_id"
        case name, latitude, longitude
        case categoryId = "category_id"
        case colorHex   = "color_hex"
        case notes, elevation
        case addressHouseNumber  = "address_house_number"
        case addressRoad         = "address_road"
        case addressSuburb       = "address_suburb"
        case addressNeighbourhood = "address_neighbourhood"
        case addressCity         = "address_city"
        case addressMunicipality = "address_municipality"
        case addressCounty       = "address_county"
        case addressStateDistrict = "address_state_district"
        case addressState        = "address_state"
        case addressPostcode     = "address_postcode"
        case addressCountry      = "address_country"
        case addressCountryCode  = "address_country_code"
        case createdAt  = "created_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["item_id"]     = itemId
        container["name"]        = name
        container["latitude"]    = latitude
        container["longitude"]   = longitude
        container["category_id"] = categoryId
        container["color_hex"]   = colorHex
        container["notes"]       = notes
        container["elevation"]   = elevation
        container["address_house_number"]   = addressHouseNumber
        container["address_road"]           = addressRoad
        container["address_suburb"]         = addressSuburb
        container["address_neighbourhood"]  = addressNeighbourhood
        container["address_city"]           = addressCity
        container["address_municipality"]   = addressMunicipality
        container["address_county"]         = addressCounty
        container["address_state_district"] = addressStateDistrict
        container["address_state"]          = addressState
        container["address_postcode"]       = addressPostcode
        container["address_country"]        = addressCountry
        container["address_country_code"]   = addressCountryCode
        // created_at omitted — database provides default.
    }

    // MARK: Hashable — identity based on itemId only

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool { lhs.itemId == rhs.itemId }
    func hash(into hasher: inout Hasher) { hasher.combine(itemId) }
}
