//
//  ContentView.swift
//  RouteKeeper
//
//  Root view: two-column NavigationSplitView with library sidebar
//  and a main content area.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedList: RouteList?

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                folders: ListFolder.placeholders,
                selectedList: $selectedList
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let list = selectedList {
                Text("\"\(list.name)\" contents go here")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a list to view its contents")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
