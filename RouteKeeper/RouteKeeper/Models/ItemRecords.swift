//
//  ItemRecords.swift
//  RouteKeeper
//
//  GRDB record types for the items, routes, route_points, tracks,
//  and track_points tables.
//
//  The old satellite `waypoints` table (item_id → items.id) was dropped in
//  schema v3. The new standalone waypoints model lives in WaypointRecords.swift.
//
//  Columns with NOT NULL DEFAULT (datetime('now')) are omitted from
//  encode(to:) so that SQLite's default applies on insert.
//  They are still decoded when a record is fetched from the database.
//

import Foundation
import GRDB

// MARK: - ItemType

/// The kind of library item stored in the `items` table.
enum ItemType: String, Codable {
    case route
    case waypoint
    case track

    /// SF Symbol name used to represent this item type in the sidebar.
    var systemImage: String {
        switch self {
        case .route:    return "arrow.triangle.turn.up.right.diamond"
        case .waypoint: return "mappin"
        case .track:    return "scribble"
        }
    }
}

// MARK: - Item

/// A top-level library item (route, waypoint, or track).
///
/// The type-specific data lives in the corresponding satellite table
/// (`routes`, `waypoints`, or `tracks`) linked by `item_id`.
struct Item: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"

    var id: Int64?
    var type: ItemType
    var name: String
    var description: String?
    var colour: String?
    /// SF Symbol name for the waypoint's category, joined from `categories.icon_name`
    /// via `waypoints.category_id`. Nil for routes, tracks, and uncategorised waypoints.
    var categoryIcon: String?
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""
    /// Populated by the database on insert; updated on modification.
    var modifiedAt: String = ""

    init(type: ItemType, name: String, description: String? = nil, colour: String? = nil) {
        self.type = type
        self.name = name
        self.description = description
        self.colour = colour
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, colour
        case categoryIcon = "category_icon"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["type"] = type.rawValue
        container["name"] = name
        container["description"] = description
        container["colour"] = colour
        // categoryIcon, created_at, and modified_at omitted — read-only or DB-provided.
    }

    // Hashable — identity based on id only, matching the RouteList pattern.
    static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Route

/// Route-specific data, linked 1-to-1 with an `Item` via `item_id`.
///
/// Individual points are stored in `route_points` and linked by `route_item_id`.
struct Route: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "routes"

    /// Foreign key to `items.id`; also the primary key of this table.
    var itemId: Int64
    // TODO: [REFACTOR] `geojson` is a legacy field predating the `geometry` column (schema v5).
    // Verify it is no longer written or read, then drop the column in a new migration and
    // remove this property.
    /// Calculated GeoJSON LineString from the Valhalla response.
    var geojson: String?
    /// GeoJSON FeatureCollection string stored by the route-creation flow (schema v5).
    var geometry: String?
    var distanceKm: Double?
    var durationSeconds: Int?
    var routingProfile: String
    /// Name of the routing profile applied when the route was created or last edited.
    var appliedProfileName: String?
    var avoidMotorways: Bool
    var avoidTolls: Bool
    var avoidUnpaved: Bool
    var avoidFerries: Bool
    var shortestRoute: Bool
    /// CSS hex colour string used to draw this route on the map.
    var colorHex: String

    // TODO: [REFACTOR] "#1A73E8" (route default blue) is hardcoded here and in
    // DatabaseManager.createRoute(), LibraryViewModel.createRoute(), and
    // ContentView.handleSingleItemSelection(). Extract to a named constant in ColourSwatch.swift
    // or a dedicated Constants file (e.g. `RouteDefaultColorHex`).
    init(itemId: Int64, routingProfile: String = "motorcycle") {
        self.itemId = itemId
        self.routingProfile = routingProfile
        self.avoidMotorways = false
        self.avoidTolls     = false
        self.avoidUnpaved   = false
        self.avoidFerries   = false
        self.shortestRoute  = false
        self.colorHex       = "#1A73E8"
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case geojson
        case geometry
        case distanceKm = "distance_km"
        case durationSeconds = "duration_seconds"
        case routingProfile = "routing_profile"
        case appliedProfileName = "applied_profile_name"
        case avoidMotorways = "avoid_motorways"
        case avoidTolls     = "avoid_tolls"
        case avoidUnpaved   = "avoid_unpaved"
        case avoidFerries   = "avoid_ferries"
        case shortestRoute  = "shortest_route"
        case colorHex       = "color_hex"
    }
}

// MARK: - RoutePoint

/// A single point in a planned route, ordered by `sequence_number`.
struct RoutePoint: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "route_points"

    var id: Int64?
    var routeItemId: Int64
    var sequenceNumber: Int
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    /// `true` = via point (device announces arrival and shows a flag).
    /// `false` = shaping point (silent; influences the route shape only).
    var announcesArrival: Bool
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case routeItemId = "route_item_id"
        case sequenceNumber = "sequence_number"
        case latitude, longitude, elevation
        case announcesArrival = "announces_arrival"
        case name
    }
}

// MARK: - Track

/// Track-specific data, linked 1-to-1 with an `Item` via `item_id`.
///
/// Individual recorded points are stored in `track_points`.
struct Track: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tracks"

    /// Foreign key to `items.id`; also the primary key of this table.
    var itemId: Int64
    var geojson: String?
    var distanceMetres: Double?
    var durationSeconds: Int?
    var recordedAt: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case geojson
        case distanceMetres = "distance_metres"
        case durationSeconds = "duration_seconds"
        case recordedAt = "recorded_at"
    }
}

// MARK: - TrackPoint

/// A single point in a recorded GPS track, ordered by `sequence_number`.
struct TrackPoint: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track_points"

    var id: Int64?
    var trackItemId: Int64
    var sequenceNumber: Int
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var recordedAt: String?
    /// Speed in metres per second at the time this point was recorded.
    var speedMs: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case trackItemId = "track_item_id"
        case sequenceNumber = "sequence_number"
        case latitude, longitude, elevation
        case recordedAt = "recorded_at"
        case speedMs = "speed_ms"
    }
}
