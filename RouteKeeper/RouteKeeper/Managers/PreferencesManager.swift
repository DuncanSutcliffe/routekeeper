//
//  PreferencesManager.swift
//  RouteKeeper
//
//  Stores and retrieves user preferences backed by the app_settings table.
//

import Foundation

// MARK: - PreferencesManager

/// Singleton that owns the two user-facing preferences.
///
/// Reads from the database on first access via ``load()``, which must be
/// awaited once at app launch before the UI reads ``shared``.
@MainActor
@Observable
final class PreferencesManager {

    // MARK: Singleton

    /// The shared preferences manager.
    static let shared = PreferencesManager()

    // MARK: Properties

    /// Measurement system — "metric" or "imperial".
    var units: String = "metric"

    /// GPX format applied as the default in the export sheet — "standard" or "garmin".
    var defaultExportFormat: String = "standard"

    // MARK: Init

    private init() {}

    // MARK: Load

    /// Reads both preferences from the database.
    ///
    /// Unknown or absent keys fall back to their default values, which are
    /// immediately written to `app_settings` so subsequent launches find them.
    func load() async {
        do {
            if let stored = try await DatabaseManager.shared.fetchSetting(key: "units") {
                units = stored
            } else {
                try await DatabaseManager.shared.saveSetting(key: "units", value: units)
            }

            if let stored = try await DatabaseManager.shared.fetchSetting(
                key: "defaultExportFormat"
            ) {
                defaultExportFormat = stored
            } else {
                try await DatabaseManager.shared.saveSetting(
                    key: "defaultExportFormat",
                    value: defaultExportFormat
                )
            }
        } catch {
            // Non-fatal: UI falls back to the in-memory defaults.
        }
    }

    // MARK: Save

    /// Persists both current preference values to `app_settings` in a single
    /// write transaction (one call per key via `saveSetting`).
    func save() {
        Task {
            do {
                try await DatabaseManager.shared.saveSetting(key: "units", value: units)
                try await DatabaseManager.shared.saveSetting(
                    key: "defaultExportFormat",
                    value: defaultExportFormat
                )
            } catch {
                // Non-fatal: in-memory values remain correct for the session.
            }
        }
    }
}
