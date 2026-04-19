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
        case .track:    return "point.bottomleft.forward.to.point.topright.scurvepath.fill"
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
    /// JSON-encoded array of elevation samples in metres, one every 30 m.
    /// `nil` when no elevation data was returned by Valhalla.
    var elevationProfile: String?
    /// Free-form notes attached to this route.
    var notes: String?
    /// Set to `true` when the route's waypoints have changed and a fresh
    /// Valhalla calculation is needed. Defaults to `false` on all existing rows.
    var needsRecalculation: Bool

    init(itemId: Int64, routingProfile: String = "motorcycle") {
        self.itemId = itemId
        self.routingProfile = routingProfile
        self.avoidMotorways = false
        self.avoidTolls     = false
        self.avoidUnpaved   = false
        self.avoidFerries   = false
        self.shortestRoute  = false
        self.colorHex       = "#1A73E8"
        self.needsRecalculation = false
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
        case elevationProfile = "elevation_profile"
        case notes
        case needsRecalculation = "needs_recalculation"
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
    /// Foreign key back to the library waypoint this point was created from.
    /// `nil` for all points created before migration v5, and for points added
    /// without a corresponding library waypoint.
    var waypointItemId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case routeItemId = "route_item_id"
        case sequenceNumber = "sequence_number"
        case latitude, longitude, elevation
        case announcesArrival = "announces_arrival"
        case name
        case waypointItemId = "waypoint_item_id"
    }
}

// MARK: - Track

/// Track-specific data, linked 1-to-1 with an `Item` via `item_id`.
///
/// Individual recorded points are stored in `track_points`.
struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "tracks"

    var id: Int64 { itemId }
    /// Foreign key to `items.id`; also the primary key of this table.
    var itemId: Int64
    var geojson: String?
    var distanceMetres: Double?
    var durationSeconds: Int?
    var recordedAt: String?
    /// CSS hex colour for the track line, e.g. `"#3E515A"`.
    var color: String
    /// Line rendering style — one of `"dotted"`, `"short_dash"`, `"long_dash"`, `"solid"`.
    var lineStyle: String

    init(itemId: Int64, color: String = "#3E515A", lineStyle: String = "solid") {
        self.itemId    = itemId
        self.color     = color
        self.lineStyle = lineStyle
    }

    /// MapLibre `line-dasharray` values for the stored line style.
    /// `nil` when `lineStyle == "solid"` (no dasharray property applied).
    var lineStyleDashArray: [Double]? {
        switch lineStyle {
        case "dotted":     return [1, 3]
        case "short_dash": return [4, 3]
        case "long_dash":  return [8, 4]
        default:           return nil
        }
    }

    /// The eight preset colours offered in TrackPropertiesSheet.
    static let presetColours: [String] = [
        "#972D27", "#975827", "#978C27", "#317234",
        "#114B97", "#651972", "#4F372F", "#3E515A",
    ]

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case geojson
        case distanceMetres  = "distance_metres"
        case durationSeconds = "duration_seconds"
        case recordedAt      = "recorded_at"
        case color
        case lineStyle       = "line_style"
    }
}

// MARK: - TrackWithPoints

/// A track record paired with its ordered point array.
///
/// Used for map display and GPX export.
struct TrackWithPoints {
    let track: Track
    let points: [TrackPoint]
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
    /// ISO 8601 timestamp from the GPX `<time>` element, or `nil` if absent.
    var timestamp: String?
    /// Speed in metres per second at the time this point was recorded.
    var speedMs: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case trackItemId    = "track_item_id"
        case sequenceNumber = "sequence_number"
        case latitude, longitude, elevation
        case recordedAt     = "recorded_at"
        case timestamp
        case speedMs        = "speed_ms"
    }
}
