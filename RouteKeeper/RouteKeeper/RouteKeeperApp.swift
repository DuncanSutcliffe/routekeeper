//
//  RouteKeeperApp.swift
//  RouteKeeper
//

import SwiftUI

// MARK: - Focused value keys

private struct ShowNewFolderSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowNewListSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Binding to the sidebar's `showingNewFolderSheet` state.
    var showNewFolderSheet: Binding<Bool>? {
        get { self[ShowNewFolderSheetKey.self] }
        set { self[ShowNewFolderSheetKey.self] = newValue }
    }

    /// Binding to the sidebar's `showingNewListSheet` state.
    var showNewListSheet: Binding<Bool>? {
        get { self[ShowNewListSheetKey.self] }
        set { self[ShowNewListSheetKey.self] = newValue }
    }
}

// MARK: - Commands

struct RouteKeeperCommands: Commands {
    @FocusedValue(\.showNewListSheet)   private var showNewListSheet:   Binding<Bool>?
    @FocusedValue(\.showNewFolderSheet) private var showNewFolderSheet: Binding<Bool>?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New List") {
                showNewListSheet?.wrappedValue = true
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(showNewListSheet == nil)

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
