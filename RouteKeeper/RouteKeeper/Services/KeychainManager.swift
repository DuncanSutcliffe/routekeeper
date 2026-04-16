//
//  KeychainManager.swift
//  RouteKeeper
//
//  Simple UserDefaults wrapper for storing and retrieving string values.
//

import Foundation

/// Stores and retrieves string values from UserDefaults.
enum KeychainManager {

    /// Saves a string value to UserDefaults under the given key.
    static func save(key: String, value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Loads a string value from UserDefaults for the given key.
    ///
    /// Returns `nil` if no value has been stored for that key.
    static func load(key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}
