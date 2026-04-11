//
//  MapStylePicker.swift
//  RouteKeeper
//
//  Floating three-button style switcher overlaid on the map view.
//  Matches the visual weight of RouteStatsOverlay: regular material
//  background, the same corner radius and shadow.
//

import SwiftUI

// MARK: - MapStylePicker

/// A compact overlay that lets the user switch between the three available
/// MapTiler styles: Streets, Satellite, and Topographic.
///
/// Positioned in the top-left of the map view. Bind `currentStyle` to
/// `MapViewModel.currentMapStyle`.
struct MapStylePicker: View {

    @Binding var currentStyle: String

    private struct StyleOption {
        let label: String
        let styleName: String
    }

    private let options: [StyleOption] = [
        StyleOption(label: "Streets",   styleName: "streets-v4"),
        StyleOption(label: "Satellite", styleName: "hybrid-v4"),
        StyleOption(label: "Topo",      styleName: "topo-v4"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.styleName) { option in
                Button {
                    currentStyle = option.styleName
                } label: {
                    Text(option.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            currentStyle == option.styleName
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .foregroundStyle(
                            currentStyle == option.styleName
                                ? Color.primary
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

#Preview {
    @Previewable @State var style = "streets-v4"
    MapStylePicker(currentStyle: $style)
        .padding()
}
