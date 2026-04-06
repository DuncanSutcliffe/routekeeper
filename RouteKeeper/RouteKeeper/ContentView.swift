//
//  ContentView.swift
//  RouteKeeper
//
//  Root view: two-column NavigationSplitView with library sidebar
//  and a main content area.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedList: RouteList?
    @State private var selectedItem: Item?
    @State private var libraryViewModel = LibraryViewModel()
    @State private var mapViewModel = MapViewModel()

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
                // when any MapViewModel property changes, ContentView re-renders
                // and updateNSView is called on MapView with the new values.
                MapView(
                    routeGeoJSON:    mapViewModel.routeGeoJSON,
                    centerLon:       mapViewModel.centerLon,
                    centerLat:       mapViewModel.centerLat,
                    zoom:            mapViewModel.zoom,
                    waypointDisplay: mapViewModel.waypointDisplay,
                    routeDisplay:    mapViewModel.routeDisplay
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
        // Re-fires whenever the selected item changes (including when it is
        // cleared to nil). Fetches waypoint geometry from the database and
        // updates the map accordingly.
        .task(id: selectedItem?.id) {
            await handleItemSelection(selectedItem)
        }
    }

    // MARK: - Item selection

    /// Updates the map in response to a sidebar item selection.
    ///
    /// Waypoints are shown as a circle pin at their stored coordinates.
    /// Routes and tracks clear the waypoint marker (their own geometry
    /// display is not yet implemented).
    /// A nil selection clears the waypoint marker.
    private func handleItemSelection(_ item: Item?) async {
        guard let item, let itemId = item.id else {
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            return
        }
        switch item.type {
        case .waypoint:
            mapViewModel.clearRoute()
            do {
                if let wp = try await DatabaseManager.shared.fetchWaypointDetails(itemId: itemId) {
                    mapViewModel.showWaypoint(
                        latitude:  wp.latitude,
                        longitude: wp.longitude,
                        colorHex:  wp.colorHex
                    )
                } else {
                    mapViewModel.clearWaypoint()
                }
            } catch {
                print("fetchWaypointDetails failed: \(error)")
                mapViewModel.clearWaypoint()
            }
        case .route:
            mapViewModel.clearWaypoint()
            do {
                if let geometry = try await DatabaseManager.shared.fetchRouteGeometry(itemId: itemId) {
                    mapViewModel.showRoute(geojson: geometry)
                } else {
                    mapViewModel.clearRoute()
                }
            } catch {
                print("fetchRouteGeometry failed: \(error)")
                mapViewModel.clearRoute()
            }
        case .track:
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
