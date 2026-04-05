//
//  RoutingService.swift
//  RouteKeeper
//
//  Calls the Valhalla routing API and returns a GeoJSON LineString string
//  ready to pass to MapLibre. All network work happens off the main thread
//  inside the actor.
//

import Foundation
import CoreLocation

// MARK: - Error type

enum RoutingError: LocalizedError {
    case networkFailure(Error)
    case httpError(statusCode: Int)
    case noLegsInResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .networkFailure(let e):    return "Network error: \(e.localizedDescription)"
        case .httpError(let code):      return "Valhalla returned HTTP \(code)"
        case .noLegsInResponse:         return "Valhalla response contained no route legs"
        case .decodingFailed:           return "Failed to decode the Valhalla response"
        }
    }
}

// MARK: - RoutingService

/// Calculates motorcycle routes via the Valhalla API.
actor RoutingService {

    static let shared = RoutingService()

    private let endpoint = URL(string: "https://valhalla1.openstreetmap.de/route")!
    private let session = URLSession.shared

    /// In-memory cache keyed on coordinate pair. Persists for the lifetime of the session.
    private var cache: [String: String] = [:]

    private init() {}

    // MARK: - Public API

    /// Requests a motorcycle route from `origin` to `destination`.
    ///
    /// - Returns: A compact GeoJSON FeatureCollection string containing a
    ///   single LineString feature representing the route shape.
    /// - Throws: ``RoutingError`` on network failure, non-200 response, or
    ///   an unexpected response structure.
    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> String {
        let key = cacheKey(from: origin, to: destination)
        if let cached = cache[key] {
            return cached
        }

        print("Routing: calling Valhalla API (\(origin.latitude),\(origin.longitude) → \(destination.latitude),\(destination.longitude))")
        let request = try buildRequest(from: origin, to: destination)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RoutingError.networkFailure(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RoutingError.httpError(statusCode: http.statusCode)
        }

        let vResponse: ValhallaResponse
        do {
            vResponse = try JSONDecoder().decode(ValhallaResponse.self, from: data)
        } catch {
            throw RoutingError.decodingFailed
        }

        guard let leg = vResponse.trip.legs.first else {
            throw RoutingError.noLegsInResponse
        }

        let coordinates = Self.decodePolyline(leg.shape)
        let geojson = Self.toGeoJSON(coordinates)
        print("Routing: received \(coordinates.count) points from Valhalla, caching result")
        cache[key] = geojson
        return geojson
    }

    /// Cache key formed from start and end coordinates at 6 decimal places —
    /// matching Valhalla's own precision so cache hits are exact.
    private func cacheKey(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> String {
        String(format: "%.6f,%.6f-%.6f,%.6f",
               origin.latitude, origin.longitude,
               destination.latitude, destination.longitude)
    }

    // MARK: - Request building

    private func buildRequest(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) throws -> URLRequest {
        let body = ValhallaRequest(
            locations: [
                .init(lon: origin.longitude, lat: origin.latitude),
                .init(lon: destination.longitude, lat: destination.latitude),
            ],
            costing: "motorcycle",
            directionsOptions: .init(units: "km")
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Encoded polyline decoder

    /// Decodes a Valhalla encoded polyline (precision 6) into coordinates.
    ///
    /// Valhalla uses 1e6 precision, not Google's standard 1e5.
    private static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lon = 0

        while index < encoded.endIndex {
            lat += decodeDelta(&index, in: encoded)
            lon += decodeDelta(&index, in: encoded)
            coordinates.append(CLLocationCoordinate2D(
                latitude:  Double(lat) / 1e6,
                longitude: Double(lon) / 1e6
            ))
        }

        return coordinates
    }

    /// Decodes one signed delta value from the encoded string, advancing `index`.
    private static func decodeDelta(_ index: inout String.Index, in encoded: String) -> Int {
        var result = 0
        var shift = 0
        var byte = 0

        repeat {
            guard index < encoded.endIndex else { break }
            byte = Int(encoded[index].asciiValue ?? 63) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1f) << shift
            shift += 5
        } while byte >= 32

        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }

    // MARK: - GeoJSON serialisation

    /// Converts an array of coordinates into a compact GeoJSON FeatureCollection string.
    ///
    /// GeoJSON uses [longitude, latitude] order.
    private static func toGeoJSON(_ coordinates: [CLLocationCoordinate2D]) -> String {
        let pairs = coordinates
            .map { "[\($0.longitude),\($0.latitude)]" }
            .joined(separator: ",")
        return """
            {"type":"FeatureCollection","features":[{"type":"Feature",\
            "geometry":{"type":"LineString","coordinates":[\(pairs)]},\
            "properties":{}}]}
            """
    }
}

// MARK: - Valhalla Codable types

private struct ValhallaRequest: Encodable {
    let locations: [Location]
    let costing: String
    let directionsOptions: DirectionsOptions

    enum CodingKeys: String, CodingKey {
        case locations, costing
        case directionsOptions = "directions_options"
    }

    struct Location: Encodable {
        let lon: Double
        let lat: Double
    }

    struct DirectionsOptions: Encodable {
        let units: String
    }
}

private struct ValhallaResponse: Decodable {
    let trip: Trip

    struct Trip: Decodable {
        let legs: [Leg]
    }

    struct Leg: Decodable {
        let shape: String
    }
}
