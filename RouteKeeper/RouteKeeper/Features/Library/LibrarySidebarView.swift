//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  The root of the sidebar is a List with .listStyle(.sidebar) — macOS
//  applies the title-bar safe-area inset automatically for this pattern.
//  The items panel is attached as a .safeAreaInset(edge: .bottom) so the
//  List scrolls above it.  A draggable divider lets the user resize the
//  two panels.
//
//  The sort control and new-item buttons live in a control strip that is
//  the first row of the List (no .tag, so it is not selectable).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag identifier

private extension UTType {
    /// Internal type used to transfer library items within RouteKeeper.
    ///
    /// Uses `importedAs` rather than `exportedAs` so that no Info.plist
    /// declaration is required — this type is private to the app and is
    /// never exported to the system UTType registry.
    static let routeKeeperItem = UTType(exportedAs: "com.routekeeper.libraryitem")
}

// MARK: - Drag payload

/// Data transferred when a library item is dragged between lists.
private struct DraggableItem: Codable, Transferable {
    /// The `items.id` of the dragged item.
    let itemId: Int64
    /// The `lists.id` the item was dragged from; −1 means Unclassified.
    let sourceListId: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .routeKeeperItem)
    }
}

// MARK: - Drop delegate

/// Handles drops onto a list row in the library tree.
///
/// - Valid targets: real lists only (id ≠ −1).
/// - Dropping onto Unclassified or a folder is rejected via `validateDrop`.
/// - Badge behaviour: returns `.copy` (shows +) by default; returns `.move`
///   (no badge) when the Command key is held during the drag.
private struct ListDropDelegate: DropDelegate {
    let targetList: RouteList
    let viewModel: LibraryViewModel

    func validateDrop(info: DropInfo) -> Bool {
        targetList.id != -1
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard targetList.id != -1 else { return DropProposal(operation: .forbidden) }
        let commandDown = NSEvent.modifierFlags.contains(.command)
        return DropProposal(operation: commandDown ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard targetList.id != -1 else { return false }
        let commandDown = NSEvent.modifierFlags.contains(.command)
        let providers = info.itemProviders(for: [.routeKeeperItem])
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.routeKeeperItem.identifier
        ) { data, _ in
            guard let data,
                  let dragged = try? JSONDecoder().decode(DraggableItem.self, from: data)
            else { return }

            Task { @MainActor in
                if dragged.sourceListId == -1 {
                    // From Unclassified — always a move: insert membership only
                    // (there is no source membership row to delete).
                    await viewModel.copyItem(itemId: dragged.itemId, toList: targetList)
                } else if commandDown {
                    // Command held — move: delete source membership, insert target.
                    await viewModel.moveItem(
                        itemId: dragged.itemId,
                        fromListId: dragged.sourceListId,
                        toList: targetList
                    )
                } else {
                    // No modifier — copy: insert target membership, source unchanged.
                    await viewModel.copyItem(itemId: dragged.itemId, toList: targetList)
                }
            }
        }
        return true
    }
}

private struct RouteIdentity: Identifiable {
    let id: Int64
    let name: String
}

private struct WaypointIdentity: Identifiable {
    let id: Int64
    let name: String
}

/// Carries the state needed to open a new-item creation sheet.
///
/// Using this as the `.sheet(item:)` identity guarantees the preselected list ID
/// is baked into the presentation object before SwiftUI evaluates the sheet content,
/// avoiding the timing ambiguity of the `.sheet(isPresented:)` + separate-state-var pattern.
private struct NewItemPresentation: Identifiable {
    /// Unique per-presentation so re-opening the sheet always creates a fresh view.
    let id = UUID()
    /// The list to pre-tick in the sheet's list-assignment section, or `nil` for none.
    let preselectedListID: Int64?
}

struct LibrarySidebarView: View {
    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?
    @Binding var selectedItem: Item?

    // Sort preference — persisted across launches.
    @AppStorage("library.sortColumn")        private var sortColumn: String    = "name"
    @AppStorage("library.sortAscending")     private var sortAscending: Bool   = true

    // Height of the bottom (items) panel in points — persisted.
    @AppStorage("library.bottomPanelHeight") private var bottomPanelHeight: Double = 200

    // Drag state — not persisted; initialised from bottomPanelHeight on appear.
    @State private var isDragging      = false
    @State private var dragStartHeight: CGFloat = 200

    @State private var showingNewFolderSheet   = false
    @State private var showingNewListSheet     = false
    @State private var newListPreselectedFolderID: Int64?

    @State private var newWaypointPresentation: NewItemPresentation? = nil
    @State private var newRoutePresentation:    NewItemPresentation? = nil

    @State private var routePropertiesTarget: RouteIdentity? = nil
    @State private var routeWaypointTarget:   RouteIdentity? = nil
    @State private var waypointEditTarget:    WaypointIdentity? = nil

    // Export state
    @State private var showingExportSheet       = false
    @State private var exportItemIds: [Int64]   = []
    @State private var exportFilename: String   = ""
    @State private var showExportError          = false
    @State private var exportErrorMessage       = ""

    // Delete / removal confirmation state
    @State private var showRemoveItemConfirm    = false
    @State private var itemScheduledForRemoval: Item?      = nil   // last membership → Unclassified
    @State private var showDeleteItemConfirm    = false
    @State private var itemScheduledForDeletion: Item?     = nil   // permanent delete

    @State private var showNotEmptyAlert        = false
    @State private var notEmptyAlertTitle       = ""
    @State private var notEmptyAlertMessage     = ""
    @State private var showDeleteListConfirm    = false
    @State private var listScheduledForDeletion: RouteList?    = nil
    @State private var showDeleteFolderConfirm  = false
    @State private var folderScheduledForDeletion: ListFolder? = nil

    private let dividerHeight:  CGFloat = 8
    private let minPanelHeight: CGFloat = 80
    private let maxPanelHeight: CGFloat = 600

    var body: some View {
        List(selection: $selectedList) {
            // ── Control strip ──────────────────────────────────────────
            // No .tag() → not selectable; transparent background so it
            // reads as a toolbar strip rather than a list row.
            controlStrip
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // ── Folder / list hierarchy ────────────────────────────────
            ForEach(viewModel.folderContents, id: \.folder.id) { folder, lists in
                // Visually separate the Unclassified system folder from user content.
                if folder.id == -1 {
                    Divider()
                }
                DisclosureGroup(isExpanded: expansionBinding(for: folder)) {
                    ForEach(lists) { list in
                        Label {
                            Text(list.name)
                        } icon: {
                            if list.id == -1 {
                                Image(systemName: "map")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "map")
                            }
                        }
                            .tag(list)
                            .contextMenu {
                                Button {
                                    newRoutePresentation = NewItemPresentation(
                                        preselectedListID: list.id
                                    )
                                } label: {
                                    Label("New Route", systemImage: "road.lanes")
                                }
                                Button {
                                    newWaypointPresentation = NewItemPresentation(
                                        preselectedListID: list.id
                                    )
                                } label: {
                                    Label("New Waypoint", systemImage: "mappin.and.ellipse")
                                }
                                if list.id != -1 {
                                    Divider()
                                    Button("Export GPX…") {
                                        Task {
                                            guard let listId = list.id else { return }
                                            let count = (try? await DatabaseManager.shared
                                                .fetchListItemCount(listId: listId)) ?? 0
                                            if count == 0 {
                                                notEmptyAlertTitle   = "Nothing to Export"
                                                notEmptyAlertMessage = "\(list.name) " +
                                                    "contains no items to export."
                                                showNotEmptyAlert = true
                                            } else {
                                                let ids = (try? await DatabaseManager.shared
                                                    .fetchItemIdsForList(listId: listId)) ?? []
                                                exportItemIds = ids
                                                exportFilename = list.name
                                                showingExportSheet = true
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Delete List…", role: .destructive) {
                                        Task {
                                            guard let listId = list.id else { return }
                                            let count = (try? await DatabaseManager.shared.fetchListItemCount(listId: listId)) ?? 0
                                            if count > 0 {
                                                notEmptyAlertTitle   = "Cannot Delete List"
                                                notEmptyAlertMessage = "\(list.name) " +
                                                "cannot be deleted because it contains " + "items. Remove all items from the " +
                                                    "list before deleting it."
                                                
                                                showNotEmptyAlert = true
                                            } else {
                                                listScheduledForDeletion = list
                                                showDeleteListConfirm = true
                                            }
                                        }
                                    }
                                }
                            }
                            .onDrop(
                                of: [.routeKeeperItem],
                                delegate: ListDropDelegate(
                                    targetList: list,
                                    viewModel: viewModel
                                )
                            )
                    }
                } label: {
                    Label {
                        Text(folder.name)
                    } icon: {
                        if folder.id == -1 {
                            Image(systemName: "tray.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "folder.fill")
                        }
                    }
                    .fontWeight(.bold)
                    .contextMenu {
                        if folder.id != -1 {
                            Button {
                                newListPreselectedFolderID = folder.id
                                showingNewListSheet = true
                            } label: {
                                Label("New List", systemImage: "list.bullet.rectangle.portrait")
                            }
                            Button {
                                newWaypointPresentation = NewItemPresentation(
                                    preselectedListID: lists.first?.id
                                )
                            } label: {
                                Label("New Waypoint", systemImage: "mappin.and.ellipse")
                            }
                            Button {
                                newRoutePresentation = NewItemPresentation(
                                    preselectedListID: lists.first?.id
                                )
                            } label: {
                                Label("New Route", systemImage: "road.lanes")
                            }
                            Divider()
                            Button("Export GPX…") {
                                Task {
                                    guard let folderId = folder.id else { return }
                                    let hasItems = (try? await DatabaseManager.shared
                                        .folderHasItems(folderId: folderId)) ?? false
                                    if !hasItems {
                                        notEmptyAlertTitle   = "Nothing to Export"
                                        notEmptyAlertMessage = "\(folder.name) " +
                                            "contains no items to export."
                                        showNotEmptyAlert = true
                                    } else {
                                        let ids = (try? await DatabaseManager.shared
                                            .fetchItemIdsForFolder(folderId: folderId)) ?? []
                                        exportItemIds = ids
                                        exportFilename = folder.name
                                        showingExportSheet = true
                                    }
                                }
                            }
                            Divider()
                            Button("Delete Folder…", role: .destructive) {
                                Task {
                                    guard let folderId = folder.id else { return }
                                    let hasItems = (try? await DatabaseManager.shared.folderHasItems(folderId: folderId)) ?? false
                                    if hasItems {
                                        notEmptyAlertTitle   = "Cannot Delete Folder"
                                        notEmptyAlertMessage = "\(folder.name) " +
                                            "cannot be deleted because " +
                                            "one or more of its lists contain items. " +
                                            "Remove all items from the lists before " +
                                            "deleting the folder."
                                        showNotEmptyAlert = true
                                    } else {
                                        folderScheduledForDeletion = folder
                                        showDeleteFolderConfirm = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button {
                showingNewFolderSheet = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        }
        // Items panel pinned to the bottom; the List adjusts its own
        // scroll-content inset automatically to stay above this area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Draggable divider — dragging up enlarges the items panel.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: dividerHeight)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartHeight = CGFloat(bottomPanelHeight)
                                }
                                // Negative translation (drag up) → panel grows.
                                let proposed = dragStartHeight - value.translation.height
                                bottomPanelHeight = Double(
                                    min(max(proposed, minPanelHeight), maxPanelHeight)
                                )
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .cursor(.resizeUpDown)

                bottomPanel
                    .frame(height: CGFloat(bottomPanelHeight))
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showingNewFolderSheet) {
            NewFolderSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingNewListSheet) {
            NewListSheet(viewModel: viewModel, preselectedFolderID: newListPreselectedFolderID)
        }
        .sheet(item: $newWaypointPresentation) { presentation in
            NewWaypointSheet(
                viewModel: viewModel,
                preselectedListID: presentation.preselectedListID
            )
        }
        .sheet(item: $newRoutePresentation) { presentation in
            NewRouteSheet(
                viewModel: viewModel,
                preselectedListID: presentation.preselectedListID
            )
        }
        .sheet(item: $routePropertiesTarget) { identity in
            RoutePropertiesSheet(
                routeItemId: identity.id,
                initialName: identity.name,
                onSave: {
                    Task { await viewModel.reload() }
                    // Cycle selectedItem so ContentView's .task(id:) re-fires and
                    // redraws the updated geometry if this route is currently shown.
                    guard let current = selectedItem,
                          current.id == identity.id else { return }
                    let snapshot = current
                    selectedItem = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        selectedItem = snapshot
                    }
                }
            )
        }
        .sheet(item: $routeWaypointTarget) { identity in
            RouteWaypointSheet(
                routeItemId: identity.id,
                routeName: identity.name
            ) {
                // If the edited route is the currently selected item, cycle
                // selectedItem through nil so ContentView's .task(id:) re-fires
                // and redraws the updated geometry on the map.
                guard let current = selectedItem, current.id == identity.id else { return }
                let snapshot = current
                selectedItem = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    selectedItem = snapshot
                }
            }
        }
        .sheet(item: $waypointEditTarget) { identity in
            EditWaypointSheet(
                viewModel: viewModel,
                waypointItemId: identity.id
            ) {
                Task { await viewModel.reload() }
                // Cycle selectedItem so ContentView re-fires its .task(id:)
                // and refreshes the map marker with the updated coordinates.
                guard let current = selectedItem, current.id == identity.id else { return }
                let snapshot = current
                selectedItem = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    selectedItem = snapshot
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportFormatSheet(defaultFilename: exportFilename) { format in
                Task { @MainActor in
                    await performExport(
                        itemIds: exportItemIds,
                        format: format,
                        filename: exportFilename
                    )
                }
            }
        }
        .focusedValue(\.showNewFolderSheet,   $showingNewFolderSheet)
        .focusedValue(\.showNewListSheet,     $showingNewListSheet)
        .focusedValue(\.showNewWaypointSheet, Binding(
            get: { newWaypointPresentation != nil },
            set: { show in
                if show {
                    newWaypointPresentation = NewItemPresentation(
                        preselectedListID: selectedList?.id
                    )
                } else {
                    newWaypointPresentation = nil
                }
            }
        ))
        .focusedValue(\.showNewRouteSheet, Binding(
            get: { newRoutePresentation != nil },
            set: { show in
                if show {
                    newRoutePresentation = NewItemPresentation(
                        preselectedListID: selectedList?.id
                    )
                } else {
                    newRoutePresentation = nil
                }
            }
        ))
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .onChange(of: selectedList) { _, newList in
            selectedItem = nil
            Task {
                if let list = newList {
                    await viewModel.loadItems(for: list)
                } else {
                    viewModel.clearItems()
                }
            }
        }
        .onChange(of: sortColumn)    { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        .onChange(of: sortAscending) { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        .onAppear {
            dragStartHeight = CGFloat(bottomPanelHeight)
            if let list = selectedList {
                Task { await viewModel.loadItems(for: list) }
            }
        }
        // "Remove from this list" confirmation — item's last membership; moves to Unclassified.
        .confirmationDialog(
            "Remove from this list?",
            isPresented: $showRemoveItemConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let item = itemScheduledForRemoval,
                      let itemId = item.id,
                      let listId = viewModel.currentList?.id
                else { return }
                if selectedItem?.id == itemId { selectedItem = nil }
                Task { await viewModel.removeItemFromList(itemId: itemId, listId: listId) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let item = itemScheduledForRemoval {
                Text("\(item.name) Item will be removed from this list " +
                     "and moved to Unclassified.")
            }
        }
        // "Delete item" confirmation — permanent deletion.
        .confirmationDialog(
            "Delete item?",
            isPresented: $showDeleteItemConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = itemScheduledForDeletion, let itemId = item.id else { return }
                if selectedItem?.id == itemId { selectedItem = nil }
                Task { await viewModel.deleteItem(itemId: itemId) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let item = itemScheduledForDeletion {
                Text("\(item.name) will be permanently deleted and cannot be recovered.")
            }
        }
        // "List / folder not empty" informational alert.
        .alert(notEmptyAlertTitle, isPresented: $showNotEmptyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(notEmptyAlertMessage)
        }
        // "Delete list" confirmation.
        .confirmationDialog(
            "Delete list?",
            isPresented: $showDeleteListConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let list = listScheduledForDeletion else { return }
                if selectedList?.id == list.id {
                    selectedList = nil
                    selectedItem = nil
                }
                Task { await viewModel.deleteList(list) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let list = listScheduledForDeletion {
                Text("\(list.name) will be permanently deleted.")
            }
        }
        // "Delete folder" confirmation.
        .confirmationDialog(
            "Delete folder?",
            isPresented: $showDeleteFolderConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let folder = folderScheduledForDeletion else { return }
                if let selectedFolderId = selectedList?.folderId, selectedFolderId == folder.id {
                    selectedList = nil
                    selectedItem = nil
                }
                Task { await viewModel.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let folder = folderScheduledForDeletion {
                Text("\(folder.name) and all its lists will be permanently deleted.")
            }
        }
        // Export failure alert.
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage)
        }
    }

    // MARK: - Control strip

    /// Sort menu on the left; new-item buttons on the right.
    /// Placed as the first List row with no .tag so it is never selectable.
    private var controlStrip: some View {
        HStack(spacing: 16) {
            // Sort menu
            Menu {
                Picker("Sort by", selection: $sortColumn) {
                    Text("Name").tag("name")
                    Text("Date Created").tag("created_at")
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(isOn: $sortAscending) {
                    Label(
                        "Ascending",
                        systemImage: sortAscending ? "chevron.up" : "chevron.down"
                    )
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.up.chevron.down")
                    Text(sortColumn == "name" ? "Name" : "Date Created")
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 16))
            .help("Sort library")

            Spacer()

            // New Folder (outermost container — leftmost)
            Button {
                showingNewFolderSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New folder")

            // New List
            Button {
                newListPreselectedFolderID = nil
                showingNewListSheet = true
            } label: {
                Image(systemName: "rectangle.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New list")

            // New Waypoint
            Button {
                newWaypointPresentation = NewItemPresentation(
                    preselectedListID: selectedList?.id
                )
            } label: {
                Image(systemName: "mappin.and.ellipse")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New waypoint")

            // New Route (leaf item — rightmost)
            Button {
                newRoutePresentation = NewItemPresentation(
                    preselectedListID: selectedList?.id
                )
            } label: {
                Image(systemName: "road.lanes")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New route")
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        Group {
            if selectedList != nil {
                List(selection: $selectedItem) {
                    ForEach(viewModel.listItems) { item in
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(systemName: item.type == .waypoint
                                ? (item.categoryIcon ?? item.type.systemImage)
                                : item.type.systemImage)
                                .foregroundStyle(iconColor(for: item))
                        }
                        .tag(item)
                        .draggable(DraggableItem(
                            itemId: item.id ?? 0,
                            sourceListId: selectedList?.id ?? -1
                        ))
                        .contextMenu {
                            itemContextMenu(for: item)
                        }
                        .overlay(
                            DoubleClickHandler {
                                guard let itemId = item.id else { return }
                                selectedItem = item
                                if item.type == .route {
                                    routePropertiesTarget = RouteIdentity(
                                        id: itemId, name: item.name
                                    )
                                } else if item.type == .waypoint {
                                    waypointEditTarget = WaypointIdentity(
                                        id: itemId, name: item.name
                                    )
                                }
                            }
                        )
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if viewModel.listItems.isEmpty {
                        Text("No items in this list")
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Select a list")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Helpers

    /// Builds the "Move to…" / "Copy to…" context menu for an item row.
    ///
    /// - From Unclassified: only "Move to…" is shown; the action inserts a
    ///   membership row (there is no source row to delete).
    /// - From a real list: both submenus are shown; "Move to…" deletes the
    ///   source membership and "Copy to…" leaves it in place.
    /// - Lists the item already belongs to are shown disabled in both submenus.
    @ViewBuilder
    private func itemContextMenu(for item: Item) -> some View {
        let currentListId  = selectedList?.id ?? -1
        let isUnclassified = currentListId == -1
        let itemId         = item.id ?? -1
        let alreadyIn      = viewModel.itemMemberships[itemId] ?? []

        // Real folders only — Unclassified sentinel (id == -1) is not a
        // valid drop target and is excluded from both submenus.
        let realFolders = viewModel.folderContents.filter { $0.folder.id != -1 }

        // "Edit Route" actions — routes only.
        if item.type == .route {
            Button("Edit Route…") {
                routePropertiesTarget = RouteIdentity(id: itemId, name: item.name)
            }
            Button("Edit Route Waypoints…") {
                routeWaypointTarget = RouteIdentity(id: itemId, name: item.name)
            }
            Divider()
        } else if item.type == .waypoint {
            Button("Edit Waypoint…") {
                waypointEditTarget = WaypointIdentity(id: itemId, name: item.name)
            }
            Divider()
        }

        // "Move to…" — always present.
        Menu("Move to…") {
            ForEach(realFolders, id: \.folder.id) { folder, lists in
                let targets = lists.filter { ($0.id ?? -1) != currentListId }
                if !targets.isEmpty {
                    Section(folder.name) {
                        ForEach(targets) { list in
                            Button(list.name) {
                                Task {
                                    if isUnclassified {
                                        // Unclassified has no membership row to remove.
                                        await viewModel.copyItem(itemId: itemId, toList: list)
                                    } else {
                                        await viewModel.moveItem(
                                            itemId: itemId,
                                            fromListId: currentListId,
                                            toList: list
                                        )
                                    }
                                }
                            }
                            .disabled(alreadyIn.contains(list.id ?? -1))
                        }
                    }
                }
            }
        }

        // "Copy to…" — suppressed when viewing Unclassified.
        if !isUnclassified {
            Menu("Copy to…") {
                ForEach(realFolders, id: \.folder.id) { folder, lists in
                    let targets = lists.filter { ($0.id ?? -1) != currentListId }
                    if !targets.isEmpty {
                        Section(folder.name) {
                            ForEach(targets) { list in
                                Button(list.name) {
                                    Task {
                                        await viewModel.copyItem(itemId: itemId, toList: list)
                                    }
                                }
                                .disabled(alreadyIn.contains(list.id ?? -1))
                            }
                        }
                    }
                }
            }
        }

        // Export section.
        Divider()

        Button("Export GPX…") {
            guard item.id != nil else { return }
            exportItemIds = [itemId]
            exportFilename = item.name
            showingExportSheet = true
        }

        // Delete / remove section — separated from Move/Copy by a divider.
        Divider()

        if !isUnclassified {
            if alreadyIn.count <= 1 {
                // This is the item's only list membership — removing it sends the
                // item to Unclassified; a confirmation is required.
                Button("Remove from this list…") {
                    itemScheduledForRemoval = item
                    showRemoveItemConfirm = true
                }
            } else {
                // Item belongs to other lists — safe to remove from this one immediately.
                Button("Remove from this list") {
                    Task {
                        if selectedItem?.id == itemId { selectedItem = nil }
                        await viewModel.removeItemFromList(itemId: itemId, listId: currentListId)
                    }
                }
            }
        }

        Button("Delete…", role: .destructive) {
            itemScheduledForDeletion = item
            showDeleteItemConfirm = true
        }
    }

    /// Returns the colour to apply to `item`'s sidebar icon.
    ///
    /// Waypoints carry a `colour` hex string populated from `waypoints.color_hex`
    /// by the fetch query.  Routes and tracks have no colour yet, so they fall
    /// back to `.secondary`.
    private func iconColor(for item: Item) -> Color {
        if let hex = item.colour, !hex.isEmpty {
            return Color(itemHex: hex)
        }
        return .secondary
    }

    // MARK: - GPX export

    /// Presents a NSSavePanel then fetches items, generates GPX, and writes the file.
    @MainActor
    private func performExport(
        itemIds: [Int64],
        format: GPXFormat,
        filename: String
    ) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitizedFilename(filename) + ".gpx"
        panel.canCreateDirectories = true
        if let gpxType = UTType(filenameExtension: "gpx") {
            panel.allowedContentTypes = [gpxType]
        }

        // runModal() blocks with a nested AppKit event loop — standard macOS usage.
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let exportItems = try await DatabaseManager.shared.fetchItemsForExport(
                itemIds: itemIds
            )
            let gpxString = GPXExporter.exportGPX(items: exportItems, format: format)
            guard let data = gpxString.data(using: .utf8) else {
                exportErrorMessage = "The file couldn't be saved."
                showExportError = true
                return
            }
            try data.write(to: url)
        } catch {
            exportErrorMessage = "The file couldn't be saved. " +
                "Check that you have permission to write to the chosen location."
            showExportError = true
        }
    }

    /// Strips characters that are invalid in macOS filenames.
    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:?*\\\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    /// A `Binding<Bool>` for the expansion state of a folder row.
    private func expansionBinding(for folder: ListFolder) -> Binding<Bool> {
        Binding(
            get: {
                guard let id = folder.id else { return true }
                return viewModel.expandedFolderIDs.contains(id)
            },
            set: { isExpanded in
                guard let id = folder.id else { return }
                if isExpanded {
                    viewModel.expandedFolderIDs.insert(id)
                } else {
                    viewModel.expandedFolderIDs.remove(id)
                }
            }
        )
    }
}

// MARK: - Double-click handler

/// An invisible `NSView` background that intercepts AppKit double-click events
/// and fires a closure, leaving SwiftUI's own gesture recogniser stack (and
/// therefore list-row selection) completely undisturbed.
private struct DoubleClickHandler: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickableNSView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickableNSView)?.onDoubleClick = onDoubleClick
    }

    private class ClickableNSView: NSView {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            }
            // Always pass the event up so single-click selection still works.
            super.mouseDown(with: event)
        }
    }
}

// MARK: - Color from hex string

private extension Color {
    /// Initialises a `Color` from a CSS hex string such as `"#E8453C"`.
    init(itemHex hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(clean, radix: 16) ?? 0x888888
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double(value         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Resize cursor

private extension View {
    /// Pushes a vertical-resize cursor while the pointer is over this view.
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

#Preview {
    NavigationSplitView {
        LibrarySidebarView(
            viewModel: LibraryViewModel(),
            selectedList: .constant(nil),
            selectedItem: .constant(nil)
        )
    } detail: {
        Text("Select a list to view its contents")
            .foregroundStyle(.secondary)
    }
    .frame(width: 1000, height: 600)
}
