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

    /// Returns the best available place name for the given coordinate using
    /// Nominatim reverse geocoding. Returns `nil` if the request fails or
    /// produces no parseable result.
    func reverseGeocode(latitude: Double, longitude: Double) async -> GeocodingResult? {
        // TODO: [REFACTOR] Force-unwrap on URLComponents(string:) — this will crash at
        // runtime if the constant URL string is ever malformed. Use a guard or make the
        // URL a module-level constant validated at compile time.
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "lat",            value: String(latitude)),
            URLQueryItem(name: "lon",            value: String(longitude)),
            URLQueryItem(name: "format",         value: "json"),
            URLQueryItem(name: "addressdetails", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("RouteKeeper/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let raw = try? JSONDecoder().decode(NominatimResult.self, from: data) else { return nil }
        return GeocodingResult(nominatim: raw)
    }

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

        // TODO: [REFACTOR] Nominatim base URLs and the result limit "8" are hardcoded here
        // and in reverseGeocode(). Extract to named constants or ConfigService so they can
        // be changed in one place.
        // TODO: [REFACTOR] Force-unwrap on URLComponents(string:) — see comment in reverseGeocode().
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
    let name: String?       // Place's own name — present for named features, absent for addresses
    let displayName: String // Full formatted address string
    let lat: String
    let lon: String
    let address: NominatimAddress?

    enum CodingKeys: String, CodingKey {
        case name
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

        // Use the place's own name if present; fall back to the first
        // comma-component of display_name (e.g. "Matlock" from the full address).
        if let n = raw.name, !n.isEmpty {
            name = n
        } else {
            let first = raw.displayName
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            name = first.isEmpty ? raw.displayName : first
        }
        latitude  = lat
        longitude = lon
        subtitle  = parts.isEmpty ? raw.displayName : parts.joined(separator: ", ")
    }
}
