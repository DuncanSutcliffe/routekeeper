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
    /// The item's database identifier, used to key the name label popup.
    let itemId: Int64
    let latitude: Double
    let longitude: Double
    /// CSS hex colour string, e.g. `"#E8453C"`.
    let colorHex: String
    /// Display name shown as a compact label adjacent to the marker.
    let name: String
    /// MapLibre image name for the category icon, e.g. `"icon-cafe"`.
    /// `nil` when the waypoint has no category assigned.
    let iconImageName: String?
}

// MARK: - MapCoordinate

/// A coordinate pair returned from a map interaction (e.g. context-menu tap).
struct MapCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

// MARK: - ViaWaypoint

/// A single intermediate waypoint passed to the map for display.
///
/// Announcing waypoints (`announcesArrival == true`) render as numbered white circles
/// with a coloured stroke. Shaping waypoints (`announcesArrival == false`) render as
/// small filled circles in the route colour with no number.
struct ViaWaypoint: Equatable {
    let latitude: Double
    let longitude: Double
    /// 1-based display index shown inside the circle marker.
    /// Only meaningful when `announcesArrival` is `true`.
    let index: Int
    /// `true` = via point rendered as a numbered circle.
    /// `false` = shaping point rendered as a small filled dot.
    let announcesArrival: Bool
}

// MARK: - RouteDisplay

/// Everything the map needs to render a stored route: the GeoJSON line,
/// any intermediate via-waypoint circles, and the route's colour.
struct RouteDisplay: Equatable {
    /// The item's database identifier, used to key the name label popup.
    let itemId: Int64
    let geojson: String
    let viaWaypoints: [ViaWaypoint]
    /// CSS hex colour string for the route line, e.g. `"#1A73E8"`.
    let colorHex: String
    /// Display name shown as a compact label at the route start point.
    let name: String
}

// MARK: - MapViewModel

/// Drives the map's displayed state.
///
/// ContentView calls ``drawRoute(geojson:)``, ``flyTo(longitude:latitude:zoom:)``,
/// ``showWaypoint(latitude:longitude:colorHex:itemId:name:)``, and ``clearWaypoint()``
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

    /// Shows a waypoint marker on the map at the given coordinates with a name label.
    func showWaypoint(
        latitude: Double,
        longitude: Double,
        colorHex: String,
        itemId: Int64,
        name: String,
        iconImageName: String?
    ) {
        waypointDisplay = WaypointDisplay(
            itemId: itemId,
            latitude: latitude,
            longitude: longitude,
            colorHex: colorHex,
            name: name,
            iconImageName: iconImageName
        )
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

    /// The active MapTiler style name — `"streets-v4"`, `"hybrid-v4"`, or `"topo-v4"`.
    ///
    /// Defaults to `"streets-v4"`. `ContentView.task` overwrites this with the
    /// value loaded from `app_settings` before the map first appears.
    var currentMapStyle: String = "streets-v4"
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
    /// The active MapTiler style name — passed to `setMapStyle()` in JS when it changes.
    let mapStyle: String
    /// Scale control unit — `"metric"` or `"imperial"` — mirrors the units preference.
    /// Passed to `setScaleUnits()` in JS when the preference changes.
    let mapScaleUnit: String
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

        // Apply a map style change if it has changed.
        if mapStyle != coordinator.lastMapStyle {
            let isFirstUpdate = coordinator.lastMapStyle == nil
            coordinator.lastMapStyle = mapStyle
            if coordinator.mapIsReady && !isFirstUpdate {
                // prepareStyleSwitch() sets suppressRecentre = true in JS so that the
                // layer-restore pass triggered by mapStyleLoaded does not reposition
                // the viewport.  setMapStyle() kicks off the style reload immediately.
                nsView.evaluateJavaScript(
                    "prepareStyleSwitch(); setMapStyle(\"\(mapStyle)\");"
                )
            }
            if !isFirstUpdate {
                // Persist the user's choice asynchronously.
                Task { try? await DatabaseManager.shared.saveMapStyle(mapStyle) }
            }
        }

        // Apply a scale unit change if the units preference has changed.
        if mapScaleUnit != coordinator.lastScaleUnit {
            let isFirstUpdate = coordinator.lastScaleUnit == nil
            coordinator.lastScaleUnit = mapScaleUnit
            if coordinator.mapIsReady && !isFirstUpdate {
                nsView.evaluateJavaScript("setScaleUnits(\"\(mapScaleUnit)\");")
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

        // Inject the initial style name and API key before the page's own scripts
        // run so MapLibreMap.html's getInitialStyleUrl() can build the full URL.
        // mapStyle is read from app_settings before the map first appears, so this
        // always reflects the user's saved choice on first render.
        let apiKey = ConfigService.mapTilerAPIKey
        let script = WKUserScript(
            source: "var mapStyleName = \"\(mapStyle)\"; var mapApiKey = \"\(apiKey)\";" +
                    " var mapScaleUnit = \"\(mapScaleUnit)\";",
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

        // MARK: Notification observation

        private var categoriesChangedObserver: (any NSObjectProtocol)?

        override init() {
            super.init()
            // Re-register category icons with MapLibre whenever the user
            // creates, edits, or deletes a category via the management window.
            categoriesChangedObserver = NotificationCenter.default.addObserver(
                forName: .routeKeeperCategoriesChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let wv = self.webView, self.mapIsReady else { return }
                self.applyRegisteredCategoryIcons(in: wv)
            }
        }

        deinit {
            if let observer = categoriesChangedObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

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

        /// Last style name applied to the map; `nil` on first render (before any
        /// `updateNSView` pass). Used to detect user-initiated style changes and
        /// skip the redundant initial write.
        var lastMapStyle: String? = nil

        /// Last scale unit applied; `nil` on first render. Used to detect
        /// preference changes and call `setScaleUnits()` in JS.
        var lastScaleUnit: String? = nil

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
        ///
        /// When showing, the item's `itemId` and `name` are passed as the fourth and
        /// fifth arguments so the JS function can attach a compact name label popup.
        func applyWaypointDisplay(_ display: WaypointDisplay?, in webView: WKWebView) {
            if let wp = display {
                let escapedName = wp.name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                // Pass iconImageName as a JS string, or null when absent.
                let iconArg: String
                if let icon = wp.iconImageName, !icon.isEmpty {
                    iconArg = "\"\(icon)\""
                } else {
                    iconArg = "null"
                }
                webView.evaluateJavaScript(
                    "showWaypoint(\(wp.latitude), \(wp.longitude), \"\(wp.colorHex)\"," +
                    " \(wp.itemId), \"\(escapedName)\", \(iconArg));"
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

        /// Fetches every category, renders its SF Symbol as a 40×40 px PNG, and
        /// calls `registerCategoryIcons()` in JavaScript to pre-register them with
        /// the MapLibre style.
        ///
        /// Must be called on `mapReady` and again on every `mapStyleLoaded` because
        /// `map.setStyle()` wipes all registered images.
        func applyRegisteredCategoryIcons(in webView: WKWebView) {
            Task { @MainActor in
                let json = await renderCategoryIcons()
                guard json != "[]" else { return }
                let escaped = json
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                do {
                    try await webView.evaluateJavaScript("registerCategoryIcons(\"\(escaped)\");")
                } catch {
                    print("registerCategoryIcons error: \(error)")
                }
            }
        }

        /// Calls either `showRoute()` or `clearRoute()` in JS depending on
        /// whether `display` is non-nil.
        ///
        /// Start and end flag icons are pre-registered as `"icon-route-start"` and
        /// `"icon-route-end"` via `registerCategoryIcons()` at map startup and after
        /// every style change, so they no longer need to be passed as base64 here.
        /// Intermediate waypoints are split into two JSON arrays: announcing via
        /// points (numbered circles) and shaping points (small filled dots), passed
        /// as the second and fourth arguments respectively.
        func applyRouteDisplay(_ display: RouteDisplay?, in webView: WKWebView) {
            if let display {
                let escaped = display.geojson
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")

                // Announcing via points — numbered circles.
                let announcing = display.viaWaypoints.filter { $0.announcesArrival }
                let viaItems = announcing.map { wp in
                    "{\"lat\":\(wp.latitude),\"lng\":\(wp.longitude),\"index\":\(wp.index)}"
                }.joined(separator: ",")
                let viaEscaped = "[\(viaItems)]"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                // Shaping points — small filled dots, no label.
                let shaping = display.viaWaypoints.filter { !$0.announcesArrival }
                let shapingItems = shaping.map { wp in
                    "{\"lat\":\(wp.latitude),\"lng\":\(wp.longitude)}"
                }.joined(separator: ",")
                let shapingEscaped = "[\(shapingItems)]"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                let escapedName = display.name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let js = "showRoute(\"\(escaped)\", \"\(viaEscaped)\"," +
                         " \"\(display.colorHex)\", \"\(shapingEscaped)\"," +
                         " \(display.itemId), \"\(escapedName)\")"
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

            // Fires after every setMapStyle() call once the new style is fully
            // applied.  Re-dispatch the current display state because map.setStyle()
            // wipes all custom sources and layers.  suppressRecentre was set to true
            // by the prepareStyleSwitch() call that preceded setMapStyle(), so the
            // JS-side flag ensures the viewport does not move during the restore.
            if type == "mapStyleLoaded" {
                guard let wv = webView else { return }
                // Re-register category icons — map.setStyle() wipes all images.
                applyRegisteredCategoryIcons(in: wv)
                applyWaypointDisplay(lastWaypointDisplay, in: wv)
                applyRouteDisplay(lastRouteDisplay, in: wv)
                applyMultiDisplay(lastMultiDisplay, in: wv)
                return
            }

            if type == "mapReady" {
                mapIsReady = true
                guard let wv = webView else { return }

                // Pre-register category icons so they are available when the
                // first waypoint is selected.
                applyRegisteredCategoryIcons(in: wv)

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
        mapStyle: "streets-v4", mapScaleUnit: "metric",
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

// MARK: - Category icon rendering

/// Renders a single SF Symbol at 14 pt into a transparent 40 × 40 px (20 pt @2×)
/// PNG and returns it as a base64-encoded string, or `nil` on failure.
///
/// The icon is centred in the square canvas so it sits cleanly over the white
/// circle rendered by `showWaypoint` / `showMultipleItems`.
private func categoryIconBase64(_ symbolName: String) -> String? {
    let ptSize:   CGFloat = 22
    let canvasPx: Int     = 84  // 28 pt × 3×

    let config = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black]))
    guard let symbol = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes:  nil,
        pixelsWide:        canvasPx,
        pixelsHigh:        canvasPx,
        bitsPerSample:     8,
        samplesPerPixel:   4,
        hasAlpha:          true,
        isPlanar:          false,
        colorSpaceName:    .deviceRGB,
        bytesPerRow:       0,
        bitsPerPixel:      0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    // Clear to fully transparent.
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: canvasPx, height: canvasPx).fill()

    // Draw the symbol centred in the canvas.
    let sw = symbol.size.width
    let sh = symbol.size.height
    let ox = (CGFloat(canvasPx) - sw) / 2
    let oy = (CGFloat(canvasPx) - sh) / 2
    symbol.draw(in: NSRect(x: ox, y: oy, width: sw, height: sh))

    return rep.representation(using: .png, properties: [:])?.base64EncodedString()
}

/// Fetches every category from the database, renders its SF Symbol icon as a
/// transparent PNG, and returns a JSON array of
/// `{ "name": "icon-<category>", "base64Png": "..." }` objects.
///
/// Also includes the two fixed route flag icons:
///   - `"icon-route-start"` from `flag.fill`
///   - `"icon-route-end"` from `flag.checkered`
///
/// The result is passed directly to `registerCategoryIcons()` in JavaScript.
/// Returns `"[]"` if no categories exist and no flag icons can be rendered.
func renderCategoryIcons() async -> String {
    let categories = (try? await DatabaseManager.shared.fetchCategories()) ?? []
    var entries: [[String: String]] = []

    // Fixed route flag icons — always included.
    if let b64 = categoryIconBase64("flag.fill") {
        entries.append(["name": "icon-route-start", "base64Png": b64])
    }
    if let b64 = categoryIconBase64("flag.checkered") {
        entries.append(["name": "icon-route-end", "base64Png": b64])
    }

    for cat in categories {
        guard let b64 = categoryIconBase64(cat.iconName) else { continue }
        entries.append([
            "name":      "icon-\(cat.name.lowercased())",
            "base64Png": b64
        ])
    }
    guard !entries.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: entries),
          let json = String(data: data, encoding: .utf8) else { return "[]" }
    return json
}
