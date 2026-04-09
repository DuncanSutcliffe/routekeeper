//
//  RouteEditSheet.swift
//  RouteKeeper
//
//  Displays and allows in-memory editing of the waypoints (route_points)
//  for an existing route, then persists the changes via Valhalla + DatabaseManager.
//

import SwiftUI
import CoreLocation

struct RouteEditSheet: View {
    let routeItemId: Int64
    let routeName: String
    /// Called after a successful save so the parent can refresh the map.
    let onSave: () -> Void

    @State private var points: [RoutePoint] = []
    @State private var insertionIndex: Int?
    @State private var showingWaypointPicker = false
    @State private var isSaving = false
    @State private var showSaveError = false

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
                    name: summary.name
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
                let coords = points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let geometry = try await RoutingService.shared.calculateRoute(
                    through: coords
                )
                try await DatabaseManager.shared.updateRoutePoints(
                    points,
                    routeItemId: routeItemId,
                    geometry: geometry,
                    distanceMetres: nil,
                    durationSecs: nil
                )
                onSave()
                dismiss()
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
            // Leading badge: Start / Via N / End
            if index == 0 {
                badge("Start", color: .green)
            } else if index == points.count - 1 {
                badge("End", color: .red)
            } else {
                // index is 1-based among intermediates because index 0 is Start.
                badge("Via \(index)", color: .gray)
            }

            // Name or coordinate fallback
            if let name = point.name, !name.isEmpty {
                Text(name)
            } else {
                Text(String(format: "%.4f, %.4f", point.latitude, point.longitude))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Drag handle
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

            // Delete button
            Button {
                points.remove(at: index)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
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
