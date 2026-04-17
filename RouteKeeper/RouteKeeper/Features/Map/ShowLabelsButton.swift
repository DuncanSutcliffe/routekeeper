//
//  ShowLabelsButton.swift
//  RouteKeeper
//
//  Floating toggle control that shows or hides map labels when a list
//  is displayed. Styled to match MapStylePicker and RouteStatsOverlay.
//

import SwiftUI

struct ShowLabelsButton: View {
    @Binding var showLabels: Bool

    var body: some View {
        Toggle("Labels", isOn: $showLabels)
            .toggleStyle(.switch)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            .help("Show labels on map")
    }
}

#Preview {
    @Previewable @State var show = true
    ShowLabelsButton(showLabels: $show)
        .padding()
}
