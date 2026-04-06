//
//  GeocodingService.swift
//  RouteKeeper
//
//  Wraps the Nominatim geocoding API with a 300 ms debounce and automatic
//  task cancellation when a newer search supersedes the previous one.
//
//  Callers should catch `CancellationError` silently — it means a newer
//  search was started before the current one completed, which is expected
//  behaviour during rapid typing.
//

import Foundation

// MARK: - GeocodingResult

/// A single place returned from a geocoding search.
struct GeocodingResult: Identifiable {
    /// Stable identity for use in SwiftUI `ForEach`.
    let id = UUID()
    /// Full display name from Nominatim's `display_name` field.
    let name: String
    let latitude: Double
    let longitude: Double
    /// Shorter secondary line: city (or town/village) and country.
    let subtitle: String
}

// MARK: - GeocodingService

/// Searches the Nominatim API for places matching a text query.
///
/// Uses a 300 ms debounce: if ``search(_:)`` is called again before the
/// previous call's debounce expires, the previous `Task` is cancelled and
/// `CancellationError` is thrown to that caller.
@MainActor
final class GeocodingService {

    // MARK: Singleton

    static let shared = GeocodingService()
    private init() {}

    // MARK: State

    private var currentTask: Task<[GeocodingResult], Error>?

    // MARK: Public API

    /// Returns up to eight places matching `query`, debounced by 300 ms.
    ///
    /// Cancels any in-flight search before starting a new one.
    func search(_ query: String) async throws -> [GeocodingResult] {
        currentTask?.cancel()
        let task = Task {
            // Debounce: let the user finish typing before hitting the network.
            try await Task.sleep(for: .milliseconds(300))
            return try await Self.fetchResults(for: query)
        }
        currentTask = task
        return try await task.value
    }

    // MARK: Private

    private static func fetchResults(for query: String) async throws -> [GeocodingResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q",              value: trimmed),
            URLQueryItem(name: "format",         value: "json"),
            URLQueryItem(name: "limit",          value: "8"),
            URLQueryItem(name: "addressdetails", value: "1"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        // Nominatim requires a descriptive User-Agent; requests without one
        // may be rejected with HTTP 403.
        request.setValue("RouteKeeper/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let raw = try JSONDecoder().decode([NominatimResult].self, from: data)
        return raw.compactMap { GeocodingResult(nominatim: $0) }
    }
}

// MARK: - Nominatim JSON types (private)

private struct NominatimResult: Decodable {
    let displayName: String
    let lat: String
    let lon: String
    let address: NominatimAddress?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case lat, lon, address
    }
}

private struct NominatimAddress: Decodable {
    let city:    String?
    let town:    String?
    let village: String?
    let country: String?
}

// MARK: - GeocodingResult initialiser from Nominatim data

private extension GeocodingResult {
    /// Converts a raw Nominatim result. Returns `nil` if `lat`/`lon` cannot
    /// be parsed as `Double` (should never happen in practice).
    init?(nominatim raw: NominatimResult) {
        guard let lat = Double(raw.lat), let lon = Double(raw.lon) else { return nil }

        // Build the subtitle from the most specific available address fields.
        var parts: [String] = []
        if let place = raw.address?.city ?? raw.address?.town ?? raw.address?.village {
            parts.append(place)
        }
        if let country = raw.address?.country {
            parts.append(country)
        }

        name     = raw.displayName
        latitude = lat
        longitude = lon
        subtitle  = parts.isEmpty ? raw.displayName : parts.joined(separator: ", ")
    }
}
