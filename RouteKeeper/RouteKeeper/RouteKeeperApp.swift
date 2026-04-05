//
//  RouteKeeperApp.swift
//  RouteKeeper
//

import SwiftUI

// MARK: - Focused value key

private struct ShowNewFolderSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Binding to the sidebar's `showingNewFolderSheet` state.
    var showNewFolderSheet: Binding<Bool>? {
        get { self[ShowNewFolderSheetKey.self] }
        set { self[ShowNewFolderSheetKey.self] = newValue }
    }
}

// MARK: - Commands

struct RouteKeeperCommands: Commands {
    @FocusedValue(\.showNewFolderSheet) private var showNewFolderSheet: Binding<Bool>?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") {
                showNewFolderSheet?.wrappedValue = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(showNewFolderSheet == nil)
        }
    }
}

// MARK: - App

@main
struct RouteKeeperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 750)
        .commands {
            RouteKeeperCommands()
        }
    }
}
