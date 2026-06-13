//
//  RouteWaypointSheet.swift
//  RouteKeeper
//
//  Displays and allows in-memory editing of the waypoints (route_points)
//  for an existing route, then persists the changes via Valhalla + DatabaseManager.
//

import SwiftUI
import CoreLocation

struct RouteWaypointSheet: View {
    let routeItemId: Int64
    let routeName: String
    /// Called after a successful save so the parent can refresh the map.
    let onSave: () -> Void

    @State private var points: [RoutePoint] = []

    private var pointLabels: [Int64: String] { buildPointLabels(from: points) }

    private func labelFor(_ point: RoutePoint, at index: Int) -> String {
        if let id = point.id, let lbl = pointLabels[id] { return lbl }
        if let name = point.name, !name.isEmpty, !isCoordinatePair(name) { return name }
        if index == 0 { return "Start" }
        if index == points.count - 1 { return "End" }
        return "Point \(index)"
    }

    @State private var insertionIndex: Int?
    @State private var showingWaypointPicker = false
    @State private var isSaving = false
    @State private var showSaveError = false
    @State private var pendingDeleteIndex: Int? = nil

    private var pendingDeleteLabel: String {
        guard let idx = pendingDeleteIndex, idx < points.count else { return "" }
        return labelFor(points[idx], at: idx)
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Waypoints") {
                    if points.isEmpty {
                        Text("No waypoints found for this route.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                            // Waypoint row
                            pointRow(for: point, at: index)

                            // Insert button after every row, including the last
                            insertButton(after: index)
                        }
                        .onMove { source, destination in
                            points.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(routeName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Button("Save") { save() }
                            .disabled(points.count < 2)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $showingWaypointPicker) {
            WaypointPickerSheet { summary in
                let newPoint = RoutePoint(
                    id: nil,
                    routeItemId: routeItemId,
                    sequenceNumber: 0,       // recalculated on save
                    latitude: summary.latitude,
                    longitude: summary.longitude,
                    elevation: nil,
                    announcesArrival: true,
                    name: summary.name,
                    waypointItemId: summary.itemId
                )
                let index = insertionIndex ?? points.count
                points.insert(newPoint, at: min(index, points.count))
                insertionIndex = nil
            }
        }
        .alert("Route Calculation Failed", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Route calculation failed. Please check your internet " +
                 "connection and try again.")
        }
        .alert(
            "Delete \"\(pendingDeleteLabel)\"?",
            isPresented: Binding(
                get: { pendingDeleteIndex != nil },
                set: { if !$0 { pendingDeleteIndex = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let idx = pendingDeleteIndex {
                    points.remove(at: idx)
                }
                pendingDeleteIndex = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIndex = nil
            }
        }
        .task {
            do {
                await Task.yield()
                points = try await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: routeItemId
                )
            } catch {
                // Points remain empty; the list shows the placeholder message.
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        Task {
            do {
                // Start and End always announce arrival regardless of what was toggled.
                var pointsToSave = points
                if !pointsToSave.isEmpty {
                    pointsToSave[0].announcesArrival = true
                    pointsToSave[pointsToSave.count - 1].announcesArrival = true
                }
                let coords = pointsToSave.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                // Fetch the stored routing criteria so the recalculation honours them.
                let route = try? await DatabaseManager.shared.fetchRouteRecord(itemId: routeItemId)
                let result = try await RoutingService.shared.calculateRoute(
                    through:        coords,
                    avoidMotorways: route?.avoidMotorways ?? false,
                    avoidTolls:     route?.avoidTolls     ?? false,
                    avoidUnpaved:   route?.avoidUnpaved   ?? false,
                    avoidFerries:   route?.avoidFerries   ?? false,
                    shortestRoute:  route?.shortestRoute  ?? false
                )
                try await DatabaseManager.shared.updateRoutePoints(
                    pointsToSave,
                    routeItemId:      routeItemId,
                    geometry:         result.geometry,
                    distanceKm:       result.distanceKm,
                    durationSeconds:  result.durationSeconds,
                    elevationProfile: result.elevationProfile
                )
                onSave()
                dismiss()
            } catch {
                showSaveError = true
                isSaving = false
            }
        }
    }

    // MARK: - Set as start point

    /// Rotates the route so `sequenceNumber` becomes the new first point,
    /// then reloads the list and triggers the standard Valhalla replanning flow.
    private func setAsStartPoint(sequenceNumber: Int) {
        Task {
            isSaving = true
            do {
                try await DatabaseManager.shared.rotateRoutePoints(
                    routeItemId: routeItemId,
                    newStartSequenceNumber: sequenceNumber
                )
                points = try await DatabaseManager.shared.fetchRoutePoints(
                    routeItemId: routeItemId
                )
                save()
            } catch {
                showSaveError = true
                isSaving = false
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func pointRow(for point: RoutePoint, at index: Int) -> some View {
        HStack(spacing: 10) {
            // Leading badge: Start / Via N / Shaping / End
            if index == 0 {
                badge("Start", color: .green)
            } else if index == points.count - 1 {
                badge("End", color: .red)
            } else if point.announcesArrival {
                // Count only announcing intermediates up to and including this index.
                let viaNumber = points[1...index].filter { $0.announcesArrival }.count
                badge("Via \(viaNumber)", color: .gray)
            } else {
                badge("Shaping", color: .gray)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(labelFor(point, at: index))
                Text(String(format: "%.4f, %.4f", point.latitude, point.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Set as start point — omitted on the first row (already the start).
            if index > 0 {
                Button {
                    setAsStartPoint(sequenceNumber: point.sequenceNumber)
                } label: {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Set as start point")
            }

            // Announce toggle — intermediates only (not Start or End).
            if index > 0 && index < points.count - 1 {
                Button {
                    points[index].announcesArrival.toggle()
                } label: {
                    Image(systemName: point.announcesArrival ? "bell" : "bell.slash")
                        .foregroundStyle(point.announcesArrival ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(point.announcesArrival ? "Click to make shaping point" :
                      "Click to make announcing point")
            }

            // Drag handle
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

            // Delete button
            Button {
                pendingDeleteIndex = index
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Set as start point") {
                setAsStartPoint(sequenceNumber: point.sequenceNumber)
            }
            .disabled(point.sequenceNumber == 0)
        }
    }

    @ViewBuilder
    private func insertButton(after index: Int) -> some View {
        HStack {
            Spacer()
            Button {
                insertionIndex = index + 1
                showingWaypointPicker = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
