//
//  ConfigService.swift
//  RouteKeeper
//
//  Reads compile-time configuration from Config.plist, which is excluded from
//  version control so that API keys are never committed to the repository.
//

import Foundation
import os.log

/// Provides access to values stored in Config.plist.
enum ConfigService {

    private static let logger = Logger(subsystem: "com.routekeeper", category: "ConfigService")

    /// The MapTiler API key read from Config.plist.
    ///
    /// Returns an empty string and logs a warning if Config.plist is missing
    /// or does not contain the expected key.
    static var mapTilerAPIKey: String {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let key = dict["MapTilerAPIKey"] as? String else {
            logger.warning("MapTilerAPIKey not found in Config.plist — map tiles will not load.")
            return ""
        }
        return key
    }
}
