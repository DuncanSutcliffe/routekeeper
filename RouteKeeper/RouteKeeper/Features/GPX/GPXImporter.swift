//
//  GPXImporter.swift
//  RouteKeeper
//
//  Parses a GPX file using Foundation's XMLParser and returns a structured
//  GPXImportResult containing arrays of parsed waypoints and routes.
//  Tracks (<trk>) are ignored entirely.
//

import Foundation

// MARK: - Parsed model types

/// A waypoint parsed from a <wpt> element.
struct ParsedWaypoint {
    let name: String
    let lat: Double
    let lon: Double
    let ele: Double?
}

/// A single point parsed from a <rtept> element inside a <rte>.
struct ParsedRoutePoint {
    let name: String?
    let lat: Double
    let lon: Double
    let ele: Double?
    /// `true` if the point carries a Garmin gpxx:RoutePointExtension with the
    /// shaping-point subclass hex, marking it as a silent routing constraint.
    let isShaping: Bool
}

/// A route parsed from a <rte> element.
struct ParsedRoute {
    let name: String
    let points: [ParsedRoutePoint]
}

/// The structured output of a successful GPX parse.
struct GPXImportResult {
    let waypoints: [ParsedWaypoint]
    let routes: [ParsedRoute]
}

// MARK: - Error

enum GPXImportError: Error, LocalizedError {
    case unparseable(String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .unparseable(let detail):
            return "The file could not be parsed: \(detail)"
        case .noContent:
            return "No importable content found in this file."
        }
    }
}

// MARK: - GPXImporter

/// Parses a GPX file at a given URL and returns a structured ``GPXImportResult``.
///
/// Uses Foundation's `XMLParser` — no third-party dependencies.
enum GPXImporter {

    /// Parses the GPX file at `url`.
    ///
    /// - Throws: ``GPXImportError/unparseable(_:)`` when the XML is malformed.
    /// - Throws: ``GPXImportError/noContent`` when the file contains no `<wpt>`
    ///   or `<rte>` elements (e.g. a tracks-only file).
    static func parse(url: URL) throws -> GPXImportResult {
        let delegate = ParserDelegate()
        guard let parser = XMLParser(contentsOf: url) else {
            throw GPXImportError.unparseable("Could not read the file at the given URL.")
        }
        parser.delegate = delegate
        parser.parse()

        if let error = delegate.parseError {
            throw GPXImportError.unparseable(error.localizedDescription)
        }
        if delegate.waypoints.isEmpty && delegate.routes.isEmpty {
            throw GPXImportError.noContent
        }
        return GPXImportResult(waypoints: delegate.waypoints, routes: delegate.routes)
    }
}

// MARK: - Garmin shaping-point constant

/// The gpxx:Subclass hex value Garmin writes for silent shaping points.
private let shapingSubclassHex = "000000000000FFFFFFFFFFFFFFFFFFFFFFFF"

// MARK: - XMLParser delegate

private final class ParserDelegate: NSObject, XMLParserDelegate {

    private(set) var waypoints: [ParsedWaypoint] = []
    private(set) var routes:    [ParsedRoute]    = []
    private(set) var parseError: Error?          = nil

    // Element nesting stack — the last entry is always the currently open element.
    private var elementStack: [String] = []
    // Character accumulator for the element currently being closed.
    private var currentText = ""

    // Pending values reset at the start of each <wpt> or <rtept>.
    private var pendingLat:       Double? = nil
    private var pendingLon:       Double? = nil
    private var pendingName:      String? = nil
    private var pendingEle:       Double? = nil
    private var pendingIsShaping: Bool   = false

    // Route accumulator reset at the start of each <rte>.
    private var currentRouteName:   String?             = nil
    private var currentRoutePoints: [ParsedRoutePoint] = []

    // MARK: didStartElement

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        currentText = ""

        switch elementName {
        case "wpt", "rtept":
            pendingLat       = attributeDict["lat"].flatMap(Double.init)
            pendingLon       = attributeDict["lon"].flatMap(Double.init)
            pendingName      = nil
            pendingEle       = nil
            pendingIsShaping = false
        case "rte":
            currentRouteName   = nil
            currentRoutePoints = []
        default:
            break
        }
    }

    // MARK: foundCharacters

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // MARK: didEndElement

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        elementStack.removeLast()
        let parent = elementStack.last ?? ""
        currentText = ""

        switch elementName {

        case "name":
            // Capture <name> only when it is a direct child of <wpt>, <rtept>, or <rte>.
            if parent == "wpt" || parent == "rtept" {
                pendingName = text.isEmpty ? nil : text
            } else if parent == "rte" {
                currentRouteName = text.isEmpty ? nil : text
            }

        case "ele":
            if parent == "wpt" || parent == "rtept" {
                pendingEle = Double(text)
            }

        case "gpxx:Subclass":
            if text == shapingSubclassHex {
                pendingIsShaping = true
            }

        case "wpt":
            guard let lat = pendingLat, let lon = pendingLon else { break }
            let name = pendingName ?? String(format: "%.6f, %.6f", lat, lon)
            waypoints.append(ParsedWaypoint(name: name, lat: lat, lon: lon, ele: pendingEle))

        case "rtept":
            guard let lat = pendingLat, let lon = pendingLon else { break }
            currentRoutePoints.append(ParsedRoutePoint(
                name: pendingName, lat: lat, lon: lon,
                ele: pendingEle, isShaping: pendingIsShaping
            ))

        case "rte":
            guard !currentRoutePoints.isEmpty else { break }
            routes.append(ParsedRoute(
                name: currentRouteName ?? "Imported Route",
                points: currentRoutePoints
            ))

        default:
            break
        }
    }

    // MARK: parseErrorOccurred

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
