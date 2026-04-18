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

private struct MapViewModelKey: FocusedValueKey {
    typealias Value = MapViewModel
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

    /// The `MapViewModel` instance owned by `ContentView`, used to inspect the undo stack.
    var mapViewModel: MapViewModel? {
        get { self[MapViewModelKey.self] }
        set { self[MapViewModelKey.self] = newValue }
    }
}

// MARK: - Commands

struct RouteKeeperCommands: Commands {
    @FocusedValue(\.showNewListSheet)          private var showNewListSheet:          Binding<Bool>?
    @FocusedValue(\.showNewFolderSheet)        private var showNewFolderSheet:        Binding<Bool>?
    @FocusedValue(\.showNewWaypointSheet)      private var showNewWaypointSheet:      Binding<Bool>?
    @FocusedValue(\.showNewRouteSheet)         private var showNewRouteSheet:         Binding<Bool>?
    @FocusedValue(\.showRoutingProfilesSheet)  private var showRoutingProfilesSheet:  Binding<Bool>?
    @FocusedValue(\.mapViewModel)              private var mapViewModel:              MapViewModel?
    @Environment(\.openWindow)                 private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                NotificationCenter.default.post(name: .routeKeeperPerformUndo, object: nil)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(mapViewModel?.undoStack.isEmpty ?? true)
        }

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
        }

        CommandMenu("Manage") {
            Button("Categories…") {
                openWindow(id: "category-management")
            }
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
    @State private var apiKeysManager = APIKeysManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 750)
        .environment(apiKeysManager)
        .commands {
            RouteKeeperCommands()
        }

        Window("Categories", id: "category-management") {
            CategoryManagementView()
        }
        .defaultSize(width: 420, height: 520)

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
                APIKeysSettingsView()
                    .tabItem {
                        Label("API Keys", systemImage: "key")
                    }
                    .environment(apiKeysManager)
            }
            .frame(minWidth: 480)
        }
    }
}
