//
//  DatabaseManager.swift
//  RouteKeeper
//
//  Opens, migrates, and provides access to the application's SQLite database.
//  Call setUp() once at launch before any other database access.
//

import Foundation
import GRDB

// MARK: - Error type

enum DatabaseManagerError: Error {
    /// setUp() has not been called before a database access was attempted.
    case notInitialised
    /// A required row was missing after a seeding insert.
    case seedingFailed(String)
    /// A user-initiated insert failed or the new row could not be retrieved.
    case insertFailed(String)
}

// TODO: [REFACTOR] WaypointSummary and WaypointListSection are presentation/model types
// that belong in Models/, not in DatabaseManager.swift.

// MARK: - WaypointSummary

/// Lightweight projection used by `WaypointPickerSheet` to list available
/// waypoints without pulling full `Waypoint` records.
struct WaypointSummary: Identifiable, Hashable {
    let itemId: Int64
    let name: String
    let latitude: Double
    let longitude: Double
    /// CSS hex colour string from the `color_hex` column, e.g. `"#E8453C"`.
    var colorHex: String = "#E8453C"
    /// Display name of the assigned category, or `nil` if uncategorised.
    var categoryName: String? = nil
    /// SF Symbol name of the assigned category, or `nil` if uncategorised.
    var categoryIconName: String? = nil
    /// Free-form notes attached to the waypoint, or `nil` if none.
    var notes: String? = nil
    /// Road name from the stored Nominatim address, or `nil` if absent.
    var addressRoad: String? = nil
    var addressSuburb: String? = nil
    var addressCity: String? = nil
    var addressState: String? = nil
    var addressPostcode: String? = nil
    var addressCountry: String? = nil

    var id: Int64 { itemId }
}

// MARK: - WaypointListSection

/// A single section in the grouped waypoint picker: one library list and its waypoints.
///
/// Waypoints that belong to no list appear in a section whose `listId` is `nil`
/// and whose `listName` is `"Unclassified"`.
struct WaypointListSection: Identifiable {
    let listId: Int64?
    let listName: String
    /// The name of the folder that contains this list, or `nil` for Unclassified.
    let folderName: String?
    /// Waypoints in this list that have coordinates, sorted alphabetically by name.
    let waypoints: [WaypointSummary]

    var id: String { listId.map { "list-\($0)" } ?? "unclassified" }
}

// MARK: - DatabaseManager

/// Manages the application's SQLite database.
///
/// Call ``setUp()`` once at application launch (from `ContentView.task` or the
/// `App` body). All subsequent reads and writes go through ``shared``.
actor DatabaseManager {

    // MARK: Singleton

    /// The shared database manager.
    static let shared = DatabaseManager()

    // MARK: State

    private var _dbQueue: DatabaseQueue?

    /// Internal so that unit tests can create isolated in-memory instances via
    /// ``makeInMemory()``. All production code uses ``shared``.
    init() {}

    // MARK: Setup

    /// Opens (or creates) the database file and applies any pending schema migrations.
    ///
    /// - Parameter path: SQLite file path. Pass `nil` (the default) to use the
    ///   standard Application Support location. Pass `":memory:"` for an isolated
    ///   in-memory database (used by unit tests via ``makeInMemory()``).
    ///
    /// Idempotent — safe to call more than once; subsequent calls return immediately.
    func setUp(path: String? = nil) async throws {
        guard _dbQueue == nil else { return }
        let dbQueue: DatabaseQueue
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try Self.openDatabaseQueue()
        }
        var migrator = DatabaseMigrator()

        // v1 — complete schema including routing_profiles.
        // This is the definitive single migration for fresh databases.
        migrator.registerMigration("v1") { db in
            try Self.createCompleteSchema(db)
            try Self.seedRoutingProfiles(db)
            try Self.seedCategories(db)
        }

        // v2 — adds elevation column to waypoints.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE waypoints ADD COLUMN elevation REAL")
        }

        // v3 — adds colour column to routes; default covers all existing rows.
        migrator.registerMigration("v3") { db in
            try db.execute(
                sql: "ALTER TABLE routes " +
                     "ADD COLUMN color_hex TEXT NOT NULL DEFAULT '#1A73E8'"
            )
        }

        // v4 — adds is_default flag to categories; marks the twelve seed rows.
        migrator.registerMigration("v4") { db in
            try db.execute(
                sql: "ALTER TABLE categories " +
                     "ADD COLUMN is_default INTEGER NOT NULL DEFAULT 0"
            )
            let defaultNames: [String] = [
                "Café", "Campsite", "Ferry", "Fuel", "Hotel",
                "Landmark", "Other", "Parking", "Pass",
                "Restaurant", "Viewpoint", "Workshop"
            ]
            for name in defaultNames {
                try db.execute(
                    sql: "UPDATE categories SET is_default = 1 WHERE name = ?",
                    arguments: [name]
                )
            }
        }

        // v5 — adds waypoint back-reference to route_points and recalculation
        //      flag to routes; both default to no-op values on existing rows.
        migrator.registerMigration("v5") { db in
            try db.execute(
                sql: "ALTER TABLE route_points " +
                     "ADD COLUMN waypoint_item_id INTEGER " +
                     "REFERENCES waypoints(item_id) ON DELETE SET NULL"
            )
            try db.execute(
                sql: "ALTER TABLE routes " +
                     "ADD COLUMN needs_recalculation INTEGER NOT NULL DEFAULT 0"
            )
        }

        // v6 — adds structured address columns to waypoints (from Nominatim).
        migrator.registerMigration("v6") { db in
            let cols = [
                "address_house_number", "address_road",
                "address_suburb",       "address_neighbourhood",
                "address_city",         "address_municipality",
                "address_county",       "address_state_district",
                "address_state",        "address_postcode",
                "address_country",      "address_country_code"
            ]
            for col in cols {
                try db.execute(sql: "ALTER TABLE waypoints ADD COLUMN \(col) TEXT")
            }
        }

        // v7 — adds colour and line-style to tracks; adds ISO 8601 timestamp
        //      to track_points for GPX import/export.
        migrator.registerMigration("v7") { db in
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN color TEXT NOT NULL DEFAULT '#3E515A'"
            )
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN line_style TEXT NOT NULL DEFAULT 'solid'"
            )
            try db.execute(
                sql: "ALTER TABLE track_points ADD COLUMN timestamp TEXT"
            )
        }

        try await migrator.migrate(dbQueue)
        _dbQueue = dbQueue
    }

    /// Creates a fresh `DatabaseManager` backed by an isolated in-memory SQLite
    /// database with all migrations applied.
    ///
    /// Each call returns a completely independent instance — suitable for use
    /// in unit tests where isolation between test cases is required.
    static func makeInMemory() async throws -> DatabaseManager {
        let db = DatabaseManager()
        try await db.setUp(path: ":memory:")
        return db
    }

    // MARK: - Queries

    /// Fetches all list folders paired with their contained lists.
    ///
    /// - Parameters:
    ///   - sortColumn: The `list_folders` column to sort by (`"name"` or `"created_at"`).
    ///   - ascending: `true` for A→Z / oldest-first; `false` for Z→A / newest-first.
    func fetchFoldersWithLists(
        sortColumn: String = "sort_order",
        ascending: Bool = true
    ) async throws -> [(ListFolder, [RouteList])] {
        let q = try requireQueue()
        return try await q.read { db in
            let order = ascending
                ? Column(sortColumn).asc
                : Column(sortColumn).desc
            let folders = try ListFolder.order(order).fetchAll(db)
            return try folders.map { folder in
                let lists = try RouteList
                    .filter(Column("folder_id") == folder.id)
                    .order(Column("sort_order"))
                    .fetchAll(db)
                return (folder, lists)
            }
        }
    }

    /// Inserts a new folder with the given name and returns it with its database-assigned id.
    @discardableResult
    func createFolder(name: String) async throws -> ListFolder {
        let q = try requireQueue()
        return try await q.write { db in
            try db.execute(
                sql: "INSERT INTO list_folders (name) VALUES (?)",
                arguments: [name]
            )
            guard let id = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.insertFailed("Could not retrieve new folder ID")
            }
            guard let folder = try ListFolder.fetchOne(
                db,
                sql: "SELECT * FROM list_folders WHERE id = ?",
                arguments: [id]
            ) else {
                throw DatabaseManagerError.insertFailed(
                    "Could not fetch newly created folder (id: \(id))"
                )
            }
            return folder
        }
    }

    /// Inserts a new list with the given name inside `folderId` and returns it
    /// with its database-assigned id.
    @discardableResult
    func createList(name: String, folderId: Int64) async throws -> RouteList {
        let q = try requireQueue()
        return try await q.write { db in
            try db.execute(
                sql: "INSERT INTO lists (name, folder_id) VALUES (?, ?)",
                arguments: [name, folderId]
            )
            guard let id = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.insertFailed("Could not retrieve new list ID")
            }
            guard let list = try RouteList.fetchOne(
                db,
                sql: "SELECT * FROM lists WHERE id = ?",
                arguments: [id]
            ) else {
                throw DatabaseManagerError.insertFailed(
                    "Could not fetch newly created list (id: \(id))"
                )
            }
            return list
        }
    }

    /// Fetches all categories ordered by name.
    func fetchCategories() async throws -> [Category] {
        let q = try requireQueue()
        return try await q.read { db in
            try Category.order(Column("name")).fetchAll(db)
        }
    }

    /// Fetches all favourite waypoints ordered by name.
    func fetchWaypoints() async throws -> [Waypoint] {
        let q = try requireQueue()
        return try await q.read { db in
            try Waypoint.order(Column("name")).fetchAll(db)
        }
    }

    /// Inserts a new waypoint and associates it with zero or more lists.
    ///
    /// Writes an `items` row (type = `"waypoint"`) first, then a `waypoints`
    /// row using the new item's id as the primary key. List associations are
    /// written to `item_list_membership`. The entire operation runs inside a
    /// single write transaction.
    @discardableResult
    func createWaypoint(
        name: String,
        latitude: Double,
        longitude: Double,
        elevation: Double?,
        categoryId: Int64?,
        colorHex: String,
        notes: String?,
        address: AddressData? = nil,
        listIds: [Int64]
    ) async throws -> Waypoint {
        let q = try requireQueue()
        return try await q.write { db in
            // 1. Insert into items (type = 'waypoint').
            try db.execute(
                sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                arguments: ["waypoint", name]
            )
            guard let itemId = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.insertFailed("Could not retrieve new item ID")
            }

            // 2. Insert waypoint-specific data, keyed on itemId.
            try db.execute(
                sql: "INSERT INTO waypoints " +
                     "(item_id, name, latitude, longitude, elevation, " +
                     "category_id, color_hex, notes, " +
                     "address_house_number, address_road, address_suburb, address_neighbourhood, " +
                     "address_city, address_municipality, address_county, address_state_district, " +
                     "address_state, address_postcode, address_country, address_country_code) " +
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [itemId, name, latitude, longitude, elevation,
                            categoryId, colorHex, notes,
                            address?.houseNumber, address?.road,
                            address?.suburb, address?.neighbourhood,
                            address?.city, address?.municipality,
                            address?.county, address?.stateDistrict,
                            address?.state, address?.postcode,
                            address?.country, address?.countryCode]
            )

            // 3. Associate with requested lists.
            for listId in listIds {
                try db.execute(
                    sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                    arguments: [itemId, listId]
                )
            }

            // 4. Fetch and return the persisted record.
            guard let waypoint = try Waypoint.fetchOne(
                db,
                sql: "SELECT * FROM waypoints WHERE item_id = ?",
                arguments: [itemId]
            ) else {
                throw DatabaseManagerError.insertFailed(
                    "Could not fetch newly created waypoint (item_id: \(itemId))"
                )
            }
            return waypoint
        }
    }

    /// Returns the stored GeoJSON geometry string for the given route item id,
    /// or `nil` if no row exists or the geometry column is NULL.
    func fetchRouteGeometry(itemId: Int64) async throws -> String? {
        let q = try requireQueue()
        return try await q.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT geometry FROM routes WHERE item_id = ?",
                arguments: [itemId]
            )
        }
    }

    /// Returns the `Route` record for the given item id, or `nil` if none exists.
    func fetchRouteRecord(itemId: Int64) async throws -> Route? {
        let q = try requireQueue()
        return try await q.read { db in
            try Route.fetchOne(
                db,
                sql: "SELECT * FROM routes WHERE item_id = ?",
                arguments: [itemId]
            )
        }
    }

    /// Returns all `RoutePoint` rows for the given route item, ordered by sequence number.
    func fetchRoutePoints(routeItemId: Int64) async throws -> [RoutePoint] {
        let q = try requireQueue()
        return try await q.read { db in
            try RoutePoint.fetchAll(
                db,
                sql: """
                    SELECT * FROM route_points
                    WHERE route_item_id = ?
                    ORDER BY sequence_number ASC
                    """,
                arguments: [routeItemId]
            )
        }
    }

    /// Returns a lightweight summary of every waypoint that has coordinates,
    /// ordered by name.  Used by `WaypointPickerSheet` in the route-edit flow.
    func fetchAllWaypoints() async throws -> [WaypointSummary] {
        let q = try requireQueue()
        return try await q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.item_id, i.name, w.latitude, w.longitude
                FROM waypoints w
                JOIN items i ON i.id = w.item_id
                WHERE w.latitude IS NOT NULL AND w.longitude IS NOT NULL
                ORDER BY i.name ASC
                """)
            return rows.map {
                WaypointSummary(
                    itemId:    $0["item_id"],
                    name:      $0["name"],
                    latitude:  $0["latitude"],
                    longitude: $0["longitude"]
                )
            }
        }
    }

    /// Fetches all coordinate-bearing waypoints grouped by library list membership.
    ///
    /// Waypoints belonging to multiple lists appear in each relevant section.
    /// Waypoints not in any list appear in a trailing "Unclassified" section.
    /// Sections are ordered by list `sort_order`; within each section waypoints
    /// are sorted alphabetically by name.
    func fetchWaypointsByList() async throws -> [WaypointListSection] {
        let q = try requireQueue()
        return try await q.read { db in
            // Left-join to list membership so unclassified waypoints appear with
            // NULL list columns.  CASE WHEN pushes the NULL (unclassified) rows to
            // the end without requiring NULLS LAST syntax.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    w.item_id, i.name AS waypoint_name,
                    w.latitude, w.longitude,
                    COALESCE(w.color_hex, '#E8453C') AS color_hex,
                    w.notes,
                    c.name AS category_name, c.icon_name AS category_icon,
                    l.id AS list_id, l.name AS list_name,
                    l.sort_order AS list_sort,
                    f.name AS folder_name,
                    w.address_road, w.address_suburb, w.address_city,
                    w.address_state, w.address_postcode, w.address_country
                FROM waypoints w
                JOIN items i ON i.id = w.item_id
                LEFT JOIN categories c ON c.id = w.category_id
                LEFT JOIN item_list_membership m ON m.item_id = w.item_id
                LEFT JOIN lists l ON l.id = m.list_id
                LEFT JOIN list_folders f ON f.id = l.folder_id
                WHERE w.latitude IS NOT NULL AND w.longitude IS NOT NULL
                ORDER BY
                    CASE WHEN l.id IS NULL THEN 1 ELSE 0 END ASC,
                    l.sort_order ASC,
                    l.name ASC,
                    i.name ASC
                """)

            // Group into sections while preserving the SQL ordering.
            var orderedKeys: [String] = []
            var sectionData: [String: (
                listId: Int64?,
                listName: String,
                folderName: String?,
                waypoints: [WaypointSummary]
            )] = [:]

            for row in rows {
                let itemId: Int64       = row["item_id"]
                let wpName: String      = row["waypoint_name"]
                let latitude: Double    = row["latitude"]
                let longitude: Double   = row["longitude"]
                let colorHex: String    = row["color_hex"]
                let notes: String?      = row["notes"]
                let catName: String?      = row["category_name"]
                let catIcon: String?      = row["category_icon"]
                let listId: Int64?        = row["list_id"]
                let listName: String?     = row["list_name"]
                let folderName: String?   = row["folder_name"]
                let addressRoad: String?     = row["address_road"]
                let addressSuburb: String?   = row["address_suburb"]
                let addressCity: String?     = row["address_city"]
                let addressState: String?    = row["address_state"]
                let addressPostcode: String? = row["address_postcode"]
                let addressCountry: String?  = row["address_country"]

                let sectionKey = listId.map { "list-\($0)" } ?? "unclassified"
                let waypoint = WaypointSummary(
                    itemId:           itemId,
                    name:             wpName,
                    latitude:         latitude,
                    longitude:        longitude,
                    colorHex:         colorHex,
                    categoryName:     catName,
                    categoryIconName: catIcon,
                    notes:            notes,
                    addressRoad:      addressRoad,
                    addressSuburb:    addressSuburb,
                    addressCity:      addressCity,
                    addressState:     addressState,
                    addressPostcode:  addressPostcode,
                    addressCountry:   addressCountry
                )

                if sectionData[sectionKey] == nil {
                    orderedKeys.append(sectionKey)
                    sectionData[sectionKey] = (
                        listId:     listId,
                        listName:   listName ?? "Unclassified",
                        folderName: folderName,
                        waypoints:  []
                    )
                }
                sectionData[sectionKey]!.waypoints.append(waypoint)
            }

            return orderedKeys.map { key in
                let s = sectionData[key]!
                return WaypointListSection(
                    listId:     s.listId,
                    listName:   s.listName,
                    folderName: s.folderName,
                    waypoints:  s.waypoints
                )
            }
        }
    }

    /// Fetches all waypoints that have coordinate rows in the `waypoints` table,
    /// ordered by name.  Used to populate the start/end point pickers in `NewRouteSheet`.
    func fetchWaypointsWithCoordinates() async throws -> [Waypoint] {
        let q = try requireQueue()
        return try await q.read { db in
            try Waypoint.fetchAll(db, sql: """
                SELECT * FROM waypoints
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                ORDER BY name
                """)
        }
    }

    /// Inserts a new route item, its geometry, optional start/end route points,
    /// and optional list memberships — all in a single write transaction.
    ///
    /// Returns the database-assigned `items.id` for the new route.
    @discardableResult
    func createRoute(
        name: String,
        geometry: String,
        distanceKm: Double? = nil,
        durationSeconds: Int? = nil,
        listIds: [Int64],
        startWaypoint: Waypoint? = nil,
        endWaypoint: Waypoint? = nil,
        appliedProfileName: String? = nil,
        avoidMotorways: Bool = false,
        avoidTolls: Bool = false,
        avoidUnpaved: Bool = false,
        avoidFerries: Bool = false,
        shortestRoute: Bool = false,
        colorHex: String = "#1A73E8",
        elevationProfile: String? = nil
    ) async throws -> Int64 {
        let q = try requireQueue()
        return try await q.write { db in
            // 1. Insert into items (type = 'route').
            try db.execute(
                sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                arguments: ["route", name]
            )
            guard let itemId = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.insertFailed("Could not retrieve new item ID")
            }

            // 2. Insert route-specific data including applied profile criteria.
            try db.execute(
                sql: "INSERT INTO routes " +
                     "(item_id, routing_profile, geometry, distance_km, duration_seconds, " +
                     "applied_profile_name, avoid_motorways, avoid_tolls, " +
                     "avoid_unpaved, avoid_ferries, shortest_route, color_hex, " +
                     "elevation_profile) " +
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [itemId, "motorcycle", geometry, distanceKm, durationSeconds,
                            appliedProfileName,
                            avoidMotorways ? 1 : 0, avoidTolls ? 1 : 0,
                            avoidUnpaved ? 1 : 0, avoidFerries ? 1 : 0,
                            shortestRoute ? 1 : 0, colorHex, elevationProfile]
            )

            // 3. Insert route_points for start (seq 1) and end (seq 2) if supplied.
            if let start = startWaypoint {
                try db.execute(
                    sql: """
                        INSERT INTO route_points
                            (route_item_id, sequence_number, latitude, longitude,
                             announces_arrival, name, waypoint_item_id)
                        VALUES (?, 1, ?, ?, 1, ?, ?)
                        """,
                    arguments: [itemId, start.latitude, start.longitude,
                                start.name, start.itemId]
                )
            }
            if let end = endWaypoint {
                try db.execute(
                    sql: """
                        INSERT INTO route_points
                            (route_item_id, sequence_number, latitude, longitude,
                             announces_arrival, name, waypoint_item_id)
                        VALUES (?, 2, ?, ?, 1, ?, ?)
                        """,
                    arguments: [itemId, end.latitude, end.longitude,
                                end.name, end.itemId]
                )
            }

            // 4. Associate with requested lists.
            for listId in listIds {
                try db.execute(
                    sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                    arguments: [itemId, listId]
                )
            }

            return itemId
        }
    }

    /// Replaces the route points for an existing route and updates its stored geometry.
    ///
    /// All existing `route_points` rows for `routeItemId` are deleted, then the
    /// supplied points are re-inserted with `sequence_number` set to their array
    /// index (0-based). The `routes` row is updated with the new geometry and
    /// optional distance / duration values. All changes execute in one transaction.
    func updateRoutePoints(
        _ points: [RoutePoint],
        routeItemId: Int64,
        geometry: String,
        distanceKm: Double?,
        durationSeconds: Int?,
        elevationProfile: String? = nil
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            // 1. Remove old points.
            try db.execute(
                sql: "DELETE FROM route_points WHERE route_item_id = ?",
                arguments: [routeItemId]
            )

            // 2. Re-insert with fresh sequence numbers.
            for (index, point) in points.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO route_points
                            (route_item_id, sequence_number, latitude, longitude,
                             elevation, announces_arrival, name, waypoint_item_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        routeItemId,
                        index,
                        point.latitude,
                        point.longitude,
                        point.elevation,
                        point.announcesArrival ? 1 : 0,
                        point.name,
                        point.waypointItemId
                    ]
                )
            }

            // 3. Update the route record.
            try db.execute(
                sql: """
                    UPDATE routes
                    SET geometry = ?,
                        distance_km = ?,
                        duration_seconds = ?,
                        elevation_profile = ?
                    WHERE item_id = ?
                    """,
                arguments: [geometry, distanceKm, durationSeconds,
                            elevationProfile, routeItemId]
            )
        }
    }

    /// Moves a single route point to new coordinates.
    ///
    /// Matches the row by both `route_item_id` and `sequence_number` so exactly
    /// one row is affected. Used after a map drag to persist the dropped position
    /// before re-routing through Valhalla.
    func updateRoutePointPosition(
        routeItemId: Int64,
        sequenceNumber: Int,
        latitude: Double,
        longitude: Double
    ) async throws {
        let coordinateName = String(format: "%.4f, %.4f", latitude, longitude)
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: """
                    UPDATE route_points
                    SET latitude = ?, longitude = ?,
                        waypoint_item_id = NULL, name = ?
                    WHERE route_item_id = ? AND sequence_number = ?
                    """,
                arguments: [latitude, longitude, coordinateName,
                            routeItemId, sequenceNumber]
            )
        }
    }

    /// Updates the `geometry`, `distance_km`, and `duration_seconds` columns on the
    /// given route row in a single write transaction.
    ///
    /// Used after a Valhalla recalculation to persist the new GeoJSON and stats
    /// without touching waypoints or other route metadata.
    func updateRouteGeometryAndStats(
        itemId: Int64,
        geometry: String,
        distanceKm: Double?,
        durationSeconds: Int?,
        elevationProfile: String? = nil
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE routes " +
                     "SET geometry = ?, distance_km = ?, duration_seconds = ?, " +
                     "elevation_profile = ?, needs_recalculation = 0 " +
                     "WHERE item_id = ?",
                arguments: [geometry, distanceKm, durationSeconds,
                            elevationProfile, itemId]
            )
        }
    }

    /// Updates the route name (in `items`), colour, and all five routing criteria
    /// columns (in `routes`) in a single write transaction.
    func updateRouteProperties(
        itemId: Int64,
        name: String,
        appliedProfileName: String?,
        avoidMotorways: Bool,
        avoidTolls: Bool,
        avoidUnpaved: Bool,
        avoidFerries: Bool,
        shortestRoute: Bool,
        colorHex: String
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE items SET name = ? WHERE id = ?",
                arguments: [name, itemId]
            )
            try db.execute(
                sql: "UPDATE routes " +
                     "SET applied_profile_name = ?, " +
                     "avoid_motorways = ?, avoid_tolls = ?, " +
                     "avoid_unpaved = ?, avoid_ferries = ?, shortest_route = ?, " +
                     "color_hex = ? " +
                     "WHERE item_id = ?",
                arguments: [appliedProfileName,
                            avoidMotorways ? 1 : 0, avoidTolls ? 1 : 0,
                            avoidUnpaved ? 1 : 0, avoidFerries ? 1 : 0,
                            shortestRoute ? 1 : 0, colorHex, itemId]
            )
        }
    }

    /// Returns the waypoint row for the given item id, or `nil` if no row exists.
    func fetchWaypointDetails(itemId: Int64) async throws -> Waypoint? {
        let q = try requireQueue()
        return try await q.read { db in
            try Waypoint.fetchOne(
                db,
                sql: "SELECT * FROM waypoints WHERE item_id = ?",
                arguments: [itemId]
            )
        }
    }

    /// Updates an existing waypoint's name, location, and details, then reconciles
    /// its list memberships — all inside a single write transaction.
    ///
    /// - Parameters:
    ///   - addListIds: Membership rows to insert (newly checked lists).
    ///   - removeListIds: Membership rows to delete (unchecked lists).
    func updateWaypoint(
        itemId: Int64,
        name: String,
        latitude: Double,
        longitude: Double,
        elevation: Double?,
        categoryId: Int64?,
        colorHex: String,
        notes: String?,
        address: AddressData? = nil,
        addListIds: Set<Int64>,
        removeListIds: Set<Int64>
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            // 1. Update the item name.
            try db.execute(
                sql: "UPDATE items SET name = ? WHERE id = ?",
                arguments: [name, itemId]
            )
            // 2. Update the waypoint-specific row.
            try db.execute(
                sql: "UPDATE waypoints " +
                     "SET name = ?, latitude = ?, longitude = ?, elevation = ?, " +
                     "category_id = ?, color_hex = ?, notes = ?, " +
                     "address_house_number = ?, address_road = ?, " +
                     "address_suburb = ?, address_neighbourhood = ?, " +
                     "address_city = ?, address_municipality = ?, " +
                     "address_county = ?, address_state_district = ?, " +
                     "address_state = ?, address_postcode = ?, " +
                     "address_country = ?, address_country_code = ? " +
                     "WHERE item_id = ?",
                arguments: [name, latitude, longitude, elevation,
                            categoryId, colorHex, notes,
                            address?.houseNumber, address?.road,
                            address?.suburb, address?.neighbourhood,
                            address?.city, address?.municipality,
                            address?.county, address?.stateDistrict,
                            address?.state, address?.postcode,
                            address?.country, address?.countryCode,
                            itemId]
            )
            // 3. Remove memberships for lists the user unchecked.
            for listId in removeListIds {
                try db.execute(
                    sql: "DELETE FROM item_list_membership " +
                         "WHERE item_id = ? AND list_id = ?",
                    arguments: [itemId, listId]
                )
            }
            // 4. Add memberships for lists the user checked.
            for listId in addListIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO item_list_membership " +
                         "(item_id, list_id) VALUES (?, ?)",
                    arguments: [itemId, listId]
                )
            }
        }
    }

    /// Updates the latitude and longitude of an existing waypoint.
    ///
    /// Only position columns are touched; name, colour, category, and notes are
    /// unchanged. Used after the user drags the waypoint marker on the map.
    func updateWaypointPosition(
        itemId: Int64,
        latitude: Double,
        longitude: Double
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE waypoints " +
                     "SET latitude = ?, longitude = ? " +
                     "WHERE item_id = ?",
                arguments: [latitude, longitude, itemId]
            )
        }
    }

    /// Overwrites only the twelve address columns for the given waypoint.
    ///
    /// All other waypoint fields are untouched. Empty strings are stored as NULL
    /// (callers should pass `nil` rather than `""` for absent values).
    func updateWaypointAddress(itemId: Int64, address: AddressData) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE waypoints " +
                     "SET address_house_number = ?, address_road = ?, " +
                     "address_suburb = ?, address_neighbourhood = ?, " +
                     "address_city = ?, address_municipality = ?, " +
                     "address_county = ?, address_state_district = ?, " +
                     "address_state = ?, address_postcode = ?, " +
                     "address_country = ?, address_country_code = ? " +
                     "WHERE item_id = ?",
                arguments: [
                    address.houseNumber, address.road,
                    address.suburb, address.neighbourhood,
                    address.city, address.municipality,
                    address.county, address.stateDistrict,
                    address.state, address.postcode,
                    address.country, address.countryCode,
                    itemId
                ]
            )
        }
    }

    /// Returns all routes that contain a `route_points` row referencing the given
    /// waypoint item, together with the route's display name.
    ///
    /// Used after a library waypoint is moved on the map to ask the user whether
    /// dependent routes should have their via/shaping positions updated.
    func fetchRoutesContainingWaypoint(
        itemId: Int64
    ) async throws -> [(routeItemId: Int64, routeName: String)] {
        let q = try requireQueue()
        return try await q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT rp.route_item_id, i.name " +
                     "FROM route_points rp " +
                     "JOIN items i ON i.id = rp.route_item_id " +
                     "WHERE rp.waypoint_item_id = ? " +
                     "ORDER BY i.name",
                arguments: [itemId]
            )
            return rows.map {
                (routeItemId: $0["route_item_id"] as Int64,
                 routeName:   $0["name"]          as String)
            }
        }
    }

    /// Updates the position of every `route_points` row that references the
    /// given waypoint item, then marks each affected route as needing
    /// recalculation.
    ///
    /// Both operations execute in a single write transaction. The
    /// `needs_recalculation` flag is set to `1`; Valhalla recalculation itself
    /// is not performed here and must be triggered separately.
    func updateRoutePointsForWaypoint(
        waypointItemId: Int64,
        latitude: Double,
        longitude: Double
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE route_points " +
                     "SET latitude = ?, longitude = ? " +
                     "WHERE waypoint_item_id = ?",
                arguments: [latitude, longitude, waypointItemId]
            )
            try db.execute(
                sql: "UPDATE routes SET needs_recalculation = 1 " +
                     "WHERE item_id IN (" +
                     "    SELECT DISTINCT route_item_id " +
                     "    FROM route_points WHERE waypoint_item_id = ?" +
                     ")",
                arguments: [waypointItemId]
            )
        }
    }

    /// Fetches all items that have no row in `item_list_membership`, ordered by name.
    ///
    /// LEFT JOINs with `waypoints` and `categories` promote `waypoints.color_hex`
    /// into `colour` and `categories.icon_name` into `category_icon` for waypoint rows.
    /// Routes and tracks have no waypoints row, so both joined columns remain NULL.
    func fetchUnclassifiedItems() async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.id,
                       items.type,
                       items.name,
                       items.description,
                       COALESCE(w.color_hex, t.color, items.colour) AS colour,
                       c.icon_name AS category_icon,
                       items.created_at,
                       items.modified_at
                FROM items
                LEFT JOIN waypoints  w ON items.id = w.item_id
                LEFT JOIN categories c ON w.category_id = c.id
                LEFT JOIN tracks     t ON items.id = t.item_id
                WHERE items.id NOT IN (SELECT item_id FROM item_list_membership)
                ORDER BY items.name
                """)
        }
    }

    /// Copies an item into a list by inserting a membership row.
    ///
    /// Uses `INSERT OR IGNORE` so this is a no-op if the item is already a
    /// member of the target list.
    func copyItemToList(itemId: Int64, targetListId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                arguments: [itemId, targetListId]
            )
        }
    }

    /// Moves an item from one list to another in a single write transaction.
    ///
    /// Calling this with `sourceListId == targetListId` is a no-op.
    func moveItemBetweenLists(
        itemId: Int64,
        sourceListId: Int64,
        targetListId: Int64
    ) async throws {
        guard sourceListId != targetListId else { return }
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM item_list_membership WHERE item_id = ? AND list_id = ?",
                arguments: [itemId, sourceListId]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                arguments: [itemId, targetListId]
            )
        }
    }

    /// Fetches all items belonging to the given list, ordered by name.
    ///
    /// LEFT JOINs with `waypoints` and `categories` promote `waypoints.color_hex`
    /// into `colour` and `categories.icon_name` into `category_icon` for waypoint rows.
    func fetchItems(for listId: Int64) async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.id,
                       items.type,
                       items.name,
                       items.description,
                       COALESCE(w.color_hex, t.color, items.colour) AS colour,
                       c.icon_name AS category_icon,
                       items.created_at,
                       items.modified_at
                FROM items
                JOIN item_list_membership
                  ON items.id = item_list_membership.item_id
                LEFT JOIN waypoints  w ON items.id = w.item_id
                LEFT JOIN categories c ON w.category_id = c.id
                LEFT JOIN tracks     t ON items.id = t.item_id
                WHERE item_list_membership.list_id = ?
                ORDER BY items.name
                """, arguments: [listId])
        }
    }

    /// Returns the set of list IDs that `itemId` currently belongs to.
    func fetchListIds(for itemId: Int64) async throws -> Set<Int64> {
        let q = try requireQueue()
        return try await q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT list_id FROM item_list_membership WHERE item_id = ?",
                arguments: [itemId]
            )
            return Set(rows.map { $0["list_id"] as Int64 })
        }
    }

    // MARK: - List membership removal and item deletion

    /// Removes a single list membership row for the given item.
    func removeItemFromList(itemId: Int64, listId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM item_list_membership WHERE item_id = ? AND list_id = ?",
                arguments: [itemId, listId]
            )
        }
    }

    /// Permanently deletes an item and all its associated data.
    ///
    /// All related rows in `waypoints`, `routes`, `tracks`, and
    /// `item_list_membership` are removed automatically by their ON DELETE CASCADE
    /// foreign keys.
    func deleteItem(itemId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM items WHERE id = ?",
                arguments: [itemId]
            )
        }
    }

    /// Returns the number of items currently assigned to `listId`.
    func fetchListItemCount(listId: Int64) async throws -> Int {
        let q = try requireQueue()
        return try await q.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM item_list_membership WHERE list_id = ?",
                arguments: [listId]
            ) ?? 0
        }
    }

    /// Permanently deletes a list.
    func deleteList(listId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM lists WHERE id = ?",
                arguments: [listId]
            )
        }
    }

    /// Returns `true` if any list within `folderId` has at least one item.
    func folderHasItems(folderId: Int64) async throws -> Bool {
        let q = try requireQueue()
        return try await q.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM item_list_membership
                    WHERE list_id IN (SELECT id FROM lists WHERE folder_id = ?)
                    """,
                arguments: [folderId]
            ) ?? 0
            return count > 0
        }
    }

    /// Permanently deletes a folder and all lists it contains.
    func deleteFolder(folderId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM lists WHERE folder_id = ?",
                arguments: [folderId]
            )
            try db.execute(
                sql: "DELETE FROM list_folders WHERE id = ?",
                arguments: [folderId]
            )
        }
    }

    /// Renames a folder.
    ///
    /// Throws a SQLITE_CONSTRAINT error if another folder with the same name
    /// already exists (enforced by the UNIQUE constraint on `list_folders.name`).
    func renameFolder(folderId: Int64, newName: String) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE list_folders SET name = ? WHERE id = ?",
                arguments: [newName, folderId]
            )
        }
    }

    /// Updates a list's name and folder assignment in a single write.
    ///
    /// Throws a SQLITE_CONSTRAINT error if a list with the same name already
    /// exists in the target folder (enforced by the UNIQUE constraint on
    /// `lists(name, folder_id)`).
    func updateList(listId: Int64, newName: String, newFolderId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE lists SET name = ?, folder_id = ? WHERE id = ?",
                arguments: [newName, newFolderId, listId]
            )
        }
    }

    /// Moves a list to a different folder without changing its name.
    func moveList(listId: Int64, toFolderId: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE lists SET folder_id = ? WHERE id = ?",
                arguments: [toFolderId, listId]
            )
        }
    }

    // MARK: - Routing profiles

    /// Returns all routing profiles ordered by name.
    func fetchRoutingProfiles() async throws -> [RoutingProfile] {
        let q = try requireQueue()
        return try await q.read { db in
            try RoutingProfile.order(Column("name")).fetchAll(db)
        }
    }

    /// Returns the profile whose `is_default` column is 1, or `nil` if none is set.
    func fetchDefaultRoutingProfile() async throws -> RoutingProfile? {
        let q = try requireQueue()
        return try await q.read { db in
            try RoutingProfile.fetchOne(
                db,
                sql: "SELECT * FROM routing_profiles WHERE is_default = 1"
            )
        }
    }

    /// Inserts a new profile or updates an existing one (matched on `id`).
    func saveRoutingProfile(_ profile: RoutingProfile) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try profile.save(db)
        }
    }

    /// Permanently deletes the routing profile with the given id.
    func deleteRoutingProfile(id: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM routing_profiles WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Sets `is_default = 1` on the given profile and `is_default = 0` on all
    /// others, in a single write transaction.
    func setDefaultRoutingProfile(id: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE routing_profiles SET is_default = 0"
            )
            try db.execute(
                sql: "UPDATE routing_profiles SET is_default = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - App Settings

    // TODO: [REFACTOR] app_settings key strings ("map_style", "units", "defaultExportFormat",
    // "selected_list_id", "selected_item_ids") are scattered as raw literals. Define them as
    // constants so typos produce compiler errors.

    /// Returns the value stored for `key` in `app_settings`, or `nil` if no row exists.
    func fetchSetting(key: String) async throws -> String? {
        let q = try requireQueue()
        return try await q.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [key]
            )
            return row?["value"] as String?
        }
    }

    /// Returns the stored map style name from `app_settings`, defaulting to `"streets-v4"`.
    func loadMapStyle() async -> String {
        return (try? await fetchSetting(key: "map_style")) ?? "streets-v4"
    }

    /// Persists the map style name to `app_settings`.
    func saveMapStyle(_ style: String) async throws {
        try await saveSetting(key: "map_style", value: style)
    }

    /// Returns the persisted sidebar selection state from `app_settings`.
    ///
    /// Returns `(nil, [])` when no state has been saved or the stored values are absent.
    func fetchSessionState() async -> (listId: Int64?, itemIds: [Int64]) {
        let listIdStr  = (try? await fetchSetting(key: "selected_list_id"))  ?? ""
        let itemIdsStr = (try? await fetchSetting(key: "selected_item_ids")) ?? "[]"
        let listId: Int64? = listIdStr.isEmpty ? nil : Int64(listIdStr)
        let itemIds: [Int64]
        if let data = itemIdsStr.data(using: .utf8),
           let arr = try? JSONDecoder().decode([Int64].self, from: data) {
            itemIds = arr
        } else {
            itemIds = []
        }
        return (listId, itemIds)
    }

    /// Persists the sidebar selection state to `app_settings`.
    ///
    /// Pass `nil` for `listId` to record that no list is selected.
    /// An empty `itemIds` array is stored as `"[]"` so reads always decode cleanly.
    func saveSessionState(listId: Int64?, itemIds: [Int64]) async {
        let listIdValue = listId.map { String($0) } ?? ""
        let itemIdsValue: String
        if let data = try? JSONEncoder().encode(itemIds),
           let str = String(data: data, encoding: .utf8) {
            itemIdsValue = str
        } else {
            itemIdsValue = "[]"
        }
        try? await saveSetting(key: "selected_list_id", value: listIdValue)
        try? await saveSetting(key: "selected_item_ids", value: itemIdsValue)
    }

    /// Writes `value` for `key` into `app_settings`, inserting or replacing any existing row.
    func saveSetting(key: String, value: String) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - GPX Import

    /// Imports a parsed GPX result into the database, assigning all created items
    /// to `listId`.
    ///
    /// - For each ``ParsedWaypoint``: inserts an `items` row, a `waypoints` row,
    ///   and a membership row. Duplicate item names are suffixed with `(1)`, `(2)`, …
    ///
    /// - For each ``ParsedRoute``: inserts an `items` row, a `routes` row with
    ///   `geometry = NULL` and `needs_recalculation = 1` (so Valhalla runs on first
    ///   display), and `route_points` rows in sequence order. Waypoint records are
    ///   also created for the first and last route points and added to the list.
    ///
    /// - Returns: A tuple of (routeCount, waypointCount, listName) for the
    ///   confirmation message shown to the user.
    // TODO: [REFACTOR] The doc comment above is a dangling stub for importGPXResult
    // (the actual implementation is below at the second "MARK: - GPX Import"). Clean up
    // the duplicate MARK and orphaned doc comment.
    // MARK: - Track operations

    /// Returns the `Track` record for the given item id, or `nil` if none exists.
    func fetchTrack(itemId: Int64) async throws -> Track? {
        let q = try requireQueue()
        return try await q.read { db in
            try Track.fetchOne(
                db,
                sql: "SELECT * FROM tracks WHERE item_id = ?",
                arguments: [itemId]
            )
        }
    }

    /// Returns the track and its ordered points, or `nil` if no track row exists.
    func fetchTrackWithPoints(itemId: Int64) async throws -> TrackWithPoints? {
        let q = try requireQueue()
        return try await q.read { db in
            guard let track = try Track.fetchOne(
                db,
                sql: "SELECT * FROM tracks WHERE item_id = ?",
                arguments: [itemId]
            ) else { return nil }
            let points = try TrackPoint.fetchAll(
                db,
                sql: """
                    SELECT * FROM track_points
                    WHERE track_item_id = ?
                    ORDER BY sequence_number ASC
                    """,
                arguments: [itemId]
            )
            return TrackWithPoints(track: track, points: points)
        }
    }

    /// Updates the track's name (in `items`), colour, and line style.
    func updateTrackProperties(
        itemId: Int64,
        name: String,
        color: String,
        lineStyle: String
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE items SET name = ? WHERE id = ?",
                arguments: [name, itemId]
            )
            try db.execute(
                sql: "UPDATE tracks SET color = ?, line_style = ? WHERE item_id = ?",
                arguments: [color, lineStyle, itemId]
            )
        }
    }

    // MARK: - GPX Import

    @discardableResult
    func importGPXResult(
        _ result: GPXImportResult,
        into listId: Int64
    ) async throws -> (routeCount: Int, waypointCount: Int, trackCount: Int, listName: String) {
        let q = try requireQueue()
        return try await q.write { db in
            guard let list = try RouteList.fetchOne(
                db,
                sql: "SELECT * FROM lists WHERE id = ?",
                arguments: [listId]
            ) else {
                throw DatabaseManagerError.insertFailed("Target list not found.")
            }
            let listName  = list.name
            var waypointCount = 0
            var routeCount    = 0
            var trackCount    = 0

            // Names of every <wpt> element in this file, used below to avoid
            // creating a duplicate waypoint when a route's first or last point
            // shares its name with an already-imported standalone waypoint.
            let wptNames = Set(result.waypoints.map(\.name))

            // Import standalone waypoints.
            for wpt in result.waypoints {
                let name = try Self.uniqueItemName(base: wpt.name, db: db)
                try db.execute(
                    sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                    arguments: ["waypoint", name]
                )
                guard let itemId = try Int64.fetchOne(
                    db, sql: "SELECT last_insert_rowid()"
                ) else { continue }
                try db.execute(
                    sql: "INSERT INTO waypoints " +
                         "(item_id, name, latitude, longitude, elevation, color_hex) " +
                         "VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [itemId, name, wpt.lat, wpt.lon, wpt.ele, "#E8453C"]
                )
                try db.execute(
                    sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                    arguments: [itemId, listId]
                )
                waypointCount += 1
            }

            // Fetch the default routing profile once so every imported route uses
            // the same costing criteria as a manually created route.
            let defaultProfile = try RoutingProfile.fetchOne(
                db,
                sql: "SELECT * FROM routing_profiles WHERE is_default = 1"
            )

            // Import routes.
            for rte in result.routes {
                let routeName = try Self.uniqueItemName(base: rte.name, db: db)
                try db.execute(
                    sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                    arguments: ["route", routeName]
                )
                guard let routeItemId = try Int64.fetchOne(
                    db, sql: "SELECT last_insert_rowid()"
                ) else { continue }

                // Insert route record with null geometry; needs_recalculation=1 ensures
                // Valhalla runs the first time the route is selected for display.
                // Apply the default routing profile's criteria if one is set.
                try db.execute(
                    sql: "INSERT INTO routes " +
                         "(item_id, routing_profile, needs_recalculation, color_hex, " +
                         "applied_profile_name, avoid_motorways, avoid_tolls, " +
                         "avoid_unpaved, avoid_ferries, shortest_route) " +
                         "VALUES (?, 'motorcycle', 1, '#1A73E8', ?, ?, ?, ?, ?, ?)",
                    arguments: [
                        routeItemId,
                        defaultProfile?.name,
                        defaultProfile?.avoidMotorways == true ? 1 : 0,
                        defaultProfile?.avoidTolls     == true ? 1 : 0,
                        defaultProfile?.avoidUnpaved   == true ? 1 : 0,
                        defaultProfile?.avoidFerries   == true ? 1 : 0,
                        defaultProfile?.shortestRoute  == true ? 1 : 0
                    ]
                )

                let points    = rte.points
                let lastIndex = points.count - 1

                for (seq, pt) in points.enumerated() {
                    let isFirst = seq == 0
                    let isLast  = seq == lastIndex
                    // Start and end points announce arrival; all intermediates are silent.
                    let announces = (isFirst || isLast) ? 1 : 0

                    // Create a library waypoint for the first and last route points,
                    // unless the point's name matches a <wpt> element that was already
                    // imported — in that case the standalone waypoint covers it.
                    let coveredByWpt = pt.name.map { wptNames.contains($0) } ?? false
                    var waypointItemId: Int64? = nil
                    if (isFirst || isLast) && !coveredByWpt {
                        let baseName  = pt.name ?? (isFirst ? routeName + " Start" : routeName + " End")
                        let wpName    = try Self.uniqueItemName(base: baseName, db: db)
                        try db.execute(
                            sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                            arguments: ["waypoint", wpName]
                        )
                        if let wpId = try Int64.fetchOne(
                            db, sql: "SELECT last_insert_rowid()"
                        ) {
                            try db.execute(
                                sql: "INSERT INTO waypoints " +
                                     "(item_id, name, latitude, longitude, elevation, color_hex) " +
                                     "VALUES (?, ?, ?, ?, ?, ?)",
                                arguments: [wpId, wpName, pt.lat, pt.lon, pt.ele, "#E8453C"]
                            )
                            try db.execute(
                                sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                                arguments: [wpId, listId]
                            )
                            waypointItemId = wpId
                        }
                    }

                    let ptName = pt.name ?? String(format: "%.4f, %.4f", pt.lat, pt.lon)
                    try db.execute(
                        sql: "INSERT INTO route_points " +
                             "(route_item_id, sequence_number, latitude, longitude, " +
                             "elevation, announces_arrival, name, waypoint_item_id) " +
                             "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        arguments: [
                            routeItemId, seq, pt.lat, pt.lon,
                            pt.ele, announces, ptName, waypointItemId
                        ]
                    )
                }

                try db.execute(
                    sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                    arguments: [routeItemId, listId]
                )
                routeCount += 1
            }

            // Import tracks.
            for trk in result.tracks {
                let trackName = try Self.uniqueItemName(base: trk.name, db: db)
                try db.execute(
                    sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                    arguments: ["track", trackName]
                )
                guard let trackItemId = try Int64.fetchOne(
                    db, sql: "SELECT last_insert_rowid()"
                ) else { continue }

                try db.execute(
                    sql: "INSERT INTO tracks (item_id, color, line_style) VALUES (?, ?, ?)",
                    arguments: [trackItemId, "#3E515A", "solid"]
                )

                for (seq, pt) in trk.points.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO track_points
                                (track_item_id, sequence_number, latitude, longitude,
                                 elevation, timestamp)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [trackItemId, seq, pt.lat, pt.lon, pt.ele, pt.timestamp]
                    )
                }

                try db.execute(
                    sql: "INSERT INTO item_list_membership (item_id, list_id) VALUES (?, ?)",
                    arguments: [trackItemId, listId]
                )
                trackCount += 1
            }

            return (
                routeCount:    routeCount,
                waypointCount: waypointCount,
                trackCount:    trackCount,
                listName:      listName
            )
        }
    }

    /// Returns a name that does not exist in the `items` table.
    ///
    /// If `base` is already taken, appends `(1)`, `(2)`, … until a free name is
    /// found. Falls back to a UUID suffix after 999 attempts.
    private static func uniqueItemName(base: String, db: Database) throws -> String {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM items WHERE name = ?",
            arguments: [base]
        ) ?? 0
        if count == 0 { return base }
        for suffix in 1...999 {
            let candidate = "\(base) (\(suffix))"
            let n = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM items WHERE name = ?",
                arguments: [candidate]
            ) ?? 0
            if n == 0 { return candidate }
        }
        return "\(base) (\(UUID().uuidString.prefix(8)))"
    }

    // MARK: - GPX Export

    /// Returns all item IDs that are members of `listId`.
    func fetchItemIdsForList(listId: Int64) async throws -> [Int64] {
        let q = try requireQueue()
        return try await q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT item_id FROM item_list_membership WHERE list_id = ?",
                arguments: [listId]
            )
            return rows.map { $0["item_id"] as Int64 }
        }
    }

    /// Returns all distinct item IDs that belong to any list inside `folderId`.
    func fetchItemIdsForFolder(folderId: Int64) async throws -> [Int64] {
        let q = try requireQueue()
        return try await q.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT item_id FROM item_list_membership
                    WHERE list_id IN (SELECT id FROM lists WHERE folder_id = ?)
                    """,
                arguments: [folderId]
            )
            return rows.map { $0["item_id"] as Int64 }
        }
    }

    /// Fetches all data needed to export the given items as GPX.
    ///
    /// For each item ID the corresponding child-table rows are fetched:
    /// - Waypoints: coordinates and notes from the `waypoints` table.
    ///   Items with no waypoints row are skipped.
    /// - Routes: all `route_points` rows in `sequence_number` order.
    /// - Tracks: all `track_points` rows in `sequence_number` order.
    ///
    /// Returns an empty array when `itemIds` is empty.
    func fetchItemsForExport(itemIds: [Int64]) async throws -> [ExportItem] {
        guard !itemIds.isEmpty else { return [] }
        let q = try requireQueue()
        return try await q.read { db in
            let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
            let itemSQL = "SELECT id, type, name, description FROM items " +
                          "WHERE id IN (\(placeholders)) ORDER BY name"
            let itemRows = try Row.fetchAll(
                db,
                sql: itemSQL,
                arguments: StatementArguments(itemIds)
            )

            var result: [ExportItem] = []

            for itemRow in itemRows {
                let itemId:      Int64   = itemRow["id"]
                let type:        String  = itemRow["type"]
                let name:        String  = itemRow["name"]
                let description: String? = itemRow["description"]

                switch type {
                case "waypoint":
                    guard let wptRow = try Row.fetchOne(
                        db,
                        sql: "SELECT latitude, longitude, notes FROM waypoints WHERE item_id = ?",
                        arguments: [itemId]
                    ) else {
                        continue
                    }
                    let latitude:  Double  = wptRow["latitude"]
                    let longitude: Double  = wptRow["longitude"]
                    let notes:     String? = wptRow["notes"]
                    let wpt = ExportWaypoint(
                        name: name,
                        latitude: latitude,
                        longitude: longitude,
                        elevation: nil,
                        symbol: nil,
                        description: notes ?? description
                    )
                    result.append(.waypoint(wpt))

                case "route":
                    let ptRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT latitude, longitude, elevation,
                                   announces_arrival, name
                            FROM route_points
                            WHERE route_item_id = ?
                            ORDER BY sequence_number
                            """,
                        arguments: [itemId]
                    )
                    let points: [ExportRoutePoint] = ptRows.map { pt in
                        let announcesInt: Int? = pt["announces_arrival"]
                        return ExportRoutePoint(
                            name: pt["name"],
                            latitude: pt["latitude"],
                            longitude: pt["longitude"],
                            elevation: pt["elevation"],
                            announcesArrival: (announcesInt ?? 0) != 0
                        )
                    }
                    let route = ExportRoute(
                        name: name,
                        description: description,
                        points: points
                    )
                    result.append(.route(route))

                case "track":
                    let ptRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT latitude, longitude, elevation,
                                   COALESCE(timestamp, recorded_at) AS ts
                            FROM track_points
                            WHERE track_item_id = ?
                            ORDER BY sequence_number
                            """,
                        arguments: [itemId]
                    )
                    let points: [ExportTrackPoint] = ptRows.map { pt in
                        ExportTrackPoint(
                            latitude: pt["latitude"],
                            longitude: pt["longitude"],
                            elevation: pt["elevation"],
                            timestamp: pt["ts"]
                        )
                    }
                    let track = ExportTrack(
                        name: name,
                        description: description,
                        points: points
                    )
                    result.append(.track(track))

                default:
                    break
                }
            }

            return result
        }
    }

    // MARK: - Private helpers

    private func requireQueue() throws -> DatabaseQueue {
        guard let q = _dbQueue else {
            throw DatabaseManagerError.notInitialised
        }
        return q
    }

    private static func openDatabaseQueue() throws -> DatabaseQueue {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = appSupport.appendingPathComponent("RouteKeeper", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("routekeeper.sqlite").path
        return try DatabaseQueue(path: path)
    }

    // MARK: - Schema creation

    /// Creates the complete database schema from scratch.
    ///
    /// Called by the single "v1" migration on every new database. Contains all
    /// tables including `routing_profiles` and the routing-option columns on
    /// `routes` added for Increment 19.
    // TODO: [REFACTOR] Several schema columns are dead: items.colour (never written),
    // items.description (never written or displayed), routes.geojson (superseded by
    // routes.geometry), tracks.geojson / distance_metres / duration_seconds / recorded_at
    // (never written). Consider a cleanup migration.
    // TODO: [REFACTOR] lists.is_smart / smart_rule and list_folders.parent_folder_id
    // are defined in the schema but never used — dead abstraction for unimplemented features.
    private static func createCompleteSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE items (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                type        TEXT    NOT NULL
                            CHECK (type IN ('route', 'waypoint', 'track')),
                name        TEXT    NOT NULL UNIQUE,
                description TEXT,
                colour      TEXT,
                created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
                modified_at TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE categories (
                id         INTEGER  PRIMARY KEY AUTOINCREMENT,
                name       TEXT     NOT NULL UNIQUE,
                icon_name  TEXT     NOT NULL,
                created_at DATETIME NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE waypoints (
                item_id     INTEGER  PRIMARY KEY
                             REFERENCES items(id) ON DELETE CASCADE,
                name        TEXT     NOT NULL,
                latitude    REAL     NOT NULL,
                longitude   REAL     NOT NULL,
                category_id INTEGER  REFERENCES categories(id) ON DELETE SET NULL,
                color_hex   TEXT     NOT NULL DEFAULT '#E8453C',
                notes       TEXT,
                created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE routes (
                item_id              INTEGER PRIMARY KEY
                                     REFERENCES items(id) ON DELETE CASCADE,
                geojson              TEXT,
                geometry             TEXT,
                distance_km          REAL,
                duration_seconds     INTEGER,
                routing_profile      TEXT    NOT NULL DEFAULT 'motorcycle',
                applied_profile_name TEXT,
                avoid_motorways      INTEGER NOT NULL DEFAULT 0,
                avoid_tolls          INTEGER NOT NULL DEFAULT 0,
                avoid_unpaved        INTEGER NOT NULL DEFAULT 0,
                avoid_ferries        INTEGER NOT NULL DEFAULT 0,
                shortest_route       INTEGER NOT NULL DEFAULT 0,
                elevation_profile    TEXT,
                notes                TEXT
            );

            CREATE TABLE route_points (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                route_item_id     INTEGER NOT NULL
                                  REFERENCES routes(item_id) ON DELETE CASCADE,
                sequence_number   INTEGER NOT NULL,
                latitude          REAL    NOT NULL,
                longitude         REAL    NOT NULL,
                elevation         REAL,
                announces_arrival INTEGER NOT NULL DEFAULT 0,
                name              TEXT,
                UNIQUE (route_item_id, sequence_number)
            );

            CREATE TABLE tracks (
                item_id          INTEGER PRIMARY KEY
                                 REFERENCES items(id) ON DELETE CASCADE,
                geojson          TEXT,
                distance_metres  REAL,
                duration_seconds INTEGER,
                recorded_at      TEXT
            );

            CREATE TABLE track_points (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                track_item_id   INTEGER NOT NULL
                                REFERENCES tracks(item_id) ON DELETE CASCADE,
                sequence_number INTEGER NOT NULL,
                latitude        REAL    NOT NULL,
                longitude       REAL    NOT NULL,
                elevation       REAL,
                recorded_at     TEXT,
                speed_ms        REAL,
                UNIQUE (track_item_id, sequence_number)
            );

            CREATE TABLE list_folders (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                name             TEXT    NOT NULL UNIQUE,
                parent_folder_id INTEGER REFERENCES list_folders(id)
                                 ON DELETE SET NULL,
                sort_order       INTEGER NOT NULL DEFAULT 0,
                created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
                modified_at      TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE lists (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT    NOT NULL,
                folder_id   INTEGER REFERENCES list_folders(id)
                            ON DELETE SET NULL,
                is_smart    INTEGER NOT NULL DEFAULT 0,
                smart_rule  TEXT,
                sort_order  INTEGER NOT NULL DEFAULT 0,
                created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
                modified_at TEXT    NOT NULL DEFAULT (datetime('now')),
                UNIQUE(name, folder_id)
            );

            CREATE TABLE item_list_membership (
                item_id    INTEGER NOT NULL REFERENCES items(id)
                           ON DELETE CASCADE,
                list_id    INTEGER NOT NULL REFERENCES lists(id)
                           ON DELETE CASCADE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                added_at   TEXT    NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (item_id, list_id)
            );

            CREATE TABLE routing_profiles (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                name             TEXT    NOT NULL UNIQUE,
                is_default       INTEGER NOT NULL DEFAULT 0,
                avoid_motorways  INTEGER NOT NULL DEFAULT 0,
                avoid_tolls      INTEGER NOT NULL DEFAULT 0,
                avoid_unpaved    INTEGER NOT NULL DEFAULT 0,
                avoid_ferries    INTEGER NOT NULL DEFAULT 0,
                shortest_route   INTEGER NOT NULL DEFAULT 0,
                created_at       TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT
            );

            CREATE UNIQUE INDEX idx_list_folders_name ON list_folders(name);
            CREATE UNIQUE INDEX idx_lists_name_folder ON lists(name, folder_id);
            CREATE UNIQUE INDEX idx_items_name        ON items(name);
            """)
    }

    /// Seeds the four built-in routing profiles.
    ///
    /// Called once from the "v1" migration immediately after schema creation.
    /// These are the only rows inserted on a fresh install; all other tables
    /// start empty.
    private static func seedRoutingProfiles(_ db: Database) throws {
        let profiles: [(name: String, isDefault: Int, avoidMotorways: Int,
                        avoidTolls: Int, avoidUnpaved: Int,
                        avoidFerries: Int, shortestRoute: Int)] = [
            ("All paved roads",      1, 0, 0, 1, 0, 0),
            ("Allow unpaved",        0, 0, 0, 0, 0, 0),
            ("Avoiding motorways",   0, 1, 0, 0, 0, 0),
            ("Avoiding tolls",       0, 0, 1, 0, 0, 0),
        ]
        for p in profiles {
            try db.execute(
                sql: """
                    INSERT INTO routing_profiles
                        (name, is_default, avoid_motorways, avoid_tolls,
                         avoid_unpaved, avoid_ferries, shortest_route)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    p.name, p.isDefault, p.avoidMotorways,
                    p.avoidTolls, p.avoidUnpaved, p.avoidFerries, p.shortestRoute
                ]
            )
        }
    }

    /// Seeds the twelve built-in waypoint categories in alphabetical order.
    ///
    /// Called once from the "v1" migration immediately after routing profiles.
    private static func seedCategories(_ db: Database) throws {
        let categories: [(name: String, iconName: String)] = [
            ("Café",        "cup.and.saucer.fill"),
            ("Campsite",    "tent.fill"),
            ("Ferry",       "ferry.fill"),
            ("Fuel",        "fuelpump.fill"),
            ("Hotel",       "bed.double.fill"),
            ("Landmark",    "building.columns.fill"),
            ("Other",       "mappin"),
            ("Parking",     "parkingsign"),
            ("Pass",        "mountain.2.fill"),
            ("Restaurant",  "fork.knife"),
            ("Viewpoint",   "binoculars.fill"),
            ("Workshop",    "wrench.and.screwdriver.fill"),
        ]
        for c in categories {
            try db.execute(
                sql: "INSERT INTO categories (name, icon_name) VALUES (?, ?)",
                arguments: [c.name, c.iconName]
            )
        }
    }

    // MARK: - Category management

    /// Creates a new user-defined category and returns it with its database id.
    @discardableResult
    func createCategory(name: String, iconName: String) async throws -> Category {
        let q = try requireQueue()
        return try await q.write { db in
            try db.execute(
                sql: "INSERT INTO categories (name, icon_name, is_default) " +
                     "VALUES (?, ?, 0)",
                arguments: [name, iconName]
            )
            guard let id = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.insertFailed(
                    "Could not retrieve new category ID"
                )
            }
            guard let cat = try Category.fetchOne(
                db,
                sql: "SELECT * FROM categories WHERE id = ?",
                arguments: [id]
            ) else {
                throw DatabaseManagerError.insertFailed(
                    "Could not fetch newly created category (id: \(id))"
                )
            }
            return cat
        }
    }

    /// Updates the name and icon of an existing user-defined category.
    func updateCategory(id: Int64, name: String, iconName: String) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE categories SET name = ?, icon_name = ? " +
                     "WHERE id = ? AND is_default = 0",
                arguments: [name, iconName, id]
            )
        }
    }

    /// Permanently deletes a user-defined category.
    ///
    /// The foreign key `ON DELETE SET NULL` on `waypoints.category_id` ensures
    /// that affected waypoints lose their category rather than being removed.
    func deleteCategory(id: Int64) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "DELETE FROM categories WHERE id = ? AND is_default = 0",
                arguments: [id]
            )
        }
    }

    /// Returns the number of waypoints currently assigned to the given category.
    func fetchCategoryUsageCount(categoryId: Int64) async throws -> Int {
        let q = try requireQueue()
        return try await q.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM waypoints WHERE category_id = ?",
                arguments: [categoryId]
            ) ?? 0
        }
    }

    /// Returns `true` if a category with `name` already exists (case-insensitive),
    /// optionally excluding the category identified by `excludingId`.
    func categoryNameExists(
        _ name: String,
        excludingId: Int64? = nil
    ) async throws -> Bool {
        let q = try requireQueue()
        return try await q.read { db in
            if let excludeId = excludingId {
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM categories " +
                         "WHERE lower(name) = lower(?) AND id != ?",
                    arguments: [name, excludeId]
                ) ?? 0
                return count > 0
            } else {
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM categories " +
                         "WHERE lower(name) = lower(?)",
                    arguments: [name]
                ) ?? 0
                return count > 0
            }
        }
    }
}
