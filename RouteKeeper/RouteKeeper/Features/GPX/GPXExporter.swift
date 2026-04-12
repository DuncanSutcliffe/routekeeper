//
//  GPXExporter.swift
//  RouteKeeper
//
//  Pure data-transformation layer: receives structured export data and returns
//  a valid GPX XML string. No database or UI dependencies.
//

import Foundation

// MARK: - GPXFormat

/// The GPX output format to produce.
enum GPXFormat {
    /// Standard GPX 1.1 with no vendor extensions.
    case standard
    /// GPX 1.1 with Garmin gpxx and gpxtpx namespace extensions.
    /// Shaping points receive a gpxx:RoutePointExtension block.
    case garmin
}

// MARK: - Export model types

/// A waypoint item ready for GPX export.
struct ExportWaypoint {
    let name: String
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let symbol: String?
    let description: String?
}

/// A single point within a planned route.
struct ExportRoutePoint {
    let name: String?
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    /// `true` = via point (flags on device); `false` = shaping point (silent).
    let announcesArrival: Bool
}

/// A planned route with an ordered sequence of points.
struct ExportRoute {
    let name: String
    let description: String?
    let points: [ExportRoutePoint]
}

/// A single point in a recorded GPS track.
struct ExportTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: String?
}

/// A recorded GPS track.
struct ExportTrack {
    let name: String
    let description: String?
    let points: [ExportTrackPoint]
}

/// A library item wrapped for GPX export.
enum ExportItem {
    case waypoint(ExportWaypoint)
    case route(ExportRoute)
    case track(ExportTrack)
}

// MARK: - GPXExporter

/// Transforms a list of library items into a GPX XML string.
///
/// This is a pure data-transformation layer with no UI or database dependencies.
/// Feed it ``ExportItem`` values and receive a complete GPX document as a `String`.
enum GPXExporter {

    /// Generates a GPX XML document from the supplied items.
    ///
    /// - Parameters:
    ///   - items: The library items to include.
    ///   - format: Whether to produce standard GPX 1.1 or Garmin-extended GPX.
    /// - Returns: A UTF-8 XML string containing the complete GPX document.
    static func exportGPX(items: [ExportItem], format: GPXFormat) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += gpxOpenTag(format: format)
        xml += "\n"

        for item in items {
            switch item {
            case .waypoint(let wpt):
                xml += waypointElement(wpt)
            case .route(let rte):
                xml += routeElement(rte, format: format)
            case .track(let trk):
                xml += trackElement(trk)
            }
        }

        xml += "</gpx>\n"
        return xml
    }

    // MARK: - Root element

    private static func gpxOpenTag(format: GPXFormat) -> String {
        var tag = "<gpx version=\"1.1\" creator=\"RouteKeeper\"\n"
        tag += "     xmlns=\"http://www.topografix.com/GPX/1/1\"\n"
        tag += "     xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n"
        if format == .garmin {
            tag += "     xmlns:gpxx=\"http://www.garmin.com/xmlschemas/GpxExtensions/v3\"\n"
            tag += "     xmlns:gpxtpx="
            tag += "\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\"\n"
        }
        tag += "     xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 "
        tag += "http://www.topografix.com/GPX/1/1/gpx.xsd\">"
        return tag
    }

    // MARK: - Waypoint element

    private static func waypointElement(_ wpt: ExportWaypoint) -> String {
        let latlon = coordAttr(lat: wpt.latitude, lon: wpt.longitude)
        var el = "  <wpt \(latlon)>\n"
        el += "    <name>\(xmlEscape(wpt.name))</name>\n"
        if let ele = wpt.elevation {
            el += "    <ele>\(String(format: "%.1f", ele))</ele>\n"
        }
        if let sym = wpt.symbol {
            el += "    <sym>\(xmlEscape(sym))</sym>\n"
        }
        if let desc = wpt.description {
            el += "    <desc>\(xmlEscape(desc))</desc>\n"
        }
        el += "  </wpt>\n"
        return el
    }

    // MARK: - Route element

    private static func routeElement(_ rte: ExportRoute, format: GPXFormat) -> String {
        var el = "  <rte>\n"
        el += "    <name>\(xmlEscape(rte.name))</name>\n"
        if let desc = rte.description {
            el += "    <desc>\(xmlEscape(desc))</desc>\n"
        }
        for pt in rte.points {
            el += routePointElement(pt, format: format)
        }
        el += "  </rte>\n"
        return el
    }

    private static func routePointElement(
        _ pt: ExportRoutePoint,
        format: GPXFormat
    ) -> String {
        let latlon = coordAttr(lat: pt.latitude, lon: pt.longitude)
        // Garmin shaping points (announcesArrival == false) require a
        // gpxx:RoutePointExtension block so the device treats them as silent
        // shaping points rather than announced via points.
        // Announcing points (announcesArrival == true) emit no extension block
        // and are treated as standard announced via points by the device.
        let needsExtensions = format == .garmin && !pt.announcesArrival
        let hasChildren = pt.name != nil || pt.elevation != nil || needsExtensions

        if !hasChildren {
            return "    <rtept \(latlon)/>\n"
        }

        var el = "    <rtept \(latlon)>\n"
        if let name = pt.name {
            el += "      <name>\(xmlEscape(name))</name>\n"
        }
        if let ele = pt.elevation {
            el += "      <ele>\(String(format: "%.1f", ele))</ele>\n"
        }
        if needsExtensions {
            el += "      <extensions>\n"
            el += "        <gpxx:RoutePointExtension>\n"
            el += "          <gpxx:Subclass>"
            el += "000000000000FFFFFFFFFFFFFFFFFFFFFFFF"
            el += "</gpxx:Subclass>\n"
            el += "        </gpxx:RoutePointExtension>\n"
            el += "      </extensions>\n"
        }
        el += "    </rtept>\n"
        return el
    }

    // MARK: - Track element

    private static func trackElement(_ trk: ExportTrack) -> String {
        var el = "  <trk>\n"
        el += "    <name>\(xmlEscape(trk.name))</name>\n"
        if let desc = trk.description {
            el += "    <desc>\(xmlEscape(desc))</desc>\n"
        }
        el += "    <trkseg>\n"
        for pt in trk.points {
            el += trackPointElement(pt)
        }
        el += "    </trkseg>\n"
        el += "  </trk>\n"
        return el
    }

    private static func trackPointElement(_ pt: ExportTrackPoint) -> String {
        let latlon = coordAttr(lat: pt.latitude, lon: pt.longitude)
        let hasChildren = pt.elevation != nil || pt.timestamp != nil

        if !hasChildren {
            return "      <trkpt \(latlon)/>\n"
        }

        var el = "      <trkpt \(latlon)>\n"
        if let ele = pt.elevation {
            el += "        <ele>\(String(format: "%.1f", ele))</ele>\n"
        }
        if let time = pt.timestamp {
            el += "        <time>\(xmlEscape(time))</time>\n"
        }
        el += "      </trkpt>\n"
        return el
    }

    // MARK: - Helpers

    private static func coordAttr(lat: Double, lon: Double) -> String {
        "lat=\"\(String(format: "%.6f", lat))\" lon=\"\(String(format: "%.6f", lon))\""
    }

    /// Escapes the five predefined XML entities in `string`.
    private static func xmlEscape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&",  with: "&amp;")
        result = result.replacingOccurrences(of: "<",  with: "&lt;")
        result = result.replacingOccurrences(of: ">",  with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'",  with: "&apos;")
        return result
    }
}
