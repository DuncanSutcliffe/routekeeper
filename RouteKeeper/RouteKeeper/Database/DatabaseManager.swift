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

        // v1 — full schema creation and seed data.
        // The guard lets this migration run safely on databases that were created
        // before DatabaseMigrator was adopted: those already have the schema in
        // place, so we skip creation and let v2 apply the uniqueness indexes.
        migrator.registerMigration("v1") { db in
            guard try !db.tableExists("app_settings") else { return }
            try Self.createSchemaV1(db)
            try Self.seedIfNeeded(db)
        }

        // v2 — unique-name constraints.
        // Uses named indexes rather than table recreation (SQLite has no
        // ALTER TABLE … ADD CONSTRAINT). On databases created after the v1
        // DDL update, this adds a second index alongside the implicit
        // sqlite_autoindex_* created by the UNIQUE clause — redundant but
        // harmless. On pre-v2 databases the index is the sole constraint.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_list_folders_name
                    ON list_folders(name);
                CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_name_folder
                    ON lists(name, folder_id);
                CREATE UNIQUE INDEX IF NOT EXISTS idx_items_name
                    ON items(name);
                """)
        }

        // v3 — standalone waypoints model.
        // Drops the old satellite `waypoints` table (item_id → items.id,
        // Garmin-style) and replaces it with a `categories` lookup table
        // and a new standalone `waypoints` table for favourite POIs.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS waypoints")
            try Self.createCategoriesAndWaypoints(db)
        }

        // v4 — waypoints linked to items via item_id PK.
        // The v3 standalone waypoints table had its own autoincrement id,
        // preventing waypoints from participating in item_list_membership.
        // This migration drops that table and recreates waypoints with
        // item_id as both the primary key and a foreign key to items.id,
        // matching the pattern used by routes and tracks.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS waypoints")
            try db.execute(sql: """
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
                )
                """)
        }

        // v5 — geometry column on routes.
        // Adds a nullable TEXT column to store the Valhalla-calculated GeoJSON
        // FeatureCollection produced by the route-creation flow. Existing rows
        // receive NULL, which is correct since no geometry has been calculated
        // for them yet.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE routes ADD COLUMN geometry TEXT")
        }

        // v6 — back-fill route_points.
        // Routes created before this migration have no route_points rows because
        // createRoute() did not write them. Remove those empty route shells so
        // the table is in a clean state; the user will need to recreate affected
        // routes to obtain proper start/end points for GPX export.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: "DELETE FROM route_points")
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

    // MARK: Queries

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
                throw DatabaseManagerError.insertFailed("Could not fetch newly created folder (id: \(id))")
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
                throw DatabaseManagerError.insertFailed("Could not fetch newly created list (id: \(id))")
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
                sql: """
                    INSERT INTO waypoints
                        (item_id, name, latitude, longitude, category_id, color_hex, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [itemId, name, latitude, longitude, categoryId, colorHex, notes]
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
    ///
    /// Used when a route item is selected in the sidebar to retrieve the
    /// geometry for display via `showRoute()` in MapLibreMap.html.
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

    /// Fetches all waypoints that have coordinate rows in the v4 `waypoints` table,
    /// ordered by name.
    ///
    /// Only waypoints created through the `NewWaypointSheet` flow have rows here;
    /// seed-data items of type `"waypoint"` do not (their geometry was lost during
    /// the v3/v4 schema migrations). This method is used to populate the start/end
    /// point pickers in `NewRouteSheet`.
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
    ///
    /// - Parameters:
    ///   - name: The route name; must be unique across all items.
    ///   - geometry: GeoJSON FeatureCollection string from Valhalla.
    ///   - listIds: Lists to associate the route with. Pass an empty array to
    ///     leave the route unclassified (it will appear in the Unclassified folder).
    ///   - startWaypoint: When provided, written to `route_points` as sequence 1
    ///     with `announces_arrival = 1`. Pass `nil` to skip (e.g. in unit tests).
    ///   - endWaypoint: When provided, written to `route_points` as sequence 2
    ///     with `announces_arrival = 1`. Pass `nil` to skip.
    @discardableResult
    func createRoute(
        name: String,
        geometry: String,
        listIds: [Int64],
        startWaypoint: Waypoint? = nil,
        endWaypoint: Waypoint? = nil
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

            // 2. Insert route-specific data.
            try db.execute(
                sql: "INSERT INTO routes (item_id, routing_profile, geometry) VALUES (?, ?, ?)",
                arguments: [itemId, "motorcycle", geometry]
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
        distanceMetres: Double?,
        durationSecs: Int?
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
                        distance_metres = ?,
                        estimated_duration_secs = ?
                    WHERE item_id = ?
                    """,
                arguments: [geometry, distanceMetres, durationSecs, routeItemId]
            )
        }
    }

    /// Returns the waypoint row for the given item id, or `nil` if no row exists.
    ///
    /// Used when an item is selected in the sidebar to retrieve its coordinates
    /// and colour for display on the map.
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

    /// Fetches all items that have no row in `item_list_membership`, ordered by name.
    ///
    /// A LEFT JOIN with `waypoints` promotes `waypoints.color_hex` into the
    /// `colour` column so that `Item.colour` is populated for waypoint rows.
    /// Routes and tracks have no waypoints row, so their `colour` remains NULL.
    func fetchUnclassifiedItems() async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.id,
                       items.type,
                       items.name,
                       items.description,
                       COALESCE(w.color_hex, items.colour) AS colour,
                       items.created_at,
                       items.modified_at
                FROM items
                LEFT JOIN waypoints w ON items.id = w.item_id
                WHERE items.id NOT IN (SELECT item_id FROM item_list_membership)
                ORDER BY items.name
                """)
        }
    }

    /// Copies an item into a list by inserting a membership row.
    ///
    /// Uses `INSERT OR IGNORE` so this is a no-op if the item is already a
    /// member of the target list — dropping an item onto its own list is safe.
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
    /// Deletes the `(itemId, sourceListId)` membership row, then inserts a new
    /// `(itemId, targetListId)` row.  `INSERT OR IGNORE` ensures a pre-existing
    /// target membership is not treated as an error.  No other list memberships
    /// for the item are affected.
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
    /// A LEFT JOIN with `waypoints` promotes `waypoints.color_hex` into the
    /// `colour` column so that `Item.colour` is populated for waypoint rows.
    func fetchItems(for listId: Int64) async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.id,
                       items.type,
                       items.name,
                       items.description,
                       COALESCE(w.color_hex, items.colour) AS colour,
                       items.created_at,
                       items.modified_at
                FROM items
                JOIN item_list_membership
                  ON items.id = item_list_membership.item_id
                LEFT JOIN waypoints w ON items.id = w.item_id
                WHERE item_list_membership.list_id = ?
                ORDER BY items.name
                """, arguments: [listId])
        }
    }

    /// Returns the set of list IDs that `itemId` currently belongs to.
    ///
    /// Used by the context menu to determine which target lists should be shown
    /// as disabled (the item is already a member of that list).
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
    ///
    /// The item itself is not deleted — it will appear in Unclassified if this
    /// was its only membership, since the Unclassified query selects items with
    /// no `item_list_membership` rows.
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
    /// Deletes the `items` row; all related rows in `waypoints`, `routes`,
    /// `tracks`, and `item_list_membership` are removed automatically by
    /// their `ON DELETE CASCADE` foreign keys.
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
    ///
    /// The caller is responsible for verifying the list is empty. Items that
    /// belonged solely to this list will appear in Unclassified after deletion
    /// because the `item_list_membership` rows cascade-delete with the list.
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
    ///
    /// All lists in the folder are deleted first (their `item_list_membership`
    /// rows cascade-delete automatically), then the folder itself. The caller
    /// is responsible for verifying that all lists in the folder are empty.
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

    // MARK: - GPX Export

    /// Returns all item IDs that are members of `listId`.
    ///
    /// Used to determine which items to export when the user chooses
    /// "Export GPX…" on a list row.
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
    ///
    /// Used to determine which items to export when the user chooses
    /// "Export GPX…" on a folder row.
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
    /// - Waypoints: coordinates and notes from the v4 `waypoints` table.
    ///   Items with no v4 row (e.g. legacy seed data) are skipped.
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
                let itemId: Int64  = itemRow["id"]
                let type:   String = itemRow["type"]
                let name:   String = itemRow["name"]
                let description: String? = itemRow["description"]

                switch type {
                case "waypoint":
                    guard let wptRow = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT latitude, longitude, notes
                            FROM waypoints WHERE item_id = ?
                            """,
                        arguments: [itemId]
                    ) else {
                        // No v4 waypoints row — skip (legacy seed data).
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

    // MARK: Private helpers

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

    // MARK: Migrations

    private static func createSchemaV1(_ db: Database) throws {
        // Execute the complete v1 schema as a single batch.
        // sqlite3_exec handles multiple semicolon-separated statements.
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

            CREATE TABLE waypoints (
                item_id    INTEGER PRIMARY KEY
                           REFERENCES items(id) ON DELETE CASCADE,
                latitude   REAL NOT NULL,
                longitude  REAL NOT NULL,
                elevation  REAL,
                symbol     TEXT
            );

            CREATE TABLE routes (
                item_id                 INTEGER PRIMARY KEY
                                        REFERENCES items(id) ON DELETE CASCADE,
                geojson                 TEXT,
                distance_metres         REAL,
                estimated_duration_secs INTEGER,
                routing_profile         TEXT NOT NULL DEFAULT 'motorcycle'
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

            CREATE TABLE app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT
            );

            INSERT INTO app_settings (key, value) VALUES ('schema_version', '1');
            """)
    }

    /// Creates the `categories` and `waypoints` tables (v3 schema) and seeds
    /// the twelve default categories in alphabetical order.
    private static func createCategoriesAndWaypoints(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE categories (
                id         INTEGER  PRIMARY KEY AUTOINCREMENT,
                name       TEXT     NOT NULL UNIQUE,
                icon_name  TEXT     NOT NULL,
                created_at DATETIME NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE waypoints (
                id          INTEGER  PRIMARY KEY AUTOINCREMENT,
                name        TEXT     NOT NULL UNIQUE,
                latitude    REAL     NOT NULL,
                longitude   REAL     NOT NULL,
                category_id INTEGER  REFERENCES categories(id) ON DELETE SET NULL,
                color_hex   TEXT     NOT NULL DEFAULT '#E8453C',
                notes       TEXT,
                created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
            );
            """)

        let defaults: [(name: String, iconName: String)] = [
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
        for row in defaults {
            try db.execute(
                sql: "INSERT INTO categories (name, icon_name) VALUES (?, ?)",
                arguments: [row.name, row.iconName]
            )
        }
    }

    // MARK: Seeding

    /// Inserts placeholder folders and lists when the database is empty.
    private static func seedIfNeeded(_ db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM list_folders") ?? 0
        guard count == 0 else { return }

        try db.execute(
            sql: "INSERT INTO list_folders (name, sort_order) VALUES (?, ?)",
            arguments: ["Europe Tours", 0]
        )
        guard let europeFolderId = try Int64.fetchOne(
            db, sql: "SELECT last_insert_rowid()"
        ) else {
            throw DatabaseManagerError.seedingFailed("Could not retrieve Europe Tours folder ID")
        }

        try db.execute(
            sql: "INSERT INTO list_folders (name, sort_order) VALUES (?, ?)",
            arguments: ["Day Rides", 1]
        )
        guard let dayRidesFolderId = try Int64.fetchOne(
            db, sql: "SELECT last_insert_rowid()"
        ) else {
            throw DatabaseManagerError.seedingFailed("Could not retrieve Day Rides folder ID")
        }

        try db.execute(
            sql: """
                INSERT INTO lists (name, folder_id, sort_order) VALUES
                    (?, ?, 0),
                    (?, ?, 1),
                    (?, ?, 0),
                    (?, ?, 1)
                """,
            arguments: [
                "Alps Loop 2024",     europeFolderId,
                "Pyrenees Run",       europeFolderId,
                "Morning Coastal",    dayRidesFolderId,
                "Peak District Loop", dayRidesFolderId,
            ]
        )

        try seedItems(db)
    }

    /// Inserts placeholder items and associates them with the seed lists.
    ///
    /// Called once from ``seedIfNeeded(_:)`` immediately after the lists are
    /// created. List IDs are looked up by name — safe because the names are
    /// unique within the seed data.
    private static func seedItems(_ db: Database) throws {

        // Resolve list IDs by name.
        func listID(_ name: String) throws -> Int64 {
            guard let id = try Int64.fetchOne(
                db, sql: "SELECT id FROM lists WHERE name = ?", arguments: [name]
            ) else {
                throw DatabaseManagerError.seedingFailed("List '\(name)' not found")
            }
            return id
        }

        let alpsID        = try listID("Alps Loop 2024")
        let pyreneesID    = try listID("Pyrenees Run")
        let coastalID     = try listID("Morning Coastal")
        let peakDistID    = try listID("Peak District Loop")

        // Helper: insert an item row and return its new id.
        func insertItem(type: String, name: String) throws -> Int64 {
            try db.execute(
                sql: "INSERT INTO items (type, name) VALUES (?, ?)",
                arguments: [type, name]
            )
            guard let id = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()") else {
                throw DatabaseManagerError.seedingFailed("Could not retrieve item id for '\(name)'")
            }
            return id
        }

        // Helper: link an item to a list.
        func associate(itemId: Int64, listId: Int64, order: Int = 0) throws {
            try db.execute(
                sql: "INSERT INTO item_list_membership (item_id, list_id, sort_order) VALUES (?, ?, ?)",
                arguments: [itemId, listId, order]
            )
        }

        // ── Alps Loop 2024 ────────────────────────────────────────────────

        let galibier = try insertItem(type: "waypoint", name: "Col du Galibier")
        try db.execute(
            sql: "INSERT INTO waypoints (item_id, latitude, longitude, elevation, symbol) VALUES (?, ?, ?, ?, ?)",
            arguments: [galibier, 45.0643, 6.4078, 2642.0, "Summit"]
        )
        try associate(itemId: galibier, listId: alpsID, order: 0)

        let chamonixAnnecy = try insertItem(type: "route", name: "Chamonix to Annecy")
        try db.execute(
            sql: "INSERT INTO routes (item_id, routing_profile) VALUES (?, ?)",
            arguments: [chamonixAnnecy, "motorcycle"]
        )
        try associate(itemId: chamonixAnnecy, listId: alpsID, order: 1)

        let montBlancTrack = try insertItem(type: "track", name: "Tour du Mont Blanc")
        try db.execute(
            sql: "INSERT INTO tracks (item_id) VALUES (?)",
            arguments: [montBlancTrack]
        )
        try associate(itemId: montBlancTrack, listId: alpsID, order: 2)

        // ── Pyrenees Run ─────────────────────────────────────────────────

        let aubisque = try insertItem(type: "waypoint", name: "Col d'Aubisque")
        try db.execute(
            sql: "INSERT INTO waypoints (item_id, latitude, longitude, elevation, symbol) VALUES (?, ?, ?, ?, ?)",
            arguments: [aubisque, 42.9697, -0.3375, 1709.0, "Summit"]
        )
        try associate(itemId: aubisque, listId: pyreneesID, order: 0)

        let lourdesBiarritz = try insertItem(type: "route", name: "Lourdes to Biarritz")
        try db.execute(
            sql: "INSERT INTO routes (item_id, routing_profile) VALUES (?, ?)",
            arguments: [lourdesBiarritz, "motorcycle"]
        )
        try associate(itemId: lourdesBiarritz, listId: pyreneesID, order: 1)

        // ── Morning Coastal ───────────────────────────────────────────────

        let beachyHead = try insertItem(type: "waypoint", name: "Beachy Head")
        try db.execute(
            sql: "INSERT INTO waypoints (item_id, latitude, longitude, symbol) VALUES (?, ?, ?, ?)",
            arguments: [beachyHead, 50.7361, 0.2450, "Scenic Area"]
        )
        try associate(itemId: beachyHead, listId: coastalID, order: 0)

        let sevenSisters = try insertItem(type: "track", name: "Seven Sisters Ride")
        try db.execute(
            sql: "INSERT INTO tracks (item_id) VALUES (?)",
            arguments: [sevenSisters]
        )
        try associate(itemId: sevenSisters, listId: coastalID, order: 1)

        // ── Peak District Loop ────────────────────────────────────────────

        let matlockBath = try insertItem(type: "waypoint", name: "Matlock Bath")
        try db.execute(
            sql: "INSERT INTO waypoints (item_id, latitude, longitude, symbol) VALUES (?, ?, ?, ?)",
            arguments: [matlockBath, 53.1283, -1.5604, "Flag, Blue"]
        )
        try associate(itemId: matlockBath, listId: peakDistID, order: 0)

        let matlockBuxton = try insertItem(type: "route", name: "Matlock to Buxton")
        try db.execute(
            sql: "INSERT INTO routes (item_id, routing_profile) VALUES (?, ?)",
            arguments: [matlockBuxton, "motorcycle"]
        )
        try associate(itemId: matlockBuxton, listId: peakDistID, order: 1)

        let stanage = try insertItem(type: "waypoint", name: "Stanage Edge")
        try db.execute(
            sql: "INSERT INTO waypoints (item_id, latitude, longitude, symbol) VALUES (?, ?, ?, ?)",
            arguments: [stanage, 53.3667, -1.6333, "Scenic Area"]
        )
        try associate(itemId: stanage, listId: peakDistID, order: 2)
    }
}
