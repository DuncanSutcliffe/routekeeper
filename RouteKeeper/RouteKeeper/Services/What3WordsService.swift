//
//  What3WordsService.swift
//  RouteKeeper
//
//  Resolves a What3Words address to a WGS-84 coordinate pair.
//

import Foundation

// MARK: - What3WordsError

enum What3WordsError: LocalizedError {
    case invalidAddress
    case missingKey
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Please enter a valid What3Words address (three words separated by dots)."
        case .missingKey:
            return "No What3Words API key configured."
        case .apiError(let message):
            return message
        }
    }
}

// MARK: - What3WordsService

/// Wraps the What3Words convert-to-coordinates API endpoint.
enum What3WordsService {

    /// Resolves a What3Words address to WGS-84 coordinates.
    ///
    /// - Parameters:
    ///   - address: A three-word address optionally prefixed with `///`.
    ///   - apiKey:  A valid What3Words API key supplied by the caller.
    /// - Returns: A `(latitude, longitude)` tuple on success.
    /// - Throws:  ``What3WordsError`` on validation failure or API error,
    ///            or any `URLSession` error on network failure.
    static func resolve(
        address: String,
        apiKey: String
    ) async throws -> (latitude: Double, longitude: Double) {
        guard !apiKey.isEmpty else { throw What3WordsError.missingKey }

        // Strip leading forward slashes, trim whitespace, lowercase.
        let stripped = String(address.drop(while: { $0 == "/" }))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        // Validate: exactly three non-empty lowercase alpha words separated by dots.
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        let isValid = parts.count == 3 &&
            parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter && $0.isLowercase } }
        guard isValid else { throw What3WordsError.invalidAddress }

        let urlStr = "https://api.what3words.com/v3/convert-to-coordinates" +
            "?words=\(stripped)&key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw What3WordsError.invalidAddress }

        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw What3WordsError.apiError("Invalid response from What3Words.")
        }

        // Surface any API-level error returned in the response body.
        if let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            throw What3WordsError.apiError(message)
        }

        guard let coordinates = json["coordinates"] as? [String: Any],
              let lat = coordinates["lat"] as? Double,
              let lng = coordinates["lng"] as? Double else {
            throw What3WordsError.apiError("Could not read coordinates from What3Words response.")
        }

        return (latitude: lat, longitude: lng)
    }
}
