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

// MARK: - WaypointSummary

// TODO: [REFACTOR] WaypointSummary is a model/DTO type that does not belong inside
// DatabaseManager.swift. Move it to Models/ (e.g. alongside WaypointRecords.swift).
// Also consider whether WaypointSummary is truly necessary: Waypoint already has
// the same fields; using it directly would eliminate a parallel type.

/// Lightweight projection used by `WaypointPickerSheet` to list available
/// waypoints without pulling full `Waypoint` records.
struct WaypointSummary: Identifiable, Hashable {
    let itemId: Int64
    let name: String
    let latitude: Double
    let longitude: Double

    var id: Int64 { itemId }
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
                     "category_id, color_hex, notes) " +
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [itemId, name, latitude, longitude, elevation,
                            categoryId, colorHex, notes]
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

    // TODO: [REFACTOR] fetchRouteGeometry() retrieves only `geometry`; verify it's still
    // called. If all callers have switched to fetchRouteRecord(), this is dead code.
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

    // TODO: [REFACTOR] fetchAllWaypoints() returning [WaypointSummary] and
    // fetchWaypointsWithCoordinates() returning [Waypoint] are near-duplicates.
    // Consider consolidating on fetchWaypointsWithCoordinates() and removing WaypointSummary.
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
        colorHex: String = "#1A73E8"
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
                     "avoid_unpaved, avoid_ferries, shortest_route, color_hex) " +
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [itemId, "motorcycle", geometry, distanceKm, durationSeconds,
                            appliedProfileName,
                            avoidMotorways ? 1 : 0, avoidTolls ? 1 : 0,
                            avoidUnpaved ? 1 : 0, avoidFerries ? 1 : 0,
                            shortestRoute ? 1 : 0, colorHex]
            )

            // 3. Insert route_points for start (seq 1) and end (seq 2) if supplied.
            if let start = startWaypoint {
                try db.execute(
                    sql: """
                        INSERT INTO route_points
                            (route_item_id, sequence_number, latitude, longitude,
                             announces_arrival, name)
                        VALUES (?, 1, ?, ?, 1, ?)
                        """,
                    arguments: [itemId, start.latitude, start.longitude, start.name]
                )
            }
            if let end = endWaypoint {
                try db.execute(
                    sql: """
                        INSERT INTO route_points
                            (route_item_id, sequence_number, latitude, longitude,
                             announces_arrival, name)
                        VALUES (?, 2, ?, ?, 1, ?)
                        """,
                    arguments: [itemId, end.latitude, end.longitude, end.name]
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
        durationSeconds: Int?
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
                             elevation, announces_arrival, name)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        routeItemId,
                        index,
                        point.latitude,
                        point.longitude,
                        point.elevation,
                        point.announcesArrival ? 1 : 0,
                        point.name
                    ]
                )
            }

            // 3. Update the route record.
            try db.execute(
                sql: """
                    UPDATE routes
                    SET geometry = ?,
                        distance_km = ?,
                        duration_seconds = ?
                    WHERE item_id = ?
                    """,
                arguments: [geometry, distanceKm, durationSeconds, routeItemId]
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
        durationSeconds: Int?
    ) async throws {
        let q = try requireQueue()
        try await q.write { db in
            try db.execute(
                sql: "UPDATE routes " +
                     "SET geometry = ?, distance_km = ?, duration_seconds = ? " +
                     "WHERE item_id = ?",
                arguments: [geometry, distanceKm, durationSeconds, itemId]
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
                     "category_id = ?, color_hex = ?, notes = ? " +
                     "WHERE item_id = ?",
                arguments: [name, latitude, longitude, elevation,
                            categoryId, colorHex, notes, itemId]
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
                       COALESCE(w.color_hex, items.colour) AS colour,
                       c.icon_name AS category_icon,
                       items.created_at,
                       items.modified_at
                FROM items
                LEFT JOIN waypoints  w ON items.id = w.item_id
                LEFT JOIN categories c ON w.category_id = c.id
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
                       COALESCE(w.color_hex, items.colour) AS colour,
                       c.icon_name AS category_icon,
                       items.created_at,
                       items.modified_at
                FROM items
                JOIN item_list_membership
                  ON items.id = item_list_membership.item_id
                LEFT JOIN waypoints  w ON items.id = w.item_id
                LEFT JOIN categories c ON w.category_id = c.id
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
                            SELECT latitude, longitude, elevation, recorded_at
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
                            timestamp: pt["recorded_at"]
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
                shortest_route       INTEGER NOT NULL DEFAULT 0
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
}
