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
    @State private var libraryViewModel = LibraryViewModel()
    @State private var mapViewModel = MapViewModel()

    // Hardcoded test route: Matlock → Buxton
    private let testOrigin      = CLLocationCoordinate2D(latitude: 53.1355, longitude: -1.5567)
    private let testDestination = CLLocationCoordinate2D(latitude: 53.2595, longitude: -1.9107)

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                viewModel: libraryViewModel,
                selectedList: $selectedList
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selectedList != nil {
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
        // Re-runs automatically whenever selectedList changes.
        // Cancels the previous task if the selection changes mid-flight.
        .task(id: selectedList) {
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
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
