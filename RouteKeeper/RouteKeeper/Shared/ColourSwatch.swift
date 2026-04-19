//
//  ColourSwatch.swift
//  RouteKeeper
//
//  Shared colour-swatch button and hex-colour helper used in waypoint
//  and route creation / editing sheets.
//

import SwiftUI

// MARK: - Preset colour palettes

/// Preset colours shown in waypoint creation and editing sheets.
let waypointPresetColours: [String] = [
    "#E8453C", "#E8873C", "#E8D83C", "#4CAF50",
    "#1A73E8", "#9C27B0", "#795548", "#607D8B",
]

/// Preset colours shown in route creation and editing sheets.
let routePresetColours: [String] = [
    "#E8453C", "#E8873C", "#E8D83C", "#4CAF50",
    "#1A73E8", "#9C27B0", "#795548", "#607D8B",
]

// MARK: - ColourSwatch

/// A tappable filled circle indicating a selectable colour.
///
/// When `isSelected` is true a white inner ring and dark outer ring are
/// drawn over the fill to make the active selection clearly visible.
struct ColourSwatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 24, height: 24)
                if isSelected {
                    Circle()
                        .strokeBorder(.white, lineWidth: 2.5)
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(.black.opacity(0.25), lineWidth: 3.5)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
        .help(hex)
    }
}

// MARK: - Color+hex

extension Color {
    /// Initialises a `Color` from a CSS hex string such as `"#E8453C"`.
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(clean, radix: 16) ?? 0xFF0000
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double(value         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
