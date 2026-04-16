//
//  KeychainManager.swift
//  RouteKeeper
//
//  Simple Keychain wrapper for storing and retrieving string values.
//

import Foundation
import Security

/// Stores and retrieves string values from the macOS Keychain.
enum KeychainManager {

    private static let service = "com.duncansutcliffe.RouteKeeper"

    /// Saves a string value to the Keychain under the given key.
    ///
    /// If an entry already exists for the key, it is updated in place.
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key
        ]

        let attributes: [CFString: Any] = [
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleWhenUnlocked
        ]

        let addQuery = query.merging(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    /// Loads a string value from the Keychain for the given key.
    ///
    /// Returns `nil` if no matching item exists.
    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}
