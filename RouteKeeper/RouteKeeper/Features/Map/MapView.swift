//
//  MapView.swift
//  RouteKeeper
//
//  NSViewRepresentable wrapping a WKWebView that displays the MapLibre GL JS map.
//
//  State flow:
//    ContentView owns a MapViewModel (@Observable).
//    ContentView's body reads MapViewModel properties, so SwiftUI observes them.
//    When they change, ContentView re-renders and SwiftUI calls updateNSView.
//    The Coordinator tracks what was last applied and calls evaluateJavaScript
//    only when something has actually changed.
//
//  Map-ready gate:
//    MapLibre fires map.on("load") asynchronously after the HTML loads.
//    JS posts { type: "mapReady" } to Swift at that point.
//    Until that message arrives, drawRoute() stores the GeoJSON as pending
//    rather than calling JavaScript. On receiving mapReady the Coordinator
//    flushes any pending route immediately.
//
//  Swift → JS:  webView.evaluateJavaScript(...)
//  JS → Swift:  window.webkit.messageHandlers.routekeeper.postMessage({...})
//

import SwiftUI
import WebKit
import Observation

// MARK: - WaypointDisplay

/// The data needed to render a single waypoint pin on the map.
struct WaypointDisplay: Equatable {
    let latitude: Double
    let longitude: Double
    /// CSS hex colour string, e.g. `"#E8453C"`.
    let colorHex: String
}

// MARK: - MapCoordinate

/// A coordinate pair returned from a map interaction (e.g. context-menu tap).
struct MapCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

// MARK: - ViaWaypoint

/// A single intermediate waypoint passed to the map for display as a numbered circle.
struct ViaWaypoint: Equatable {
    let latitude: Double
    let longitude: Double
    /// 1-based display index shown inside the circle marker.
    let index: Int
}

// MARK: - RouteDisplay

/// Everything the map needs to render a stored route: the GeoJSON line and any
/// intermediate via-waypoint circles.
struct RouteDisplay: Equatable {
    let geojson: String
    let viaWaypoints: [ViaWaypoint]
}

// MARK: - MapViewModel

/// Drives the map's displayed state.
///
/// ContentView calls ``drawRoute(geojson:)``, ``flyTo(longitude:latitude:zoom:)``,
/// ``showWaypoint(latitude:longitude:colorHex:)``, and ``clearWaypoint()``
/// to update the map. Because this class is ``@Observable``, any SwiftUI view that
/// reads its properties in `body` will automatically re-render when they change.
@Observable
@MainActor
final class MapViewModel {

    // Accessed by MapView in updateNSView via the properties passed from ContentView.
    var routeGeoJSON: String? = nil
    var centerLon: Double = -2.0
    var centerLat: Double = 54.0
    var zoom: Double = 5.0

    /// Non-nil when a waypoint marker should be shown on the map.
    var waypointDisplay: WaypointDisplay? = nil

    /// Non-nil when a stored route should be displayed on the map.
    /// Setting this triggers `showRoute()` in JS; setting it to nil triggers `clearRoute()`.
    var routeDisplay: RouteDisplay? = nil

    /// Non-nil when multiple items should be displayed simultaneously via
    /// `showMultipleItems()` in JS. Holds the pre-serialised JSON string.
    var multiDisplay: String? = nil

    /// Draws a GeoJSON route on the map, replacing any previously drawn route.
    func drawRoute(geojson: String) {
        routeGeoJSON = geojson
    }

    /// Flies the map to the given position.
    func flyTo(longitude: Double, latitude: Double, zoom: Double) {
        centerLon = longitude
        centerLat = latitude
        self.zoom = zoom
    }

    /// Shows a waypoint marker on the map at the given coordinates.
    func showWaypoint(latitude: Double, longitude: Double, colorHex: String) {
        waypointDisplay = WaypointDisplay(latitude: latitude, longitude: longitude, colorHex: colorHex)
    }

    /// Removes the waypoint marker from the map.
    func clearWaypoint() {
        waypointDisplay = nil
    }

    /// Displays a stored route on the map, fitting the viewport to its bounds.
    func showRoute(_ display: RouteDisplay) {
        routeDisplay = display
    }

    /// Removes the stored route from the map.
    func clearRoute() {
        routeDisplay = nil
    }

    /// Renders multiple items simultaneously using the `showMultipleItems()` JS function.
    ///
    /// - Parameter json: Pre-serialised JSON array of item descriptors.
    func showMultipleItems(_ json: String) {
        multiDisplay = json
    }

    /// Removes all multi-item display content from the map.
    func clearMultiDisplay() {
        multiDisplay = nil
    }
}

// MARK: - MapView

struct MapView: NSViewRepresentable {

    // These properties are read from MapViewModel in ContentView's body,
    // establishing SwiftUI observation on the relevant MapViewModel properties.
    let routeGeoJSON: String?
    let centerLon: Double
    let centerLat: Double
    let zoom: Double
    let waypointDisplay: WaypointDisplay?
    /// Non-nil when a stored route should be displayed; passed to showRoute() in JS.
    let routeDisplay: RouteDisplay?
    /// Non-nil when multiple items should be rendered simultaneously via showMultipleItems().
    let multiDisplay: String?
    /// Called on the main thread when the user selects "New waypoint here" from the map
    /// context menu. Receives the WGS-84 latitude and longitude of the right-click point.
    let onAddWaypointAtCoordinate: ((Double, Double) -> Void)?

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(coordinator: context.coordinator))

        // Suppress the white background flash before the map tiles load.
        webView.setValue(false, forKey: "drawsBackground")

        guard let htmlURL = Bundle.main.url(forResource: "MapLibreMap", withExtension: "html") else {
            assertionFailure("MapLibreMap.html not found in app bundle — add it to the Xcode target.")
            return webView
        }

        // Store a weak reference so the Coordinator can flush pending routes
        // when the mapReady message arrives.
        context.coordinator.webView = webView

        let resourcesDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesDir)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        // Apply a new route if it has changed.
        if routeGeoJSON != coordinator.lastRouteGeoJSON {
            coordinator.lastRouteGeoJSON = routeGeoJSON
            if let geojson = routeGeoJSON {
                coordinator.drawRoute(geojson: geojson, in: nsView)
            } else {
                if coordinator.mapIsReady {
                    nsView.evaluateJavaScript("clearRoute();")
                }
            }
        }

        // Fly to the new centre if it has changed.
        if centerLon != coordinator.lastCenterLon
            || centerLat != coordinator.lastCenterLat
            || zoom != coordinator.lastZoom {
            coordinator.lastCenterLon = centerLon
            coordinator.lastCenterLat = centerLat
            coordinator.lastZoom = zoom
            if coordinator.mapIsReady {
                nsView.evaluateJavaScript(
                    "map.flyTo({center: [\(centerLon), \(centerLat)], zoom: \(zoom)});"
                )
            }
        }

        // Apply a waypoint display change if it has changed.
        if waypointDisplay != coordinator.lastWaypointDisplay {
            coordinator.lastWaypointDisplay = waypointDisplay
            if coordinator.mapIsReady {
                coordinator.applyWaypointDisplay(waypointDisplay, in: nsView)
            } else {
                // Queue for flushing once mapReady fires. Storing nil here cancels
                // any previously queued showWaypoint (map starts empty, so no
                // explicit clearWaypoint call is needed before the map is ready).
                coordinator.pendingWaypointDisplay = waypointDisplay
            }
        }

        // Apply a stored-route display change if it has changed.
        if routeDisplay != coordinator.lastRouteDisplay {
            coordinator.lastRouteDisplay = routeDisplay
            if coordinator.mapIsReady {
                coordinator.applyRouteDisplay(routeDisplay, in: nsView)
            } else {
                coordinator.pendingRouteDisplay = routeDisplay
            }
        }

        // Apply a multi-item display change if it has changed.
        if multiDisplay != coordinator.lastMultiDisplay {
            coordinator.lastMultiDisplay = multiDisplay
            if coordinator.mapIsReady {
                coordinator.applyMultiDisplay(multiDisplay, in: nsView)
            } else {
                coordinator.pendingMultiDisplay = multiDisplay
            }
        }

        // Keep the callback current so the Coordinator always calls back into
        // the latest ContentView closure, even after SwiftUI re-renders.
        coordinator.onAddWaypointAtCoordinate = onAddWaypointAtCoordinate
    }

    // MARK: Private helpers

    private func makeConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: "routekeeper")

        // Inject the MapTiler style URL before the page's own scripts run so
        // that the map initialisation in MapLibreMap.html can read mapStyleURL.
        let apiKey = ConfigService.mapTilerAPIKey
        let styleURL = "https://api.maptiler.com/maps/streets-v2/style.json?key=\(apiKey)"
        let script = WKUserScript(
            source: "var mapStyleURL = \"\(styleURL)\";",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(script)

        config.userContentController = contentController
        return config
    }

    // MARK: - Coordinator

    /// Tracks last-applied map state, gates JS calls on map readiness, and
    /// receives JS → Swift messages.
    final class Coordinator: NSObject, WKScriptMessageHandler {

        // MARK: Map-ready gate

        /// Set to true when JS posts { type: "mapReady" }.
        var mapIsReady = false

        /// GeoJSON stored here when drawRoute() is called before the map is ready.
        /// Flushed immediately once mapReady is received.
        var pendingRouteGeoJSON: String? = nil

        /// Waypoint display queued before the map was ready.
        /// `nil` means nothing pending (or a pending show was cancelled by a deselect).
        /// Flushed on mapReady if non-nil.
        var pendingWaypointDisplay: WaypointDisplay? = nil

        /// Route display queued before the map was ready. Follows the same
        /// nil-cancels-pending contract as `pendingWaypointDisplay`.
        var pendingRouteDisplay: RouteDisplay? = nil

        /// Multi-item display queued before the map was ready.
        var pendingMultiDisplay: String? = nil

        /// Weak reference to the WKWebView, used to flush pending state
        /// from inside the message handler (which has no other webView reference).
        weak var webView: WKWebView?

        // MARK: Change tracking

        var lastRouteGeoJSON: String? = nil
        var lastCenterLon: Double = .nan  // nan ensures the first flyTo always fires
        var lastCenterLat: Double = .nan
        var lastZoom: Double = .nan
        var lastWaypointDisplay: WaypointDisplay? = nil
        var lastRouteDisplay: RouteDisplay? = nil
        var lastMultiDisplay: String? = nil

        /// Callback set by `MapView.updateNSView` each render pass.
        /// Called when the JS context menu fires an `addWaypointAtCoordinate` message.
        var onAddWaypointAtCoordinate: ((Double, Double) -> Void)? = nil

        // MARK: JS calls

        /// Passes GeoJSON to the JS drawRoute() function, or queues it if the
        /// map is not yet ready.
        func drawRoute(geojson: String, in webView: WKWebView) {
            guard mapIsReady else {
                pendingRouteGeoJSON = geojson
                return
            }
            executeDrawRoute(geojson: geojson, in: webView)
        }

        private func executeDrawRoute(geojson: String, in webView: WKWebView) {
            let escaped = geojson
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            webView.evaluateJavaScript("drawRoute(\"\(escaped)\");")
        }

        /// Calls either `showWaypoint()` or `clearWaypoint()` in JS depending on
        /// whether `display` is non-nil.
        func applyWaypointDisplay(_ display: WaypointDisplay?, in webView: WKWebView) {
            if let wp = display {
                webView.evaluateJavaScript(
                    "showWaypoint(\(wp.latitude), \(wp.longitude), \"\(wp.colorHex)\");"
                )
            } else {
                webView.evaluateJavaScript("clearWaypoint();")
            }
        }

        /// Calls either `showMultipleItems()` or `clearMultipleItems()` in JS depending
        /// on whether `json` is non-nil.
        ///
        /// The JSON string is escaped for embedding inside a JS string literal using
        /// the same backslash-then-quote sequence used by `applyRouteDisplay`.
        func applyMultiDisplay(_ json: String?, in webView: WKWebView) {
            if let json {
                let escaped = json
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")
                webView.evaluateJavaScript("showMultipleItems(\"\(escaped)\");")
            } else {
                webView.evaluateJavaScript("clearMultipleItems();")
            }
        }

        /// Calls either `showRoute()` or `clearRoute()` in JS depending on
        /// whether `display` is non-nil.
        ///
        /// When showing a route, start and end marker icons are generated from
        /// SF Symbols and passed as base64-encoded PNG strings. Intermediate via
        /// waypoints are serialised as a JSON array and passed as a fourth argument.
        func applyRouteDisplay(_ display: RouteDisplay?, in webView: WKWebView) {
            if let display {
                let startIcon = sfSymbolBase64(
                    "flag.fill",
                    color: NSColor(red: 0.0, green: 0.5, blue: 0.15, alpha: 1.0)
                ) ?? ""
                let endIcon = sfSymbolBase64("flag.checkered", color: .black) ?? ""
                let escaped = display.geojson
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")
                // Build a compact JSON array of via waypoints and escape it for
                // embedding inside a JS string literal.
                let viaItems = display.viaWaypoints.map { wp in
                    "{\"lat\":\(wp.latitude),\"lng\":\(wp.longitude),\"index\":\(wp.index)}"
                }.joined(separator: ",")
                let viaRaw = "[\(viaItems)]"
                let viaEscaped = viaRaw
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let js = "showRoute(\"\(escaped)\", \"\(startIcon)\", \"\(endIcon)\", \"\(viaEscaped)\")"
                webView.evaluateJavaScript(js)
            } else {
                webView.evaluateJavaScript("clearRoute();")
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "routekeeper",
                  let body = message.body as? [String: Any] else { return }

            print("JS → Swift: \(body)")

            guard let type = body["type"] as? String else { return }

            if type == "addWaypointAtCoordinate" {
                guard let lat = body["lat"] as? Double,
                      let lng = body["lng"] as? Double else { return }
                onAddWaypointAtCoordinate?(lat, lng)
                return
            }

            if type == "mapReady" {
                mapIsReady = true
                guard let wv = webView else { return }

                // Flush any route that arrived before the map was ready.
                if let pending = pendingRouteGeoJSON {
                    executeDrawRoute(geojson: pending, in: wv)
                    pendingRouteGeoJSON = nil
                    // Also apply the queued flyTo if centre was already set.
                    if !lastCenterLon.isNaN {
                        wv.evaluateJavaScript(
                            "map.flyTo({center: [\(lastCenterLon), \(lastCenterLat)], zoom: \(lastZoom)});"
                        )
                    }
                }

                // Flush any waypoint that arrived before the map was ready.
                if let pending = pendingWaypointDisplay {
                    applyWaypointDisplay(pending, in: wv)
                    pendingWaypointDisplay = nil
                }

                // Flush any stored route that arrived before the map was ready.
                if let pending = pendingRouteDisplay {
                    applyRouteDisplay(pending, in: wv)
                    pendingRouteDisplay = nil
                }

                // Flush any multi-item display that arrived before the map was ready.
                if let pending = pendingMultiDisplay {
                    applyMultiDisplay(pending, in: wv)
                    pendingMultiDisplay = nil
                }
            }
        }
    }
}

#Preview {
    MapView(
        routeGeoJSON: nil, centerLon: -2.0, centerLat: 54.0, zoom: 5,
        waypointDisplay: nil, routeDisplay: nil, multiDisplay: nil,
        onAddWaypointAtCoordinate: nil
    )
    .frame(width: 800, height: 600)
}

// MARK: - SF Symbol → base64 PNG

/// Renders an SF Symbol with the given colour into a base64-encoded PNG string.
///
/// The result is passed directly to `showRoute()` or `showMultipleItems()` in
/// JavaScript so MapLibre can display the symbol as a map image without requiring
/// a separate asset file.
///
/// Returns `nil` if the symbol name is not found or the bitmap render fails.
func sfSymbolBase64(_ name: String, color: NSColor, size: CGFloat = 24) -> String? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
}
