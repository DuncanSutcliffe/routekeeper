//
//  RouteStatsOverlay.swift
//  RouteKeeper
//
//  Floating panel shown over the map when a route with distance and duration
//  data is selected. Displays distance (in km or miles per the units preference)
//  and formatted duration side-by-side with a bullet separator.
//

import SwiftUI

struct RouteStatsOverlay: View {
    let distanceKm: Double
    let durationSeconds: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(distanceText)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)

            Text("•")
                .foregroundStyle(.secondary)

            Text(durationText)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private var distanceText: String {
        if PreferencesManager.shared.units == "imperial" {
            let miles = distanceKm * 0.621371
            return String(format: "%.1f mi", miles)
        } else {
            return String(format: "%.1f km", distanceKm)
        }
    }

    private var durationText: String {
        let totalMinutes = durationSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
