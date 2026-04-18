//
//  ContentView.swift
//  RouteKeeper
//
//  Root view: two-column NavigationSplitView with library sidebar
//  and a main content area.
//

import SwiftUI
import CoreLocation

// MARK: - MultiItemEntry helpers

/// A single announcing via waypoint encoded into the multi-item JSON payload.
private struct MultiViaWaypoint: Encodable {
    let lat: Double
    let lng: Double
    /// 1-based display index shown inside the circle marker.
    let index: Int
}

/// A single shaping waypoint encoded into the multi-item JSON payload.
private struct MultiShapingWaypoint: Encodable {
    let lat: Double
    let lng: Double
}

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
    /// Database identifier passed to `showLabel()` in JS as the popup dictionary key.
    var itemId: Int64?
    /// Display name shown as a compact label adjacent to the item on the map.
    var name: String?
    /// Announcing intermediate waypoints — rendered as numbered white circles.
    /// `nil` when the route has no via points or the item is not a route.
    var viaWaypoints: [MultiViaWaypoint]?
    /// Shaping (non-announcing) waypoints — rendered as small filled dots.
    /// `nil` when the route has no shaping points or the item is not a route.
    var shapingWaypoints: [MultiShapingWaypoint]?
    /// MapLibre image name for the category icon, e.g. `"icon-cafe"`.
    /// `nil` when the waypoint has no category or the item is not a waypoint.
    var iconImageName: String?
    /// Base64 PNG of the route SF Symbol icon used in the route name label popup.
    /// `nil` when the item is not a route.
    var routeIconBase64: String?
    /// Base64 PNG of the category SF Symbol rendered in white, used in the
    /// waypoint name label popup. `nil` when the waypoint has no category or
    /// the item is not a waypoint.
    var labelIconBase64: String?

    // Custom encoding so nil fields are omitted, keeping the JSON compact.
    enum CodingKeys: String, CodingKey {
        case type, lat, lng, color, geojson, itemId, name
        case viaWaypoints, shapingWaypoints, iconImageName, routeIconBase64, labelIconBase64
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(lat,              forKey: .lat)
        try c.encodeIfPresent(lng,              forKey: .lng)
        try c.encodeIfPresent(color,            forKey: .color)
        try c.encodeIfPresent(geojson,          forKey: .geojson)
        try c.encodeIfPresent(itemId,           forKey: .itemId)
        try c.encodeIfPresent(name,             forKey: .name)
        try c.encodeIfPresent(viaWaypoints,     forKey: .viaWaypoints)
        try c.encodeIfPresent(shapingWaypoints, forKey: .shapingWaypoints)
        try c.encodeIfPresent(iconImageName,    forKey: .iconImageName)
        try c.encodeIfPresent(routeIconBase64,  forKey: .routeIconBase64)
        try c.encodeIfPresent(labelIconBase64,  forKey: .labelIconBase64)
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
    @Environment(APIKeysManager.self) private var apiKeysManager
    @State private var selectedList: RouteList?
    /// Items selected in the bottom panel. Empty means nothing is selected.
    @State private var selectedItems: Set<Item> = []
    @State private var libraryViewModel = LibraryViewModel()
    @State private var mapViewModel = MapViewModel()
    @State private var showingRoutingProfilesSheet = false
    @State private var routeDistanceKm: Double? = nil
    @State private var routeDurationSeconds: Int? = nil
    @State private var routeElevationProfile: String? = nil
    @State private var routeColorHex: String = "#1A73E8"
    /// Non-nil while the map-tap "New waypoint here" sheet is open.
    @State private var mapTapPresentation: MapTapPresentation? = nil
    /// Persisted toggle: whether labels are shown when a list is displayed.
    @AppStorage("showListItemLabels") private var showListItemLabels = true
    /// Label data for the items in the currently displayed list, used to
    /// restore labels when the user turns them back on.
    @State private var currentListLabels: [LabelData] = []

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
                        mapTilerAPIKey:  apiKeysManager.mapTilerKey,
                        onAddWaypointAtCoordinate: { lat, lng in
                            mapTapPresentation = MapTapPresentation(
                                coordinate: MapCoordinate(latitude: lat, longitude: lng)
                            )
                        },
                        suppressMultiLabels: selectedList != nil && selectedItems.isEmpty
                                             && !showListItemLabels,
                        labelCommand: mapViewModel.labelCommand,
                        mapViewModel: mapViewModel
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        MapStylePicker(currentStyle: Binding(
                            get: { mapViewModel.currentMapStyle },
                            set: { mapViewModel.currentMapStyle = $0 }
                        ))
                        if selectedList != nil && selectedItems.isEmpty {
                            ShowLabelsButton(showLabels: $showListItemLabels)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let distKm = routeDistanceKm, let durSecs = routeDurationSeconds {
                        RouteStatsOverlay(
                            distanceKm:       distKm,
                            durationSeconds:  durSecs,
                            elevationProfile: routeElevationProfile,
                            colorHex:         routeColorHex
                        )
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
        .onChange(of: showListItemLabels) { _, newValue in
            guard selectedList != nil && selectedItems.isEmpty else { return }
            if newValue {
                mapViewModel.labelCommand = LabelCommand(action: .show(currentListLabels))
            } else {
                mapViewModel.labelCommand = LabelCommand(action: .hide)
            }
        }
        .focusedValue(\.showRoutingProfilesSheet, $showingRoutingProfilesSheet)
        .focusedValue(\.mapViewModel, mapViewModel)
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
            routeDistanceKm      = nil
            routeDurationSeconds = nil
            routeElevationProfile = nil
            currentListLabels = []
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
            routeDistanceKm       = nil
            routeDurationSeconds  = nil
            routeElevationProfile = nil
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            mapViewModel.clearMultiDisplay()
            let listItems = await fetchItemsForList(list)
            if !listItems.isEmpty {
                currentListLabels = await handleMultiItemDisplay(listItems)
            } else {
                currentListLabels = []
            }
        } else {
            // Nothing selected — clear everything.
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            mapViewModel.clearMultiDisplay()
            currentListLabels     = []
            routeDistanceKm       = nil
            routeDurationSeconds  = nil
            routeElevationProfile = nil
        }
    }

    // MARK: - Single-item selection (existing per-type behaviour)

    /// Shows one waypoint marker, one route line (with stats and via circles), or
    /// clears the map for tracks and nil — identical to the pre-Increment-24 behaviour.
    private func handleSingleItemSelection(_ item: Item) async {
        guard let itemId = item.id else {
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            routeDistanceKm       = nil
            routeDurationSeconds  = nil
            routeElevationProfile = nil
            return
        }
        switch item.type {
        case .waypoint:
            mapViewModel.clearRoute()
            routeDistanceKm       = nil
            routeDurationSeconds  = nil
            routeElevationProfile = nil
            do {
                if let wp = try await DatabaseManager.shared.fetchWaypointDetails(itemId: itemId) {
                    // Derive the SF Symbol name for the category icon, used by
                    // applyWaypointDisplay to render a base64 PNG via categoryIconBase64().
                    var iconImageName: String? = nil
                    if let categoryId = wp.categoryId {
                        let categories = (try? await DatabaseManager.shared.fetchCategories()) ?? []
                        if let cat = categories.first(where: { $0.id == categoryId }) {
                            iconImageName = cat.iconName
                        }
                    }
                    mapViewModel.showWaypoint(
                        latitude:      wp.latitude,
                        longitude:     wp.longitude,
                        colorHex:      wp.colorHex,
                        itemId:        itemId,
                        name:          item.name,
                        iconImageName: iconImageName
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
            var routeRecord = try? await DatabaseManager.shared.fetchRouteRecord(itemId: itemId)
            // Recalculate when flagged (e.g. waypoint moved) OR when geometry is
            // absent (e.g. newly imported route with no cached Valhalla result).
            if routeRecord?.needsRecalculation == true || routeRecord?.geometry == nil {
                let points = (try? await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: itemId
                )) ?? []
                if points.count >= 2,
                   let record = routeRecord {
                    let coords = points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    if let result = try? await RoutingService.shared.calculateRoute(
                        through:        coords,
                        avoidMotorways: record.avoidMotorways,
                        avoidTolls:     record.avoidTolls,
                        avoidUnpaved:   record.avoidUnpaved,
                        avoidFerries:   record.avoidFerries,
                        shortestRoute:  record.shortestRoute
                    ) {
                        try? await DatabaseManager.shared.updateRouteGeometryAndStats(
                            itemId:           itemId,
                            geometry:         result.geometry,
                            distanceKm:       result.distanceKm,
                            durationSeconds:  result.durationSeconds,
                            elevationProfile: result.elevationProfile
                        )
                        // Re-fetch so the display uses the updated geometry and stats.
                        routeRecord = try? await DatabaseManager.shared.fetchRouteRecord(
                            itemId: itemId
                        )
                    }
                }
            }
            routeDistanceKm       = routeRecord?.distanceKm
            routeDurationSeconds  = routeRecord?.durationSeconds
            routeElevationProfile = routeRecord?.elevationProfile
            routeColorHex         = routeRecord?.colorHex ?? "#1A73E8"
            if let geometry = routeRecord?.geometry {
                let allPoints = (try? await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: itemId
                )) ?? []
                let intermediates = allPoints.count > 2
                    ? Array(allPoints.dropFirst().dropLast())
                    : []
                // Announcing intermediates are numbered 1, 2, 3…; shaping points
                // carry index 0 (unused) so their rendering path shows a dot instead.
                var announcingCount = 0
                let viaWaypoints = intermediates.map { pt in
                    if pt.announcesArrival { announcingCount += 1 }
                    return ViaWaypoint(
                        latitude: pt.latitude,
                        longitude: pt.longitude,
                        index: announcingCount,
                        announcesArrival: pt.announcesArrival,
                        sequenceNumber: pt.sequenceNumber
                    )
                }
                mapViewModel.showRoute(RouteDisplay(
                    itemId: itemId,
                    geojson: geometry,
                    viaWaypoints: viaWaypoints,
                    colorHex: routeRecord?.colorHex ?? "#1A73E8",
                    name: item.name,
                    startSeq: allPoints.first?.sequenceNumber ?? 0,
                    endSeq: allPoints.last?.sequenceNumber ?? 0
                ))
            } else {
                mapViewModel.clearRoute()
            }
        case .track:
            mapViewModel.clearWaypoint()
            mapViewModel.clearRoute()
            routeDistanceKm       = nil
            routeDurationSeconds  = nil
            routeElevationProfile = nil
        }
    }

    // MARK: - Multi-item display

    /// Fetches geometry for each item in `items`, builds the JSON payload, and
    /// calls `mapViewModel.showMultipleItems()`.
    @discardableResult
    private func handleMultiItemDisplay(_ items: [Item]) async -> [LabelData] {
        let (json, labels) = await buildMultiItemsJson(items)
        guard !json.isEmpty else { return [] }
        mapViewModel.showMultipleItems(json)
        return labels
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
    private func buildMultiItemsJson(_ items: [Item]) async -> (json: String, labels: [LabelData]) {
        // Fetch categories once so the per-waypoint icon name lookup is O(1).
        let allCategories = (try? await DatabaseManager.shared.fetchCategories()) ?? []

        // Render the route label icon once — shared by all route entries.
        let routeIconBase64 = categoryIconBase64Compact(
            "arrow.triangle.turn.up.right.diamond",
            color: .white,
            ptSize: 18,
            canvasPx: 36
        )

        var entries: [MultiItemEntry] = []
        var labels: [LabelData] = []

        for item in items {
            guard let itemId = item.id else { continue }
            switch item.type {
            case .waypoint:
                if let wp = try? await DatabaseManager.shared.fetchWaypointDetails(itemId: itemId) {
                    var iconImageName: String? = nil
                    var labelIconBase64: String? = nil
                    if let categoryId = wp.categoryId,
                       let cat = allCategories.first(where: { $0.id == categoryId }) {
                        iconImageName = "icon-\(cat.name.lowercased())"
                        labelIconBase64 = categoryIconBase64Compact(
                            cat.iconName, color: .white, ptSize: 18, canvasPx: 36
                        )
                    }
                    entries.append(MultiItemEntry(
                        type: .waypoint,
                        lat: wp.latitude, lng: wp.longitude, color: wp.colorHex,
                        itemId: itemId, name: item.name,
                        iconImageName: iconImageName,
                        labelIconBase64: labelIconBase64
                    ))
                    labels.append(LabelData(
                        itemId: itemId,
                        lat: wp.latitude, lng: wp.longitude,
                        name: item.name, iconBase64: labelIconBase64
                    ))
                }
            case .route:
                guard let routeRecord = try? await DatabaseManager.shared.fetchRouteRecord(
                    itemId: itemId
                ) else { break }
                // Fetch points once — used for both recalculation and via/shaping arrays.
                let allPoints = (try? await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: itemId
                )) ?? []
                // Recalculate when flagged or when geometry is absent (e.g. imported route).
                var geometry = routeRecord.geometry
                if (routeRecord.needsRecalculation || routeRecord.geometry == nil),
                   allPoints.count >= 2 {
                    let coords = allPoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    if let result = try? await RoutingService.shared.calculateRoute(
                        through:        coords,
                        avoidMotorways: routeRecord.avoidMotorways,
                        avoidTolls:     routeRecord.avoidTolls,
                        avoidUnpaved:   routeRecord.avoidUnpaved,
                        avoidFerries:   routeRecord.avoidFerries,
                        shortestRoute:  routeRecord.shortestRoute
                    ) {
                        try? await DatabaseManager.shared.updateRouteGeometryAndStats(
                            itemId:           itemId,
                            geometry:         result.geometry,
                            distanceKm:       result.distanceKm,
                            durationSeconds:  result.durationSeconds,
                            elevationProfile: result.elevationProfile
                        )
                        geometry = result.geometry
                    }
                }
                guard let geometry else { break }
                // Build via and shaping waypoint arrays, matching the single-item path.
                let intermediates = allPoints.count > 2
                    ? Array(allPoints.dropFirst().dropLast())
                    : []
                var announcingCount = 0
                var viaWps: [MultiViaWaypoint] = []
                var shapingWps: [MultiShapingWaypoint] = []
                for pt in intermediates {
                    if pt.announcesArrival {
                        announcingCount += 1
                        viaWps.append(MultiViaWaypoint(
                            lat: pt.latitude, lng: pt.longitude, index: announcingCount
                        ))
                    } else {
                        shapingWps.append(MultiShapingWaypoint(
                            lat: pt.latitude, lng: pt.longitude
                        ))
                    }
                }
                entries.append(MultiItemEntry(
                    type: .route,
                    color: routeRecord.colorHex,
                    geojson: geometry,
                    itemId: itemId, name: item.name,
                    viaWaypoints:     viaWps.isEmpty     ? nil : viaWps,
                    shapingWaypoints: shapingWps.isEmpty ? nil : shapingWps,
                    routeIconBase64:  routeIconBase64
                ))
                if let mid = lineStringMidpoint(geometry) {
                    labels.append(LabelData(
                        itemId: itemId,
                        lat: mid.lat, lng: mid.lng,
                        name: item.name, iconBase64: routeIconBase64
                    ))
                }
            case .track:
                break
            }
        }

        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return ("", []) }
        return (json, labels)
    }
}

/// Returns the geometric midpoint of a GeoJSON LineString, mirroring the
/// `lineMidpoint()` helper in MapLibreMap.html.
private func lineStringMidpoint(_ geojson: String) -> (lat: Double, lng: Double)? {
    guard let data = geojson.data(using: .utf8),
          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = obj["type"] as? String, type == "LineString",
          let coords = obj["coordinates"] as? [[Double]],
          coords.count >= 2 else { return nil }
    var totalDist = 0.0
    for i in 1 ..< coords.count {
        let dlng = coords[i][0] - coords[i-1][0]
        let dlat = coords[i][1] - coords[i-1][1]
        totalDist += sqrt(dlng * dlng + dlat * dlat)
    }
    let half = totalDist / 2
    var running = 0.0
    for i in 1 ..< coords.count {
        let dlng = coords[i][0] - coords[i-1][0]
        let dlat = coords[i][1] - coords[i-1][1]
        let seg  = sqrt(dlng * dlng + dlat * dlat)
        if running + seg >= half {
            let t = seg > 0 ? (half - running) / seg : 0
            return (lat: coords[i-1][1] + t * dlat, lng: coords[i-1][0] + t * dlng)
        }
        running += seg
    }
    return coords.last.map { (lat: $0[1], lng: $0[0]) }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
