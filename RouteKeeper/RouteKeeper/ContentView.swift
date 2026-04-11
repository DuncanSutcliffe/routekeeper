//
//  ContentView.swift
//  RouteKeeper
//
//  Root view: two-column NavigationSplitView with library sidebar
//  and a main content area.
//

import AppKit
import SwiftUI

// MARK: - MultiItemEntry

/// Data transfer object for serialising a single library item to the
/// `showMultipleItems()` JavaScript function.
private struct MultiItemEntry: Encodable {
    enum EntryType: String, Encodable {
        case waypoint
        case route
    }

    let type: EntryType
    var lat: Double?
    var lng: Double?
    var color: String?
    var geojson: String?
    var startIcon: String?
    var endIcon: String?

    // Custom encoding so nil fields are omitted, keeping the JSON compact.
    enum CodingKeys: String, CodingKey {
        case type, lat, lng, color, geojson, startIcon, endIcon
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(lat,       forKey: .lat)
        try c.encodeIfPresent(lng,       forKey: .lng)
        try c.encodeIfPresent(color,     forKey: .color)
        try c.encodeIfPresent(geojson,   forKey: .geojson)
        try c.encodeIfPresent(startIcon, forKey: .startIcon)
        try c.encodeIfPresent(endIcon,   forKey: .endIcon)
    }
}

// MARK: - MapTapPresentation

/// Identity for a right-click–triggered waypoint-creation sheet.
///
/// Carrying the coordinate as a value type and giving it a unique `id` means
/// SwiftUI can correctly detect re-presentations at the same coordinate.
private struct MapTapPresentation: Identifiable {
    let id = UUID()
    let coordinate: MapCoordinate
}

// MARK: - ContentView

struct ContentView: View {
    @State private var selectedList: RouteList?
    /// Items selected in the bottom panel. Empty means nothing is selected.
    @State private var selectedItems: Set<Item> = []
    @State private var libraryViewModel = LibraryViewModel()
    @State private var mapViewModel = MapViewModel()
    @State private var showingRoutingProfilesSheet = false
    @State private var routeDistanceKm: Double? = nil
    @State private var routeDurationSeconds: Int? = nil
    /// Non-nil while the map-tap "New waypoint here" sheet is open.
    @State private var mapTapPresentation: MapTapPresentation? = nil

    // MARK: Combined selection key

    /// Combines both selection axes into a single Equatable value so a single
    /// `.task(id:)` reacts to changes in either the list or the item set.
    private struct MapSelectionKey: Equatable {
        var selectedListId: Int64?
        var selectedItemIds: Set<Int64>
    }

    private var mapSelectionKey: MapSelectionKey {
        MapSelectionKey(
            selectedListId: selectedList?.id ?? nil,
            selectedItemIds: Set(selectedItems.compactMap(\.id))
        )
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                viewModel: libraryViewModel,
                selectedList: $selectedList,
                selectedItems: $selectedItems
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selectedList != nil || !selectedItems.isEmpty {
                // Reading mapViewModel properties here establishes SwiftUI observation:
                // when any MapViewModel property changes, ContentView re-renders
                // and updateNSView is called on MapView with the new values.
                ZStack(alignment: .bottom) {
                    MapView(
                        routeGeoJSON:    mapViewModel.routeGeoJSON,
                        centerLon:       mapViewModel.centerLon,
                        centerLat:       mapViewModel.centerLat,
                        zoom:            mapViewModel.zoom,
                        waypointDisplay: mapViewModel.waypointDisplay,
                        routeDisplay:    mapViewModel.routeDisplay,
                        multiDisplay:    mapViewModel.multiDisplay,
                        mapStyle:        mapViewModel.currentMapStyle,
                        mapScaleUnit:    PreferencesManager.shared.units == "imperial"
                                             ? "imperial" : "metric",
                        onAddWaypointAtCoordinate: { lat, lng in
                            mapTapPresentation = MapTapPresentation(
                                coordinate: MapCoordinate(latitude: lat, longitude: lng)
                            )
                        }
                    )
                    MapStylePicker(currentStyle: Binding(
                        get: { mapViewModel.currentMapStyle },
                        set: { mapViewModel.currentMapStyle = $0 }
                    ))
                    .padding(.top, 12)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let distKm = routeDistanceKm, let durSecs = routeDurationSeconds {
                        RouteStatsOverlay(distanceKm: distKm, durationSeconds: durSecs)
                            .padding(.bottom, 16)
                    }
                }
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
            await PreferencesManager.shared.load()
            mapViewModel.currentMapStyle = await DatabaseManager.shared.loadMapStyle()
            await libraryViewModel.load()
        }
        // Re-fires whenever selectedItems or selectedList changes. Handles all
        // map display cases: single item, multi-item, list view, and cleared.
        .task(id: mapSelectionKey) {
            await handleSelectionChange()
        }
        .sheet(isPresented: $showingRoutingProfilesSheet) {
            RoutingProfilesSheet()
        }
        .sheet(item: $mapTapPresentation) { tap in
            NewWaypointSheet(
                viewModel: libraryViewModel,
                preselectedListID: selectedList?.id,
                prefilledCoordinate: tap.coordinate
            )
        }
        .focusedValue(\.showRoutingProfilesSheet, $showingRoutingProfilesSheet)
    }

    // MARK: - Selection handling

    /// Updates the map in response to any change in the combined selection state.
    ///
    /// Item selection takes precedence over list selection:
    /// - One item selected  → single-item display (existing per-type behaviour).
    /// - Many items selected → all rendered simultaneously via showMultipleItems.
    /// - No items, list selected → all list items rendered via showMultipleItems.
    /// - Nothing selected   → map cleared.
    private func handleSelectionChange() async {
        let items = Array(selectedItems)
        let list = selectedList

        if !items.isEmpty {
            // Item selection takes priority — clear any multi-display first.
            routeDistanceKm    = nil
            routeDurationSeconds = nil
            mapViewModel.clearMultiDisplay()

            if items.count == 1, let item = items.first {
                await handleSingleItemSelection(item)
            } else {
                mapViewModel.clearWaypoint()
                mapViewModel.clearRoute()
                await handleMultiItemDisplay(items)
            }
        } else if let list {
            // List selected with no items — show all list items.
            routeDistanceKm    = nil
            routeDurationSeconds = nil
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            mapViewModel.clearMultiDisplay()
            let listItems = await fetchItemsForList(list)
            if !listItems.isEmpty {
                await handleMultiItemDisplay(listItems)
            }
        } else {
            // Nothing selected — clear everything.
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            mapViewModel.clearMultiDisplay()
            routeDistanceKm    = nil
            routeDurationSeconds = nil
        }
    }

    // MARK: - Single-item selection (existing per-type behaviour)

    /// Shows one waypoint marker, one route line (with stats and via circles), or
    /// clears the map for tracks and nil — identical to the pre-Increment-24 behaviour.
    private func handleSingleItemSelection(_ item: Item) async {
        guard let itemId = item.id else {
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            routeDistanceKm    = nil
            routeDurationSeconds = nil
            return
        }
        switch item.type {
        case .waypoint:
            mapViewModel.clearRoute()
            routeDistanceKm    = nil
            routeDurationSeconds = nil
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
            let routeRecord = try? await DatabaseManager.shared.fetchRouteRecord(itemId: itemId)
            routeDistanceKm      = routeRecord?.distanceKm
            routeDurationSeconds = routeRecord?.durationSeconds
            if let geometry = routeRecord?.geometry {
                let allPoints = (try? await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: itemId
                )) ?? []
                let intermediates = allPoints.count > 2
                    ? Array(allPoints.dropFirst().dropLast())
                    : []
                let viaWaypoints = intermediates.enumerated().map { i, pt in
                    ViaWaypoint(latitude: pt.latitude, longitude: pt.longitude, index: i + 1)
                }
                mapViewModel.showRoute(RouteDisplay(geojson: geometry, viaWaypoints: viaWaypoints))
            } else {
                mapViewModel.clearRoute()
            }
        case .track:
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            routeDistanceKm    = nil
            routeDurationSeconds = nil
        }
    }

    // MARK: - Multi-item display

    /// Fetches geometry for each item in `items`, builds the JSON payload, and
    /// calls `mapViewModel.showMultipleItems()`.
    private func handleMultiItemDisplay(_ items: [Item]) async {
        let json = await buildMultiItemsJson(items)
        guard !json.isEmpty else { return }
        mapViewModel.showMultipleItems(json)
    }

    /// Returns the items belonging to `list`, using `fetchUnclassifiedItems()`
    /// for the sentinel (id == −1) and the normal fetch otherwise.
    private func fetchItemsForList(_ list: RouteList) async -> [Item] {
        do {
            if list.id == -1 {
                return try await DatabaseManager.shared.fetchUnclassifiedItems()
            }
            guard let listId = list.id else { return [] }
            return try await DatabaseManager.shared.fetchItems(for: listId)
        } catch {
            print("fetchItemsForList failed: \(error)")
            return []
        }
    }

    /// Builds the JSON string passed to `showMultipleItems()` in JavaScript.
    ///
    /// Generates start/end flag icons once and embeds them in every route entry.
    /// Items whose geometry is missing (NULL in the DB) are silently skipped.
    private func buildMultiItemsJson(_ items: [Item]) async -> String {
        let startIcon = sfSymbolBase64(
            "flag.fill",
            color: NSColor(red: 0.0, green: 0.5, blue: 0.15, alpha: 1.0)
        ) ?? ""
        let endIcon = sfSymbolBase64("flag.checkered", color: .black) ?? ""

        var entries: [MultiItemEntry] = []

        for item in items {
            guard let itemId = item.id else { continue }
            switch item.type {
            case .waypoint:
                if let wp = try? await DatabaseManager.shared.fetchWaypointDetails(itemId: itemId) {
                    entries.append(MultiItemEntry(
                        type: .waypoint,
                        lat: wp.latitude, lng: wp.longitude, color: wp.colorHex
                    ))
                }
            case .route:
                if let routeRecord = try? await DatabaseManager.shared.fetchRouteRecord(
                    itemId: itemId
                ), let geometry = routeRecord.geometry {
                    entries.append(MultiItemEntry(
                        type: .route,
                        geojson: geometry, startIcon: startIcon, endIcon: endIcon
                    ))
                }
            case .track:
                break
            }
        }

        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
