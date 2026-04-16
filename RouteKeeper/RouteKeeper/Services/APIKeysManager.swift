//
//  APIKeysManager.swift
//  RouteKeeper
//
//  Manages API key storage and retrieval via the system Keychain.
//  Migrates from Config.plist on first launch if a Keychain entry is absent.
//

import Foundation
import Observation

/// Manages the MapTiler and What3Words API keys, backed by the macOS Keychain.
///
/// On first launch, if the Keychain contains no MapTiler key, the value is
/// read from Config.plist (via ``ConfigService``) and immediately written to
/// the Keychain so subsequent launches read from there.
@Observable
@MainActor
final class APIKeysManager {

    private static let mapTilerKeychainKey    = "MapTilerAPIKey"
    private static let what3WordsKeychainKey  = "What3WordsAPIKey"

    /// The MapTiler API key used to build tile style URLs.
    var mapTilerKey: String = ""

    /// The What3Words API key (stored but not yet used by any feature).
    var what3WordsKey: String = ""

    init() {
        mapTilerKey   = KeychainManager.load(key: Self.mapTilerKeychainKey)   ?? ""
        what3WordsKey = KeychainManager.load(key: Self.what3WordsKeychainKey) ?? ""

        // One-time migration: promote Config.plist key to the Keychain.
        if mapTilerKey.isEmpty {
            let plistKey = ConfigService.mapTilerAPIKey
            if !plistKey.isEmpty {
                mapTilerKey = plistKey
                KeychainManager.save(key: Self.mapTilerKeychainKey, value: plistKey)
            }
        }
    }

    /// Persists both key values to the Keychain.
    func save() {
        KeychainManager.save(key: Self.mapTilerKeychainKey,   value: mapTilerKey)
        KeychainManager.save(key: Self.what3WordsKeychainKey, value: what3WordsKey)
    }
}
