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
        try await dbQueue.write { db in
            try Self.applyMigrations(db)
            try Self.seedIfNeeded(db)
        }
        _dbQueue = dbQueue
    }

    // MARK: Queries

    /// Fetches all list folders paired with their contained lists, ordered by `sort_order`.
    func fetchFoldersWithLists() async throws -> [(ListFolder, [RouteList])] {
        let q = try requireQueue()
        return try await q.read { db in
            let folders = try ListFolder
                .order(Column("sort_order"))
                .fetchAll(db)
            return try folders.map { folder in
                let lists = try RouteList
                    .filter(Column("folder_id") == folder.id)
                    .order(Column("sort_order"))
                    .fetchAll(db)
                return (folder, lists)
            }
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

    private static func applyMigrations(_ db: Database) throws {
        // Check whether the settings table exists to distinguish a fresh database
        // from one already at v1. Subsequent versions read schema_version directly.
        let settingsExists = try db.tableExists("app_settings")
        guard settingsExists else {
            try createSchemaV1(db)
            return
        }

        let version = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_settings WHERE key = 'schema_version'"
        )

        // Slot future migrations in here, in order:
        // if version == "1" { try migrateV1toV2(db) }
        _ = version
    }

    private static func createSchemaV1(_ db: Database) throws {
        // Execute the complete v1 schema as a single batch.
        // sqlite3_exec handles multiple semicolon-separated statements.
        try db.execute(sql: """
            CREATE TABLE items (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                type        TEXT    NOT NULL
                            CHECK (type IN ('route', 'waypoint', 'track')),
                name        TEXT    NOT NULL,
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
                name             TEXT    NOT NULL,
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
                modified_at TEXT    NOT NULL DEFAULT (datetime('now'))
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
    }
}
