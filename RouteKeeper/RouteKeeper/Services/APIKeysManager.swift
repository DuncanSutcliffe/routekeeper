//
//  APIKeysManager.swift
//  RouteKeeper
//
//  Manages API key storage and retrieval via UserDefaults.
//  Migrates from Config.plist on first launch if a UserDefaults entry is absent.
//

import Foundation
import Observation

/// Manages the MapTiler and What3Words API keys, backed by UserDefaults.
///
/// On first launch, if UserDefaults contains no MapTiler key, the value is
/// read from Config.plist (via ``ConfigService``) and immediately written to
/// UserDefaults so subsequent launches read from there.
@Observable
@MainActor
final class APIKeysManager {

    private static let mapTilerDefaultsKey   = "MapTilerAPIKey"
    private static let what3WordsDefaultsKey = "What3WordsAPIKey"

    /// The MapTiler API key used to build tile style URLs.
    var mapTilerKey: String = ""

    /// The What3Words API key (stored but not yet used by any feature).
    var what3WordsKey: String = ""

    init() {
        mapTilerKey   = KeychainManager.load(key: Self.mapTilerDefaultsKey)   ?? ""
        what3WordsKey = KeychainManager.load(key: Self.what3WordsDefaultsKey) ?? ""

        // One-time migration: promote Config.plist key to UserDefaults.
        if mapTilerKey.isEmpty {
            let plistKey = ConfigService.mapTilerAPIKey
            if !plistKey.isEmpty {
                mapTilerKey = plistKey
                KeychainManager.save(key: Self.mapTilerDefaultsKey, value: plistKey)
            }
        }
    }

    /// Persists both key values to UserDefaults.
    func save() {
        KeychainManager.save(key: Self.mapTilerDefaultsKey,   value: mapTilerKey)
        KeychainManager.save(key: Self.what3WordsDefaultsKey, value: what3WordsKey)
    }
}
