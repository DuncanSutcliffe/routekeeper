//
//  MapView.swift
//  RouteKeeper
//
//  NSViewRepresentable wrapping a WKWebView that displays the MapLibre GL JS map.
//  Swift → JS communication uses evaluateJavaScript(_:).
//  JS → Swift communication uses WKScriptMessageHandler ("routekeeper" handler).
//

import SwiftUI
import WebKit

struct MapView: NSViewRepresentable {

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(coordinator: context.coordinator))

        // Suppress the white background flash before the map tiles load.
        webView.setValue(false, forKey: "drawsBackground")

        guard
            let htmlURL = Bundle.main.url(forResource: "MapLibreMap", withExtension: "html"),
            let resourcesDir = htmlURL.deletingLastPathComponent() as URL?
        else {
            assertionFailure("MapLibreMap.html not found in app bundle — add it to the Xcode target.")
            return webView
        }

        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesDir)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates in this increment.
    }

    // MARK: - Private helpers

    private func makeConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // Register the message handler that JavaScript calls via:
        //   window.webkit.messageHandlers.routekeeper.postMessage({ ... })
        contentController.add(coordinator, name: "routekeeper")

        config.userContentController = contentController
        return config
    }

    // MARK: - Coordinator

    /// Receives JavaScript → Swift messages from the map.
    final class Coordinator: NSObject, WKScriptMessageHandler {

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "routekeeper" else { return }
            // Reserved for future increments (e.g. mapReady, featureTapped).
            if let body = message.body as? [String: Any] {
                print("JS → Swift: \(body)")
            }
        }
    }
}

#Preview {
    MapView()
        .frame(width: 800, height: 600)
}
