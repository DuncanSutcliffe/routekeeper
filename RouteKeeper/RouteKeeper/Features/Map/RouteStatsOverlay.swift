//
//  RouteStatsOverlay.swift
//  RouteKeeper
//
//  Floating panel shown over the map when a route with distance and duration
//  data is selected. Displays distance (in km or miles per the units preference)
//  and formatted duration. When the route has a non-null elevation_profile,
//  also shows total ascent/descent figures and a filled area chart.
//

import Charts
import SwiftUI

struct RouteStatsOverlay: View {
    let distanceKm: Double
    let durationSeconds: Int
    /// JSON-encoded array of elevation samples in metres. `nil` hides the chart.
    let elevationProfile: String?
    /// CSS hex colour of the route line (e.g. `"#1A73E8"`). Drives chart colours.
    var colorHex: String = "#1A73E8"

    // MARK: - Computed elevation data

    /// Parsed elevation array, or empty when profile is nil or unparseable.
    private var elevationSamples: [Double] {
        guard let json = elevationProfile,
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Double]
        else { return [] }
        return array
    }

    /// Total ascent in metres (sum of all positive step differences), rounded.
    private var totalAscentM: Int {
        let samples = elevationSamples
        guard samples.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1 ..< samples.count {
            let diff = samples[i] - samples[i - 1]
            if diff > 0 { sum += diff }
        }
        return Int(sum.rounded())
    }

    /// Total descent in metres (sum of all negative step differences), rounded.
    private var totalDescentM: Int {
        let samples = elevationSamples
        guard samples.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1 ..< samples.count {
            let diff = samples[i] - samples[i - 1]
            if diff < 0 { sum += -diff }
        }
        return Int(sum.rounded())
    }

    // MARK: - Chart data

    private struct ElevationPoint: Identifiable {
        let id: Int
        /// Distance from the start of the route in kilometres.
        let distanceKm: Double
        /// Elevation in metres.
        let elevationM: Double
    }

    private var chartPoints: [ElevationPoint] {
        let samples = elevationSamples
        guard samples.count > 1 else { return [] }
        let step = distanceKm / Double(samples.count - 1)
        return samples.enumerated().map { i, elev in
            ElevationPoint(id: i, distanceKm: Double(i) * step, elevationM: elev)
        }
    }

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            statsRow
            if !chartPoints.isEmpty {
                elevationChart
                    .frame(height: 60)
                    .overlay(alignment: .topLeading) {
                        elevationLabels
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, chartPoints.isEmpty ? 10 : 0)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    // MARK: - Subviews

    private var statsRow: some View {
        HStack(spacing: 12) {
            Text(distanceText)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)

            Text("•")
                .foregroundStyle(.secondary)

            Text(durationText)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)

            if !chartPoints.isEmpty {
                Text("•")
                    .foregroundStyle(.secondary)

                Text("↑ \(totalAscentM)m")
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)

                Text("↓ \(totalDescentM)m")
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)
            }
        }
        .padding(.bottom, chartPoints.isEmpty ? 0 : 8)
    }

    /// Three elevation tick labels (max, mid, min) overlaid on the left edge of the chart.
    private var elevationLabels: some View {
        let samples = elevationSamples
        let minVal  = samples.min() ?? 0
        let maxVal  = samples.max() ?? 0
        let midVal  = (minVal + maxVal) / 2
        // Round each value to the nearest 10 metres.
        let round10: (Double) -> Int = { Int(($0 / 10.0).rounded()) * 10 }
        let maxLabel = round10(maxVal)
        let midLabel = round10(midVal)
        let minLabel = round10(minVal)

        return VStack(alignment: .leading, spacing: 0) {
            Text("\(maxLabel)m")
            Spacer(minLength: 0)
            Text("\(midLabel)m")
            Spacer(minLength: 0)
            Text("\(minLabel)m")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
        .frame(height: 60)
    }

    private var elevationChart: some View {
        let points = chartPoints
        let elevations = points.map(\.elevationM)
        let minElev = (elevations.min() ?? 0) - 20
        let maxElev = (elevations.max() ?? 100) + 20
        let lineColor = Color(hex: colorHex)

        return Chart(points) { point in
            AreaMark(
                x: .value("Distance", point.distanceKm),
                yStart: .value("Base", minElev),
                yEnd: .value("Elevation", point.elevationM)
            )
            .foregroundStyle(lineColor.opacity(0.3))

            LineMark(
                x: .value("Distance", point.distanceKm),
                y: .value("Elevation", point.elevationM)
            )
            .foregroundStyle(lineColor)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: minElev ... maxElev)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    // MARK: - Formatters

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
