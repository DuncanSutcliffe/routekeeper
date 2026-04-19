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
import CoreLocation

// MARK: - UndoRecord

/// A single reversible map-drag operation, stored on the undo stack.
enum UndoRecord {
    /// A route point or library waypoint was moved to a new position.
    /// `sequenceNumber == -1` indicates a library waypoint; `routeItemId` holds the
    /// waypoint's `item_id` in that case. For route points, both fields are as named.
    case movedPoint(routeItemId: Int64, sequenceNumber: Int,
                    previousLat: Double, previousLng: Double)
    /// A new shaping point was inserted into a route at the given sequence number.
    case insertedPoint(routeItemId: Int64, sequenceNumber: Int)
}

extension Notification.Name {
    static let routeKeeperPerformUndo      = Notification.Name("routeKeeperPerformUndo")
    /// Posted after any library write operation so LibraryViewModel can reload.
    static let routeKeeperLibraryDidChange = Notification.Name("routeKeeperLibraryDidChange")
    /// Posted by the Edit menu and keyboard shortcut to remove selected items from the current list.
    static let routeKeeperRemoveFromList   = Notification.Name("routeKeeperRemoveFromList")
    /// Posted by the Edit menu and keyboard shortcut to permanently delete selected items.
    static let routeKeeperDeleteSelected   = Notification.Name("routeKeeperDeleteSelected")
}

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

// MARK: - LabelData

/// Position and display info for a single map label.
///
/// Stored by ContentView when a list is displayed so labels can be
/// restored without a full re-render when the user turns them back on.
struct LabelData: Equatable {
    let itemId: Int64
    let lat: Double
    let lng: Double
    let name: String
    let iconBase64: String?
}

// MARK: - LabelCommand

/// A one-shot instruction to show or hide map labels.
///
/// Each instance carries a unique `id` so the Coordinator always executes
/// it even when the same action is requested twice in a row.
struct LabelCommand {
    let id = UUID()
    enum Action {
        case hide
        case show([LabelData])
        /// Hides only the labels for the given items by calling `hideLabel(itemId)`
        /// for each, leaving all other visible labels untouched.
        case hideSpecific([LabelData])
    }
    let action: Action
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
    /// The `sequence_number` of the corresponding `route_points` row.
    /// Sent back to Swift in the `waypointDragged` bridge message so the
    /// correct DB row can be identified after a drag.
    let sequenceNumber: Int
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
    /// `sequence_number` of the start route_point (the first row in DB order).
    let startSeq: Int
    /// `sequence_number` of the end route_point (the last row in DB order).
    let endSeq: Int
}

// MARK: - TrackDisplay

/// Everything the map needs to render an imported GPS track: ordered coordinates,
/// colour, and line style.
struct TrackDisplay: Equatable {
    let itemId: Int64
    /// Ordered (lat, lon) pairs forming the track line.
    let points: [(lat: Double, lon: Double)]
    /// CSS hex colour string, e.g. `"#3E515A"`.
    let colorHex: String
    /// One of `"dotted"`, `"short_dash"`, `"long_dash"`, or `"solid"`.
    let lineStyle: String
    let name: String

    static func == (lhs: TrackDisplay, rhs: TrackDisplay) -> Bool {
        lhs.itemId == rhs.itemId
            && lhs.colorHex == rhs.colorHex
            && lhs.lineStyle == rhs.lineStyle
    }
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

    /// Non-nil when an imported track should be displayed on the map.
    var trackDisplay: TrackDisplay? = nil

    /// Displays a GPS track on the map.
    func showTrack(_ display: TrackDisplay) {
        trackDisplay = display
    }

    /// Removes the track line from the map.
    func clearTrack() {
        trackDisplay = nil
    }

    /// A one-shot label command applied by the Coordinator on the next
    /// `updateNSView` pass. Set by ContentView when the label toggle changes.
    var labelCommand: LabelCommand? = nil

    // MARK: Undo stack

    private(set) var undoStack: [UndoRecord] = []
    let undoStackMaxDepth = 1

    func pushUndo(_ record: UndoRecord) {
        undoStack.append(record)
        if undoStack.count > undoStackMaxDepth { undoStack.removeFirst() }
    }

    func popUndo() -> UndoRecord? {
        undoStack.popLast()
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
    /// The MapTiler API key injected into the map HTML at WebView creation time.
    let mapTilerAPIKey: String
    /// Called on the main thread when the user selects "New waypoint here" from the map
    /// context menu. Receives the WGS-84 latitude and longitude of the right-click point.
    let onAddWaypointAtCoordinate: ((Double, Double) -> Void)?
    /// When `true`, `hideAllLabels()` is appended to the `showMultipleItems()` JS call
    /// so labels are suppressed without a visible flash.
    let suppressMultiLabels: Bool
    /// A one-shot label command applied by the Coordinator on the next render pass.
    let labelCommand: LabelCommand?
    /// Non-nil when a GPS track should be rendered on the map.
    let trackDisplay: TrackDisplay?
    /// Reference to the owning MapViewModel; set on the Coordinator each pass so
    /// drag handlers can push undo records and the undo action can pop them.
    let mapViewModel: MapViewModel

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

        // Track suppressMultiLabels for mapStyleLoaded restores.
        coordinator.lastSuppressMultiLabels = suppressMultiLabels

        // Apply a multi-item display change if it has changed.
        if multiDisplay != coordinator.lastMultiDisplay {
            coordinator.lastMultiDisplay = multiDisplay
            if coordinator.mapIsReady {
                coordinator.applyMultiDisplay(
                    multiDisplay, suppressLabels: suppressMultiLabels, in: nsView
                )
            } else {
                coordinator.pendingMultiDisplay = multiDisplay
                coordinator.pendingSuppressMultiLabels = suppressMultiLabels
            }
        }

        // Execute a one-shot label command if one has been issued.
        if labelCommand?.id != coordinator.lastLabelCommandId {
            coordinator.lastLabelCommandId = labelCommand?.id
            if coordinator.mapIsReady, let cmd = labelCommand {
                coordinator.applyLabelCommand(cmd, in: nsView)
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

        // Apply a track display change if it has changed.
        if trackDisplay != coordinator.lastTrackDisplay {
            coordinator.lastTrackDisplay = trackDisplay
            if coordinator.mapIsReady {
                coordinator.applyTrackDisplay(trackDisplay, in: nsView)
            } else {
                coordinator.pendingTrackDisplay = trackDisplay
            }
        }

        // Keep the callback current so the Coordinator always calls back into
        // the latest ContentView closure, even after SwiftUI re-renders.
        coordinator.onAddWaypointAtCoordinate = onAddWaypointAtCoordinate
        coordinator.mapViewModel = mapViewModel
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
        let apiKey = mapTilerAPIKey
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
        private var performUndoObserver: (any NSObjectProtocol)?

        /// Weak reference to the owning MapViewModel; refreshed each updateNSView pass.
        weak var mapViewModel: MapViewModel?

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
            performUndoObserver = NotificationCenter.default.addObserver(
                forName: .routeKeeperPerformUndo,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.executeUndo()
            }
        }

        deinit {
            if let observer = categoriesChangedObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = performUndoObserver {
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

        /// UUID of the last-applied `LabelCommand`; used to detect re-fires.
        var lastLabelCommandId: UUID? = nil

        /// Suppress-labels flag from the last `updateNSView` pass; used when
        /// restoring display state after a map style reload.
        var lastSuppressMultiLabels: Bool = false

        /// Suppress-labels flag queued before the map was ready, flushed on mapReady.
        var pendingSuppressMultiLabels: Bool = false

        var lastTrackDisplay: TrackDisplay? = nil
        var pendingTrackDisplay: TrackDisplay? = nil
        /// itemId of the track whose label is currently shown; used to hide it when the track is cleared.
        var shownTrackItemId: Int64? = nil

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
                // Generate a base64 PNG for the category icon and pass it directly
                // to showWaypoint(), or pass null when the waypoint has no category.
                let iconArg: String
                if let symbolName = wp.iconImageName, !symbolName.isEmpty,
                   let b64 = categoryIconBase64Compact(symbolName, color: .white) {
                    iconArg = "\"\(b64)\""
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
        /// When `suppressLabels` is `true`, `hideAllLabels()` is appended to the same
        /// JS string so both calls execute atomically with no visible label flash.
        func applyMultiDisplay(_ json: String?, suppressLabels: Bool, in webView: WKWebView) {
            if let json {
                let escaped = json
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")
                if suppressLabels {
                    webView.evaluateJavaScript(
                        "showMultipleItems(\"\(escaped)\"); hideAllLabels();"
                    )
                } else {
                    webView.evaluateJavaScript("showMultipleItems(\"\(escaped)\");")
                }
            } else {
                webView.evaluateJavaScript("clearMultipleItems();")
            }
        }

        /// Executes a one-shot label show or hide command in JavaScript.
        func applyLabelCommand(_ cmd: LabelCommand, in webView: WKWebView) {
            switch cmd.action {
            case .hide:
                webView.evaluateJavaScript("hideAllLabels();")
            case .hideSpecific(let labels):
                for label in labels {
                    webView.evaluateJavaScript("hideLabel(\(label.itemId));")
                }
            case .show(let labels):
                for label in labels {
                    let escapedName = label.name
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    let iconArg = label.iconBase64.map { "\"\($0)\"" } ?? "null"
                    webView.evaluateJavaScript(
                        "showLabel(\(label.itemId), \(label.lng), \(label.lat)," +
                        " \"\(escapedName)\", \(iconArg));"
                    )
                }
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
        /// Start and end flag icons are rendered as base64 PNGs using
        /// `categoryIconBase64Compact()` in the route's colour and passed as the
        /// final two arguments to `showRoute()`. Intermediate waypoints are split
        /// into two JSON arrays: announcing via points (numbered circles) and
        /// shaping points (small filled dots), passed as the second and fourth
        /// arguments respectively.
        func applyRouteDisplay(_ display: RouteDisplay?, in webView: WKWebView) {
            if let display {
                let escaped = display.geojson
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")

                // Announcing via points — numbered, draggable circles.
                let announcing = display.viaWaypoints.filter { $0.announcesArrival }
                let viaItems = announcing.map { wp in
                    "{\"lat\":\(wp.latitude),\"lng\":\(wp.longitude)," +
                    "\"index\":\(wp.index),\"seq\":\(wp.sequenceNumber)}"
                }.joined(separator: ",")
                let viaEscaped = "[\(viaItems)]"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                // Shaping points — small filled dots, draggable, no label.
                let shaping = display.viaWaypoints.filter { !$0.announcesArrival }
                let shapingItems = shaping.map { wp in
                    "{\"lat\":\(wp.latitude),\"lng\":\(wp.longitude)," +
                    "\"seq\":\(wp.sequenceNumber)}"
                }.joined(separator: ",")
                let shapingEscaped = "[\(shapingItems)]"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                let escapedName = display.name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                let routeIconArg = categoryIconBase64Compact(
                    "arrow.triangle.turn.up.right.diamond",
                    color: .white,
                    ptSize: 18,
                    canvasPx: 36
                ).map { "\"\($0)\"" } ?? "null"

                let js = "showRoute(\"\(escaped)\", \"\(viaEscaped)\"," +
                         " \"\(display.colorHex)\", \"\(shapingEscaped)\"," +
                         " \(display.itemId), \"\(escapedName)\"," +
                         " \(display.startSeq), \(display.endSeq)," +
                         " \(routeIconArg))"
                webView.evaluateJavaScript(js)
            } else {
                webView.evaluateJavaScript("clearRoute();")
            }
        }

        /// Calls either `showTrack()` or `hideTrack()` in JS depending on whether
        /// `display` is non-nil.
        func applyTrackDisplay(_ display: TrackDisplay?, in webView: WKWebView) {
            guard let display else {
                webView.evaluateJavaScript("hideTrack();")
                if let id = shownTrackItemId {
                    webView.evaluateJavaScript("hideLabel(\(id));")
                    shownTrackItemId = nil
                }
                return
            }
            // Hide the previous track's label before showing a new one (Fix 3).
            if let prevId = shownTrackItemId, prevId != display.itemId {
                webView.evaluateJavaScript("hideLabel(\(prevId));")
            }
            let pointsJSON = display.points.map {
                "{\"lat\":\($0.lat),\"lng\":\($0.lon)}"
            }.joined(separator: ",")
            let escapedName = display.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let trackData = "{\"itemId\":\(display.itemId)," +
                "\"color\":\"\(display.colorHex)\"," +
                "\"lineStyle\":\"\(display.lineStyle)\"," +
                "\"name\":\"\(escapedName)\"," +
                "\"points\":[\(pointsJSON)]}"
            let escaped = trackData
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            webView.evaluateJavaScript("showTrack(\"\(escaped)\");")
            // Place label at the geometric midpoint of the track (Fix 1).
            let mid = trackMidpoint(display.points)
            webView.evaluateJavaScript(
                "showLabel(\(display.itemId), \(mid.lon), \(mid.lat)," +
                " \"\(escapedName)\", null);"
            )
            shownTrackItemId = display.itemId
        }

        // MARK: Undo execution

        /// Pops the top undo record and executes the reverse operation.
        func executeUndo() {
            guard let record = mapViewModel?.popUndo(),
                  let wv = webView else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    switch record {

                    case .movedPoint(let routeItemId, let sequenceNumber,
                                     let previousLat, let previousLng):
                        if sequenceNumber == -1 {
                            // Library waypoint: restore previous position in DB and redraw.
                            try await DatabaseManager.shared.updateWaypointPosition(
                                itemId: routeItemId,
                                latitude: previousLat,
                                longitude: previousLng
                            )
                            if let existing = lastWaypointDisplay,
                               existing.itemId == routeItemId {
                                let restored = WaypointDisplay(
                                    itemId:        routeItemId,
                                    latitude:      previousLat,
                                    longitude:     previousLng,
                                    colorHex:      existing.colorHex,
                                    name:          existing.name,
                                    iconImageName: existing.iconImageName
                                )
                                lastWaypointDisplay = restored
                                applyWaypointDisplay(restored, in: wv)
                            }
                        } else {
                            // Route point: restore previous position, recalculate, redraw.
                            guard let display = lastRouteDisplay else { return }
                            try await DatabaseManager.shared.updateRoutePointPosition(
                                routeItemId:    routeItemId,
                                sequenceNumber: sequenceNumber,
                                latitude:       previousLat,
                                longitude:      previousLng
                            )
                            try await recalculateAndRedraw(
                                routeItemId: routeItemId,
                                display:     display,
                                in:          wv
                            )
                        }

                    case .insertedPoint(let routeItemId, let sequenceNumber):
                        guard let display = lastRouteDisplay else { return }
                        var allPoints = try await DatabaseManager.shared.fetchRoutePoints(
                            routeItemId: routeItemId
                        )
                        allPoints.removeAll { $0.sequenceNumber == sequenceNumber }
                        guard allPoints.count >= 2 else { return }
                        guard let route = try await DatabaseManager.shared.fetchRouteRecord(
                            itemId: routeItemId
                        ) else { return }
                        let coords = allPoints.map {
                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                   longitude: $0.longitude)
                        }
                        let result = try await RoutingService.shared.calculateRoute(
                            through:        coords,
                            avoidMotorways: route.avoidMotorways,
                            avoidTolls:     route.avoidTolls,
                            avoidUnpaved:   route.avoidUnpaved,
                            avoidFerries:   route.avoidFerries,
                            shortestRoute:  route.shortestRoute
                        )
                        let snapped = result.snappedLocations
                        for i in allPoints.indices where i < snapped.count {
                            allPoints[i].latitude  = snapped[i].latitude
                            allPoints[i].longitude = snapped[i].longitude
                        }
                        try await DatabaseManager.shared.updateRoutePoints(
                            allPoints,
                            routeItemId:      routeItemId,
                            geometry:         result.geometry,
                            distanceKm:       result.distanceKm,
                            durationSeconds:  result.durationSeconds,
                            elevationProfile: result.elevationProfile
                        )
                        let savedPoints = try await DatabaseManager.shared.fetchRoutePoints(
                            routeItemId: routeItemId
                        )
                        let newDisplay = buildRouteDisplay(from: savedPoints,
                                                           result: result,
                                                           existing: display)
                        try await wv.evaluateJavaScript("suppressRecentre = true;")
                        applyRouteDisplay(newDisplay, in: wv)
                    }
                } catch {
                    print("executeUndo failed: \(error)")
                }
            }
        }

        /// Recalculates a route via Valhalla using its current route_points, applies
        /// snapped coordinates, persists the updated point list, and redraws the map.
        private func recalculateAndRedraw(
            routeItemId: Int64,
            display: RouteDisplay,
            in wv: WKWebView
        ) async throws {
            var allPoints = try await DatabaseManager.shared.fetchRoutePoints(
                routeItemId: routeItemId
            )
            guard let route = try await DatabaseManager.shared.fetchRouteRecord(
                itemId: routeItemId
            ) else { return }
            let coords = allPoints.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let result = try await RoutingService.shared.calculateRoute(
                through:        coords,
                avoidMotorways: route.avoidMotorways,
                avoidTolls:     route.avoidTolls,
                avoidUnpaved:   route.avoidUnpaved,
                avoidFerries:   route.avoidFerries,
                shortestRoute:  route.shortestRoute
            )
            let snapped = result.snappedLocations
            for i in allPoints.indices where i < snapped.count {
                allPoints[i].latitude  = snapped[i].latitude
                allPoints[i].longitude = snapped[i].longitude
            }
            try await DatabaseManager.shared.updateRoutePoints(
                allPoints,
                routeItemId:      routeItemId,
                geometry:         result.geometry,
                distanceKm:       result.distanceKm,
                durationSeconds:  result.durationSeconds,
                elevationProfile: result.elevationProfile
            )
            let savedPoints = try await DatabaseManager.shared.fetchRoutePoints(
                routeItemId: routeItemId
            )
            let newDisplay = buildRouteDisplay(from: savedPoints, result: result,
                                               existing: display)
            try await wv.evaluateJavaScript("suppressRecentre = true;")
            applyRouteDisplay(newDisplay, in: wv)
        }

        /// Builds a RouteDisplay from a freshly-fetched ordered point list and a
        /// Valhalla result, preserving presentation metadata from an existing display.
        private func buildRouteDisplay(
            from savedPoints: [RoutePoint],
            result: RouteResult,
            existing display: RouteDisplay
        ) -> RouteDisplay {
            let intermediates = savedPoints.count > 2
                ? Array(savedPoints.dropFirst().dropLast()) : []
            var announcingCount = 0
            let viaWaypoints = intermediates.map { pt -> ViaWaypoint in
                if pt.announcesArrival { announcingCount += 1 }
                return ViaWaypoint(
                    latitude:         pt.latitude,
                    longitude:        pt.longitude,
                    index:            announcingCount,
                    announcesArrival: pt.announcesArrival,
                    sequenceNumber:   pt.sequenceNumber
                )
            }
            return RouteDisplay(
                itemId:       display.itemId,
                geojson:      result.geometry,
                viaWaypoints: viaWaypoints,
                colorHex:     display.colorHex,
                name:         display.name,
                startSeq:     savedPoints.first?.sequenceNumber ?? display.startSeq,
                endSeq:       savedPoints.last?.sequenceNumber  ?? display.endSeq
            )
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

            if type == "debugLog" {
                let msg = body["message"] as? String ?? "(no message)"
                print("JS debugLog: \(msg)")
                return
            }

            if type == "waypointMoved" {
                guard let itemIdInt   = body["itemId"]      as? Int,
                      let latitude    = body["latitude"]    as? Double,
                      let longitude   = body["longitude"]   as? Double,
                      let previousLat = body["previousLat"] as? Double,
                      let previousLng = body["previousLng"] as? Double else { return }
                let itemId = Int64(itemIdInt)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        // 1. Persist the new waypoint position.
                        try await DatabaseManager.shared.updateWaypointPosition(
                            itemId:    itemId,
                            latitude:  latitude,
                            longitude: longitude
                        )
                        mapViewModel?.pushUndo(.movedPoint(
                            routeItemId:  itemId,
                            sequenceNumber: -1,
                            previousLat:  previousLat,
                            previousLng:  previousLng
                        ))
                        // 2. Find any routes whose route_points reference this waypoint.
                        let routes = try await DatabaseManager.shared
                            .fetchRoutesContainingWaypoint(itemId: itemId)
                        guard !routes.isEmpty else { return }
                        // 3. Ask the user whether to propagate the new position.
                        let alert = NSAlert()
                        alert.messageText = "Update Route Waypoints?"
                        let count = routes.count
                        let routeList = routes.map { $0.routeName }.joined(separator: ", ")
                        alert.informativeText = "This waypoint is used by " +
                            "\(count == 1 ? "1 route" : "\(count) routes"): " +
                            "\(routeList). Update those routes to use the new " +
                            "position? (Routes will be recalculated next time " +
                            "they are edited.)"
                        alert.addButton(withTitle: "Update Routes")
                        alert.addButton(withTitle: "Leave Routes")
                        let response = alert.runModal()
                        guard response == .alertFirstButtonReturn else { return }
                        // 4. Update route_points rows and mark routes for recalculation.
                        try await DatabaseManager.shared.updateRoutePointsForWaypoint(
                            waypointItemId: itemId,
                            latitude:       latitude,
                            longitude:      longitude
                        )
                    } catch {
                        print("waypointMoved update failed: \(error)")
                    }
                }
                return
            }

            if type == "addWaypointAtCoordinate" {
                guard let lat = body["lat"] as? Double,
                      let lng = body["lng"] as? Double else { return }
                onAddWaypointAtCoordinate?(lat, lng)
                return
            }

            if type == "waypointDragged" {
                guard let routeItemIdInt = body["routeItemId"]    as? Int,
                      let sequenceNumber = body["sequenceNumber"] as? Int,
                      let latitude       = body["latitude"]       as? Double,
                      let longitude      = body["longitude"]      as? Double,
                      let previousLat    = body["previousLat"]    as? Double,
                      let previousLng    = body["previousLng"]    as? Double else { return }
                let routeItemId = Int64(routeItemIdInt)
                guard let display = lastRouteDisplay else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        // 1. Persist the dropped position.
                        try await DatabaseManager.shared.updateRoutePointPosition(
                            routeItemId:    routeItemId,
                            sequenceNumber: sequenceNumber,
                            latitude:       latitude,
                            longitude:      longitude
                        )
                        // 2. Reload all points so Valhalla sees the updated position.
                        var allPoints = try await DatabaseManager.shared.fetchRoutePoints(
                            routeItemId: routeItemId
                        )
                        // 3. Fetch stored routing criteria from the route record.
                        guard let route = try await DatabaseManager.shared.fetchRouteRecord(
                            itemId: routeItemId
                        ) else { return }
                        // 4. Recalculate via Valhalla using the same costing options.
                        let coords = allPoints.map {
                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                   longitude: $0.longitude)
                        }
                        let result = try await RoutingService.shared.calculateRoute(
                            through:        coords,
                            avoidMotorways: route.avoidMotorways,
                            avoidTolls:     route.avoidTolls,
                            avoidUnpaved:   route.avoidUnpaved,
                            avoidFerries:   route.avoidFerries,
                            shortestRoute:  route.shortestRoute
                        )
                        // 5. Apply snapped coordinates from the Valhalla response,
                        //    then save the updated point list and new geometry.
                        let snapped = result.snappedLocations
                        for i in allPoints.indices where i < snapped.count {
                            allPoints[i].latitude  = snapped[i].latitude
                            allPoints[i].longitude = snapped[i].longitude
                        }
                        try await DatabaseManager.shared.updateRoutePoints(
                            allPoints,
                            routeItemId:      routeItemId,
                            geometry:         result.geometry,
                            distanceKm:       result.distanceKm,
                            durationSeconds:  result.durationSeconds,
                            elevationProfile: result.elevationProfile
                        )
                        // 6. Rebuild RouteDisplay with updated positions and redraw.
                        //    suppressRecentre prevents the viewport jumping to fitBounds.
                        let intermediates = allPoints.count > 2
                            ? Array(allPoints.dropFirst().dropLast()) : []
                        var announcingCount = 0
                        let viaWaypoints = intermediates.map { pt -> ViaWaypoint in
                            if pt.announcesArrival { announcingCount += 1 }
                            return ViaWaypoint(
                                latitude:         pt.latitude,
                                longitude:        pt.longitude,
                                index:            announcingCount,
                                announcesArrival: pt.announcesArrival,
                                sequenceNumber:   pt.sequenceNumber
                            )
                        }
                        let newDisplay = RouteDisplay(
                            itemId:       display.itemId,
                            geojson:      result.geometry,
                            viaWaypoints: viaWaypoints,
                            colorHex:     display.colorHex,
                            name:         display.name,
                            startSeq:     allPoints.first?.sequenceNumber ?? display.startSeq,
                            endSeq:       allPoints.last?.sequenceNumber  ?? display.endSeq
                        )
                        mapViewModel?.pushUndo(.movedPoint(
                            routeItemId:    routeItemId,
                            sequenceNumber: sequenceNumber,
                            previousLat:    previousLat,
                            previousLng:    previousLng
                        ))
                        guard let wv = self.webView else { return }
                        try await wv.evaluateJavaScript("suppressRecentre = true;")
                        self.applyRouteDisplay(newDisplay, in: wv)
                    } catch {
                        print("waypointDragged recalculation failed: \(error)")
                    }
                }
                return
            }

            if type == "insertShapingPoint" {
                guard let insertIndex = body["insertIndex"] as? Int,
                      let lng         = body["lng"]         as? Double,
                      let lat         = body["lat"]         as? Double,
                      let display     = lastRouteDisplay else { return }
                let routeItemId = display.itemId
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        // 1. Fetch the current ordered point list.
                        var points = try await DatabaseManager.shared.fetchRoutePoints(
                            routeItemId: routeItemId
                        )
                        // 2. Build the new shaping point and splice it in.
                        let newPoint = RoutePoint(
                            id:               nil,
                            routeItemId:      routeItemId,
                            sequenceNumber:   0,
                            latitude:         lat,
                            longitude:        lng,
                            elevation:        nil,
                            announcesArrival: false,
                            name:             String(format: "%.4f, %.4f", lat, lng),
                            waypointItemId:   nil
                        )
                        let safeIndex = max(1, min(insertIndex, points.count - 1))
                        points.insert(newPoint, at: safeIndex)
                        // 3. Fetch stored routing criteria.
                        guard let route = try await DatabaseManager.shared.fetchRouteRecord(
                            itemId: routeItemId
                        ) else { return }
                        // 4. Recalculate via Valhalla using the updated point list.
                        let coords = points.map {
                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                   longitude: $0.longitude)
                        }
                        let result = try await RoutingService.shared.calculateRoute(
                            through:        coords,
                            avoidMotorways: route.avoidMotorways,
                            avoidTolls:     route.avoidTolls,
                            avoidUnpaved:   route.avoidUnpaved,
                            avoidFerries:   route.avoidFerries,
                            shortestRoute:  route.shortestRoute
                        )
                        // 5. Apply snapped coordinates from the Valhalla response,
                        //    then persist the updated point list and new geometry.
                        let snapped = result.snappedLocations
                        for i in points.indices where i < snapped.count {
                            points[i].latitude  = snapped[i].latitude
                            points[i].longitude = snapped[i].longitude
                        }
                        try await DatabaseManager.shared.updateRoutePoints(
                            points,
                            routeItemId:     routeItemId,
                            geometry:        result.geometry,
                            distanceKm:      result.distanceKm,
                            durationSeconds: result.durationSeconds,
                            elevationProfile: result.elevationProfile
                        )
                        // 6. Reload the saved points to pick up the fresh sequence numbers.
                        let savedPoints = try await DatabaseManager.shared.fetchRoutePoints(
                            routeItemId: routeItemId
                        )
                        // 7. Rebuild RouteDisplay and redraw without moving the viewport.
                        let intermediates = savedPoints.count > 2
                            ? Array(savedPoints.dropFirst().dropLast()) : []
                        var announcingCount = 0
                        let viaWaypoints = intermediates.map { pt -> ViaWaypoint in
                            if pt.announcesArrival { announcingCount += 1 }
                            return ViaWaypoint(
                                latitude:         pt.latitude,
                                longitude:        pt.longitude,
                                index:            announcingCount,
                                announcesArrival: pt.announcesArrival,
                                sequenceNumber:   pt.sequenceNumber
                            )
                        }
                        let newDisplay = RouteDisplay(
                            itemId:   display.itemId,
                            geojson:  result.geometry,
                            viaWaypoints: viaWaypoints,
                            colorHex: display.colorHex,
                            name:     display.name,
                            startSeq: savedPoints.first?.sequenceNumber ?? display.startSeq,
                            endSeq:   savedPoints.last?.sequenceNumber  ?? display.endSeq
                        )
                        if safeIndex < savedPoints.count {
                            mapViewModel?.pushUndo(.insertedPoint(
                                routeItemId:    routeItemId,
                                sequenceNumber: savedPoints[safeIndex].sequenceNumber
                            ))
                        }
                        guard let wv = self.webView else { return }
                        try await wv.evaluateJavaScript("suppressRecentre = true;")
                        self.applyRouteDisplay(newDisplay, in: wv)
                    } catch {
                        print("insertShapingPoint recalculation failed: \(error)")
                    }
                }
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
                applyMultiDisplay(lastMultiDisplay, suppressLabels: lastSuppressMultiLabels, in: wv)
                applyTrackDisplay(lastTrackDisplay, in: wv)
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
                    applyMultiDisplay(
                        pending, suppressLabels: pendingSuppressMultiLabels, in: wv
                    )
                    pendingMultiDisplay = nil
                    pendingSuppressMultiLabels = false
                }

                // Flush any track display that arrived before the map was ready.
                if let pending = pendingTrackDisplay {
                    applyTrackDisplay(pending, in: wv)
                    pendingTrackDisplay = nil
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
        mapTilerAPIKey: "",
        onAddWaypointAtCoordinate: nil,
        suppressMultiLabels: false,
        labelCommand: nil,
        trackDisplay: nil,
        mapViewModel: MapViewModel()
    )
    .frame(width: 800, height: 600)
}

// MARK: - Track midpoint

/// Returns the coordinate at 50% of the cumulative Euclidean length of a track point array.
/// Mirrors the `lineMidpoint()` function in MapLibreMap.html.
private func trackMidpoint(_ pts: [(lat: Double, lon: Double)]) -> (lat: Double, lon: Double) {
    guard pts.count >= 2 else { return pts.first ?? (lat: 0, lon: 0) }
    var total = 0.0
    for i in 1 ..< pts.count {
        let dlng = pts[i].lon - pts[i-1].lon
        let dlat = pts[i].lat - pts[i-1].lat
        total += sqrt(dlng * dlng + dlat * dlat)
    }
    let half = total / 2
    var running = 0.0
    for i in 1 ..< pts.count {
        let dlng = pts[i].lon - pts[i-1].lon
        let dlat = pts[i].lat - pts[i-1].lat
        let seg = sqrt(dlng * dlng + dlat * dlat)
        if running + seg >= half {
            let t = seg > 0 ? (half - running) / seg : 0
            return (lat: pts[i-1].lat + t * dlat, lon: pts[i-1].lon + t * dlng)
        }
        running += seg
    }
    return pts.last!
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

/// Converts a CSS hex colour string (e.g. `"#1A73E8"`) to an `NSColor`.
private func nsColor(hex: String) -> NSColor {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    var rgb: UInt64 = 0
    Scanner(string: h).scanHexInt64(&rgb)
    return NSColor(
        srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
        green:   CGFloat((rgb >>  8) & 0xFF) / 255,
        blue:    CGFloat( rgb        & 0xFF) / 255,
        alpha:   1
    )
}

/// Renders a single SF Symbol at 18 pt into a transparent 36 × 36 px (18 pt @2×)
/// PNG and returns it as a base64-encoded string, or `nil` on failure.
///
/// Produces a compact icon sized to sit inside the waypoint marker circle
/// rendered by `showWaypoint()`. Uses the same weight as `categoryIconBase64(_:)`
/// but on a tighter canvas with no surrounding padding.
///
/// - Parameters:
///   - symbolName: The SF Symbol name, e.g. `"cup.and.saucer"`.
///   - color: The palette colour applied to the symbol. Defaults to black.
func categoryIconBase64Compact(_ symbolName: String,
                               color: NSColor = .black,
                               ptSize: CGFloat = 18,
                               canvasPx: Int = 36) -> String? {

    let config = NSImage.SymbolConfiguration(pointSize: ptSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
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
