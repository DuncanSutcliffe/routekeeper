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
    @State private var libraryViewModel = LibraryViewModel()

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                viewModel: libraryViewModel,
                selectedList: $selectedList
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selectedList != nil {
                MapView()
            } else {
                Text("Select a list to view its contents")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            do {
                try await DatabaseManager.shared.setUp()
            } catch {
                // setUp() failing is fatal in practice; surface properly in a future increment.
                print("Database setup failed: \(error)")
            }
            await libraryViewModel.load()
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 600)
}
