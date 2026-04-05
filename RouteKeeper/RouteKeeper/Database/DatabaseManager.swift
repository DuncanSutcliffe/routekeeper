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

    private init() {}

    // MARK: Setup

    /// Opens (or creates) the database file and applies any pending schema migrations.
    ///
    /// Idempotent — safe to call more than once; subsequent calls return immediately.
    func setUp() async throws {
        guard _dbQueue == nil else { return }
        let dbQueue = try Self.openDatabaseQueue()
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

        try await migrator.migrate(dbQueue)
        _dbQueue = dbQueue
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

    /// Fetches all items that have no row in `item_list_membership`, ordered by name.
    ///
    /// Used to populate the application-layer Unclassified folder.
    func fetchUnclassifiedItems() async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.*
                FROM items
                WHERE items.id NOT IN (SELECT item_id FROM item_list_membership)
                ORDER BY items.name
                """)
        }
    }

    /// Fetches all items belonging to the given list, ordered by name.
    func fetchItems(for listId: Int64) async throws -> [Item] {
        let q = try requireQueue()
        return try await q.read { db in
            try Item.fetchAll(db, sql: """
                SELECT items.*
                FROM items
                JOIN item_list_membership
                  ON items.id = item_list_membership.item_id
                WHERE item_list_membership.list_id = ?
                ORDER BY items.name
                """, arguments: [listId])
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
