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

// MARK: - MapViewModel

/// Drives the map's displayed state.
///
/// ContentView calls ``drawRoute(geojson:)`` and ``flyTo(longitude:latitude:zoom:)``
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
}

// MARK: - MapView

struct MapView: NSViewRepresentable {

    // These properties are read from MapViewModel in ContentView's body,
    // establishing SwiftUI observation on the relevant MapViewModel properties.
    let routeGeoJSON: String?
    let centerLon: Double
    let centerLat: Double
    let zoom: Double

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

        /// Weak reference to the WKWebView, used to flush pendingRouteGeoJSON
        /// from inside the message handler (which has no other webView reference).
        weak var webView: WKWebView?

        // MARK: Change tracking

        var lastRouteGeoJSON: String? = nil
        var lastCenterLon: Double = .nan  // nan ensures the first flyTo always fires
        var lastCenterLat: Double = .nan
        var lastZoom: Double = .nan

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

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "routekeeper",
                  let body = message.body as? [String: Any] else { return }

            print("JS → Swift: \(body)")

            guard let type = body["type"] as? String else { return }

            if type == "mapReady" {
                mapIsReady = true
                // Flush any route that arrived before the map was ready.
                if let pending = pendingRouteGeoJSON, let wv = webView {
                    executeDrawRoute(geojson: pending, in: wv)
                    pendingRouteGeoJSON = nil
                    // Also apply the queued flyTo if centre was already set.
                    if !lastCenterLon.isNaN {
                        wv.evaluateJavaScript(
                            "map.flyTo({center: [\(lastCenterLon), \(lastCenterLat)], zoom: \(lastZoom)});"
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    MapView(routeGeoJSON: nil, centerLon: -2.0, centerLat: 54.0, zoom: 5)
        .frame(width: 800, height: 600)
}
