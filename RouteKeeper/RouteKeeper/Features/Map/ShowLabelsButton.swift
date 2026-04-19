//
//  ShowLabelsButton.swift
//  RouteKeeper
//
//  Floating panel with per-type label toggles, shown when a list is displayed.
//  Styled to match MapStylePicker and RouteStatsOverlay.
//

import SwiftUI

struct ShowLabelsPanel: View {
    @Binding var showRouteLabels: Bool
    @Binding var showTrackLabels: Bool
    @Binding var showWaypointLabels: Bool
    var hasRoutes: Bool
    var hasTracks: Bool
    var hasWaypoints: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show labels")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Routes")
                Spacer()
                Toggle("Routes", isOn: $showRouteLabels)
                    .labelsHidden()
                    .disabled(!hasRoutes)
            }
            HStack {
                Text("Tracks")
                Spacer()
                Toggle("Tracks", isOn: $showTrackLabels)
                    .labelsHidden()
                    .disabled(!hasTracks)
            }
            HStack {
                Text("Waypoints")
                Spacer()
                Toggle("Waypoints", isOn: $showWaypointLabels)
                    .labelsHidden()
                    .disabled(!hasWaypoints)
            }
        }
        .toggleStyle(.switch)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    @Previewable @State var routes = true
    @Previewable @State var tracks = false
    @Previewable @State var waypoints = true
    ShowLabelsPanel(
        showRouteLabels: $routes,
        showTrackLabels: $tracks,
        showWaypointLabels: $waypoints,
        hasRoutes: true,
        hasTracks: true,
        hasWaypoints: false
    )
    .padding()
}
