//
//  ContentView.swift
//  RouteKeeper
//
//  Root view: two-column NavigationSplitView with library sidebar
//  and a main content area.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @State private var selectedList: RouteList?
    @State private var selectedItem: Item?
    @State private var libraryViewModel = LibraryViewModel()
    @State private var mapViewModel = MapViewModel()

    // Hardcoded test route: Matlock → Buxton
    private let testOrigin      = CLLocationCoordinate2D(latitude: 53.1355, longitude: -1.5567)
    private let testDestination = CLLocationCoordinate2D(latitude: 53.2595, longitude: -1.9107)

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                viewModel: libraryViewModel,
                selectedList: $selectedList,
                selectedItem: $selectedItem
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selectedList != nil || selectedItem != nil {
                // Reading mapViewModel properties here establishes SwiftUI observation:
                // when drawRoute() or flyTo() mutates them, ContentView re-renders
                // and updateNSView is called on MapView with the new values.
                MapView(
                    routeGeoJSON: mapViewModel.routeGeoJSON,
                    centerLon:    mapViewModel.centerLon,
                    centerLat:    mapViewModel.centerLat,
                    zoom:         mapViewModel.zoom
                )
            } else {
                Text("Select a list to view its contents")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            do {
                try await DatabaseManager.shared.setUp()
            } catch {
                print("Database setup failed: \(error)")
            }
            await libraryViewModel.load()
        }
        // Re-runs when the selection changes. selectedItem takes priority:
        // if an item is selected, its specific geometry would be drawn (not yet
        // implemented — item routes will be drawn here once stored in the DB).
        // Otherwise, the selected list triggers the hardcoded test route.
        .task(id: mapTaskKey) {
            if selectedItem != nil {
                // Item-specific map drawing: placeholder for Increment 6+.
                // Leave the current map state unchanged.
                return
            }
            guard selectedList != nil else { return }
            do {
                let geojson = try await RoutingService.shared.calculateRoute(
                    from: testOrigin,
                    to:   testDestination
                )
                mapViewModel.drawRoute(geojson: geojson)
                mapViewModel.flyTo(longitude: -1.733, latitude: 53.197, zoom: 11)
            } catch {
                print("Routing failed: \(error.localizedDescription)")
            }
        }
    }

    /// Combined key that re-fires the map task when either selection changes.
    private var mapTaskKey: MapTaskKey {
        MapTaskKey(listID: selectedList?.id, itemID: selectedItem?.id)
    }
}

/// `Equatable` identity for the `.task(id:)` map task.
private struct MapTaskKey: Equatable {
    let listID: Int64?
    let itemID: Int64?
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
