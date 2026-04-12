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

private struct ShowNewWaypointSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowNewRouteSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowRoutingProfilesSheetKey: FocusedValueKey {
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

    /// Binding to the sidebar's `showingNewWaypointSheet` state.
    var showNewWaypointSheet: Binding<Bool>? {
        get { self[ShowNewWaypointSheetKey.self] }
        set { self[ShowNewWaypointSheetKey.self] = newValue }
    }

    /// Binding to the sidebar's `showingNewRouteSheet` state.
    var showNewRouteSheet: Binding<Bool>? {
        get { self[ShowNewRouteSheetKey.self] }
        set { self[ShowNewRouteSheetKey.self] = newValue }
    }

    /// Binding to `ContentView`'s `showingRoutingProfilesSheet` state.
    var showRoutingProfilesSheet: Binding<Bool>? {
        get { self[ShowRoutingProfilesSheetKey.self] }
        set { self[ShowRoutingProfilesSheetKey.self] = newValue }
    }
}

// MARK: - Commands

struct RouteKeeperCommands: Commands {
    @FocusedValue(\.showNewListSheet)          private var showNewListSheet:          Binding<Bool>?
    @FocusedValue(\.showNewFolderSheet)        private var showNewFolderSheet:        Binding<Bool>?
    @FocusedValue(\.showNewWaypointSheet)      private var showNewWaypointSheet:      Binding<Bool>?
    @FocusedValue(\.showNewRouteSheet)         private var showNewRouteSheet:         Binding<Bool>?
    @FocusedValue(\.showRoutingProfilesSheet)  private var showRoutingProfilesSheet:  Binding<Bool>?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Route") {
                showNewRouteSheet?.wrappedValue = true
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(showNewRouteSheet == nil)

            Button("New Waypoint") {
                showNewWaypointSheet?.wrappedValue = true
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(showNewWaypointSheet == nil)

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

            Divider()

            Button("Route Profiles…") {
                showRoutingProfilesSheet?.wrappedValue = true
            }
            .disabled(showRoutingProfilesSheet == nil)
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
        // TODO: [REFACTOR] Hardcoded window size — extract to a named constant or configuration
        .defaultSize(width: 1200, height: 750)
        .commands {
            RouteKeeperCommands()
        }

        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                ExportSettingsView()
                    .tabItem {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
            }
            .frame(width: 400)
        }
    }
}
