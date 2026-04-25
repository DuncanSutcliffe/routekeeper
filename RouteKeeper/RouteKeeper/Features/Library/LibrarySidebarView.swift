//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  The root of the sidebar is a List with .listStyle(.sidebar) — macOS
//  applies the title-bar safe-area inset automatically for this pattern.
//  The items panel is attached via LibraryBottomPanel as a .safeAreaInset(edge: .bottom).
//
//  Shared types used across the Library feature files are defined here
//  as internal (no access modifier) so ListRowView, FolderLabelView, and
//  LibraryBottomPanel can all reference them without re-declaration.
//
//  body is kept intentionally short.  The modal presentation modifiers
//  (sheets, confirmation dialogs, alerts) are evaluated by the type-checker
//  in isolation inside LibrarySidebarModals: ViewModifier so that body
//  itself is never a type-checker bottleneck.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag types

extension UTType {
    /// Internal type for transferring library items between lists.
    static let routeKeeperItem     = UTType(exportedAs: "com.routekeeper.libraryitem")
    /// Internal type for transferring lists between folders.
    static let routeKeeperListItem = UTType(exportedAs: "com.routekeeper.listitem")
}

/// Data transferred when a library item is dragged between lists.
struct DraggableItem: Codable, Transferable {
    let itemIds: [Int64]
    let sourceListId: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .routeKeeperItem)
    }
}

/// Data transferred when a list is dragged to a different folder.
struct DraggableList: Codable, Transferable {
    let listId: Int64
    let sourceFolderId: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .routeKeeperListItem)
    }
}

// MARK: - Item drop delegate

/// Handles drops of library items onto a list row.
struct ListDropDelegate: DropDelegate {
    let targetList: RouteList
    let viewModel: LibraryViewModel

    func validateDrop(info: DropInfo) -> Bool { targetList.id != -1 }

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
                for itemId in dragged.itemIds {
                    if dragged.sourceListId == -1 {
                        await viewModel.copyItem(itemId: itemId, toList: targetList)
                    } else if commandDown {
                        await viewModel.moveItem(
                            itemId: itemId,
                            fromListId: dragged.sourceListId,
                            toList: targetList
                        )
                    } else {
                        await viewModel.copyItem(itemId: itemId, toList: targetList)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Folder drop delegate

/// Handles drops of lists (dragged from other folders) onto a folder header row.
///
/// Uses the `DropDelegate` API rather than `.dropDestination(for:)` because
/// the newer Transferable API does not integrate reliably with macOS's
/// NSTableView-backed sidebar List. This mirrors the approach used by
/// `ListDropDelegate` for item-to-list drags.
struct FolderDropDelegate: DropDelegate {
    let targetFolder: ListFolder
    let viewModel: LibraryViewModel

    func validateDrop(info: DropInfo) -> Bool {
        guard let folderId = targetFolder.id, folderId != -1 else { return false }
        return info.hasItemsConforming(to: [.routeKeeperListItem])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let folderId = targetFolder.id, folderId != -1 else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let folderId = targetFolder.id, folderId != -1 else { return false }
        let providers = info.itemProviders(for: [.routeKeeperListItem])
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.routeKeeperListItem.identifier
        ) { data, _ in
            guard let data,
                  let dragged = try? JSONDecoder().decode(DraggableList.self, from: data)
            else { return }
            guard dragged.sourceFolderId != folderId else { return }
            Task { @MainActor in
                await viewModel.moveList(listId: dragged.listId, toFolderId: folderId)
            }
        }
        return true
    }
}

// MARK: - Identity helpers

struct RouteIdentity: Identifiable {
    let id: Int64
    let name: String
}

struct WaypointIdentity: Identifiable {
    let id: Int64
    let name: String
}

struct TrackIdentity: Identifiable {
    let id: Int64
    let name: String
}

/// Carries state for opening a new-item creation sheet.
struct NewItemPresentation: Identifiable {
    let id = UUID()
    let preselectedListID: Int64?
}

// MARK: - Double-click handler

/// An invisible `NSView` background that intercepts AppKit double-click events
/// and fires a closure, leaving SwiftUI's own gesture recogniser stack
/// (and therefore list-row selection) completely undisturbed.
struct DoubleClickHandler: NSViewRepresentable {
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
            if event.clickCount == 2 { onDoubleClick?() }
            // Always pass the event up so single-click selection still works.
            super.mouseDown(with: event)
        }
    }
}

// MARK: - Color from hex string

// TODO: [REFACTOR] Color(itemHex:) here is a duplicate of Color(hex:) in ColourSwatch.swift
// — identical algorithm, different initialiser label. Remove one and use the other everywhere.
extension Color {
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

extension View {
    /// Pushes a vertical-resize cursor while the pointer is over this view.
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Main view

struct LibrarySidebarView: View {
    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?
    @Binding var selectedItems: Set<Item>

    // Sort preference — persisted across launches.
    @AppStorage("library.sortColumn")    private var sortColumn:    String = "name"
    @AppStorage("library.sortAscending") private var sortAscending: Bool   = true

    /// Set to `true` immediately before clearing `selectedList` in response to
    /// item selection, so `onChange(of: selectedList)` knows not to call `clearItems()`.
    @State private var itemSelectionClearedList = false

    @State private var showingNewFolderSheet       = false
    @State private var showingNewListSheet         = false
    @State private var newListPreselectedFolderID: Int64?

    @State private var newWaypointPresentation: NewItemPresentation? = nil
    @State private var newRoutePresentation:    NewItemPresentation? = nil

    @State private var routePropertiesTarget:  RouteIdentity?    = nil
    @State private var routeWaypointTarget:    RouteIdentity?    = nil
    @State private var waypointEditTarget:     WaypointIdentity? = nil
    @State private var trackPropertiesTarget:  TrackIdentity?    = nil

    // GPX import state — shared with list context menu.
    @State private var showingImportGPXSheet       = false
    @State private var importGPXPreselectedListId: Int64? = nil

    // Export state — shared with bottom panel and list/folder context menus.
    @State private var showingExportSheet     = false
    @State private var exportItemIds: [Int64] = []
    @State private var exportFilename: String = ""
    @State private var showExportError        = false
    @State private var exportErrorMessage     = ""

    // Delete / removal confirmation state
    @State private var showRemoveItemConfirm              = false
    @State private var itemsScheduledForRemoval: [Item]   = []
    @State private var showDeleteItemConfirm              = false
    @State private var itemsScheduledForDeletion: [Item]  = []

    @State private var showNotEmptyAlert              = false
    @State private var notEmptyAlertTitle             = ""
    @State private var notEmptyAlertMessage           = ""
    @State private var showDeleteListConfirm          = false
    @State private var listScheduledForDeletion: RouteList?    = nil
    @State private var showDeleteFolderConfirm        = false
    @State private var folderScheduledForDeletion: ListFolder? = nil

    // Inline folder rename
    @State private var renamingFolderID: Int64?   = nil
    @State private var renamingFolderText: String = ""

    // List edit sheet
    @State private var editListTarget: RouteList? = nil

    // MARK: - Body

    /// body is intentionally minimal — all modal modifiers live in
    /// LibrarySidebarModals and are evaluated by the type-checker in isolation.
    var body: some View {
        coreView
            .modifier(modals)
            .sheet(isPresented: $showingImportGPXSheet) {
                GPXImportSheet(
                    viewModel: viewModel,
                    preselectedListId: importGPXPreselectedListId,
                    onImported: { list in
                        selectedList = list
                    }
                )
            }
    }

    // MARK: - Core view

    /// The list and all non-modal modifiers. Evaluated independently from the
    /// modal modifier chain so neither expression grows too large for the
    /// Swift type-checker.
    private var coreView: some View {
        List(selection: $selectedList) {
            controlStrip
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(viewModel.folderContents, id: \.folder.id) { folder, lists in
                folderRow(folder: folder, lists: lists)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryBottomPanel(
                viewModel: viewModel,
                selectedItems: $selectedItems,
                routePropertiesTarget: $routePropertiesTarget,
                routeWaypointTarget: $routeWaypointTarget,
                waypointEditTarget: $waypointEditTarget,
                trackPropertiesTarget: $trackPropertiesTarget,
                exportItemIds: $exportItemIds,
                exportFilename: $exportFilename,
                showingExportSheet: $showingExportSheet,
                showRemoveItemConfirm: $showRemoveItemConfirm,
                itemsScheduledForRemoval: $itemsScheduledForRemoval,
                showDeleteItemConfirm: $showDeleteItemConfirm,
                itemsScheduledForDeletion: $itemsScheduledForDeletion
            )
        }
        .navigationTitle("Library")
        .focusedValue(\.showNewFolderSheet, $showingNewFolderSheet)
        .focusedValue(\.showNewListSheet,   $showingNewListSheet)
        .focusedValue(\.showNewWaypointSheet, Binding(
            get: { newWaypointPresentation != nil },
            set: { show in
                newWaypointPresentation = show
                    ? NewItemPresentation(preselectedListID: viewModel.currentList?.id)
                    : nil
            }
        ))
        .focusedValue(\.showNewRouteSheet, Binding(
            get: { newRoutePresentation != nil },
            set: { show in
                newRoutePresentation = show
                    ? NewItemPresentation(preselectedListID: viewModel.currentList?.id)
                    : nil
            }
        ))
        .focusedValue(\.showImportGPXSheet, Binding(
            get: { showingImportGPXSheet },
            set: { show in
                if show { importGPXPreselectedListId = nil }
                showingImportGPXSheet = show
            }
        ))
        .focusedValue(\.libraryCanRemove,
            !selectedItems.isEmpty && (viewModel.currentList?.id ?? -1) != -1)
        .focusedValue(\.libraryCanDelete, !selectedItems.isEmpty)
        .overlay {
            if viewModel.isLoading { ProgressView() }
        }
        .modifier(sidebarHandlers)
    }

    private var sidebarHandlers: LibrarySidebarHandlers {
        LibrarySidebarHandlers(
            viewModel: viewModel,
            selectedList: $selectedList,
            selectedItems: $selectedItems,
            itemSelectionClearedList: $itemSelectionClearedList,
            sortColumn: $sortColumn,
            sortAscending: $sortAscending,
            itemsScheduledForRemoval: $itemsScheduledForRemoval,
            showRemoveItemConfirm: $showRemoveItemConfirm,
            itemsScheduledForDeletion: $itemsScheduledForDeletion,
            showDeleteItemConfirm: $showDeleteItemConfirm
        )
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 16) {
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

            Button { showingNewFolderSheet = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New folder")

            Button {
                newListPreselectedFolderID = nil
                showingNewListSheet = true
            } label: {
                Image(systemName: "rectangle.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New list")

            Button {
                newWaypointPresentation = NewItemPresentation(
                    preselectedListID: viewModel.currentList?.id
                )
            } label: {
                Image(systemName: "mappin.and.ellipse")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New waypoint")

            Button {
                newRoutePresentation = NewItemPresentation(
                    preselectedListID: viewModel.currentList?.id
                )
            } label: {
                Image(systemName: "road.lanes")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New route")
        }
    }

    // MARK: - Folder row builder

    /// Builds the sidebar row for one folder entry.
    ///
    /// Isolated into its own `@ViewBuilder` function so the Swift type-checker
    /// evaluates the branching and `DisclosureGroup` construction outside of
    /// the main `body` expression.
    @ViewBuilder
    private func folderRow(
        folder: ListFolder,
        lists: [RouteList]
    ) -> some View {
        if folder.id == -1 { Divider() }
        DisclosureGroup(isExpanded: expansionBinding(for: folder)) {
            ForEach(lists) { list in
                ListRowView(
                    list: list,
                    sourceFolderId: folder.id ?? -1,
                    viewModel: viewModel,
                    editListTarget: $editListTarget,
                    newRoutePresentation: $newRoutePresentation,
                    newWaypointPresentation: $newWaypointPresentation,
                    exportItemIds: $exportItemIds,
                    exportFilename: $exportFilename,
                    showingExportSheet: $showingExportSheet,
                    notEmptyAlertTitle: $notEmptyAlertTitle,
                    notEmptyAlertMessage: $notEmptyAlertMessage,
                    showNotEmptyAlert: $showNotEmptyAlert,
                    listScheduledForDeletion: $listScheduledForDeletion,
                    showDeleteListConfirm: $showDeleteListConfirm,
                    importGPXPreselectedListId: $importGPXPreselectedListId,
                    showingImportGPXSheet: $showingImportGPXSheet
                )
                .tag(list)
            }
        } label: {
            FolderLabelView(
                folder: folder,
                lists: lists,
                viewModel: viewModel,
                renamingFolderID: $renamingFolderID,
                renamingFolderText: $renamingFolderText,
                newListPreselectedFolderID: $newListPreselectedFolderID,
                showingNewListSheet: $showingNewListSheet,
                newWaypointPresentation: $newWaypointPresentation,
                newRoutePresentation: $newRoutePresentation,
                exportItemIds: $exportItemIds,
                exportFilename: $exportFilename,
                showingExportSheet: $showingExportSheet,
                notEmptyAlertTitle: $notEmptyAlertTitle,
                notEmptyAlertMessage: $notEmptyAlertMessage,
                showNotEmptyAlert: $showNotEmptyAlert,
                folderScheduledForDeletion: $folderScheduledForDeletion,
                showDeleteFolderConfirm: $showDeleteFolderConfirm,
                onCommitRename: commitFolderRename
            )
        }
    }

    // MARK: - Named sheet-save handlers

    private func handleRoutePropertiesSave(identity: RouteIdentity) {
        NotificationCenter.default.post(name: .routeKeeperLibraryDidChange, object: nil)
        cycleSelection(for: identity.id)
    }

    private func handleRouteWaypointSave(identity: RouteIdentity) {
        NotificationCenter.default.post(name: .routeKeeperLibraryDidChange, object: nil)
        cycleSelection(for: identity.id)
    }

    private func handleWaypointEditSave(identity: WaypointIdentity) {
        Task { await viewModel.reload() }
        cycleSelection(for: identity.id)
    }

    private func handleTrackPropertiesSave(identity: TrackIdentity) {
        NotificationCenter.default.post(name: .routeKeeperLibraryDidChange, object: nil)
        cycleSelection(for: identity.id)
    }

    // MARK: - Named sheet content builders

    /// Builds the RoutePropertiesSheet for a given identity.
    @ViewBuilder
    private func routePropertiesSheetView(identity: RouteIdentity) -> some View {
        RoutePropertiesSheet(
            routeItemId: identity.id,
            initialName: identity.name,
            onSave: { handleRoutePropertiesSave(identity: identity) }
        )
    }

    /// Builds the RouteWaypointSheet for a given identity.
    @ViewBuilder
    private func routeWaypointSheetView(identity: RouteIdentity) -> some View {
        RouteWaypointSheet(
            routeItemId: identity.id,
            routeName: identity.name,
            onSave: { handleRouteWaypointSave(identity: identity) }
        )
    }

    /// Builds the EditWaypointSheet for a given identity.
    @ViewBuilder
    private func waypointEditSheetView(identity: WaypointIdentity) -> some View {
        EditWaypointSheet(
            viewModel: viewModel,
            waypointItemId: identity.id
        ) {
            handleWaypointEditSave(identity: identity)
        }
    }

    /// Builds the TrackPropertiesSheet for a given identity.
    @ViewBuilder
    private func trackPropertiesSheetView(identity: TrackIdentity) -> some View {
        TrackPropertiesSheet(
            trackItemId: identity.id,
            initialName: identity.name,
            onSave: { handleTrackPropertiesSave(identity: identity) }
        )
    }

    /// Builds the ExportFormatSheet.
    @ViewBuilder
    private func exportSheetView() -> some View {
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

    // MARK: - Modal modifier factory

    /// Assembles the `LibrarySidebarModals` view modifier with the current
    /// bindings and sheet-content builders.  Calling `.modifier(modals)` from
    /// `body` keeps the main body expression short enough for the type-checker.
    private var modals: LibrarySidebarModals {
        LibrarySidebarModals(
            viewModel: viewModel,
            showingNewFolderSheet: $showingNewFolderSheet,
            showingNewListSheet: $showingNewListSheet,
            newListPreselectedFolderID: $newListPreselectedFolderID,
            newWaypointPresentation: $newWaypointPresentation,
            newRoutePresentation: $newRoutePresentation,
            routePropertiesTarget: $routePropertiesTarget,
            routeWaypointTarget: $routeWaypointTarget,
            waypointEditTarget: $waypointEditTarget,
            editListTarget: $editListTarget,
            showingExportSheet: $showingExportSheet,
            showExportError: $showExportError,
            exportErrorMessage: exportErrorMessage,
            showRemoveItemConfirm: $showRemoveItemConfirm,
            itemsScheduledForRemoval: $itemsScheduledForRemoval,
            showDeleteItemConfirm: $showDeleteItemConfirm,
            itemsScheduledForDeletion: $itemsScheduledForDeletion,
            showNotEmptyAlert: $showNotEmptyAlert,
            notEmptyAlertTitle: notEmptyAlertTitle,
            notEmptyAlertMessage: notEmptyAlertMessage,
            showDeleteListConfirm: $showDeleteListConfirm,
            listScheduledForDeletion: $listScheduledForDeletion,
            selectedList: $selectedList,
            selectedItems: $selectedItems,
            showDeleteFolderConfirm: $showDeleteFolderConfirm,
            folderScheduledForDeletion: $folderScheduledForDeletion,
            routePropertiesSheetContent: routePropertiesSheetView,
            routeWaypointSheetContent: routeWaypointSheetView,
            waypointEditSheetContent: waypointEditSheetView,
            trackPropertiesTarget: $trackPropertiesTarget,
            trackPropertiesSheetContent: trackPropertiesSheetView,
            exportSheetContent: exportSheetView
        )
    }

    // MARK: - Helpers

    /// Commits the in-progress inline folder rename, then exits rename mode.
    private func commitFolderRename(_ folder: ListFolder) {
        let trimmed = renamingFolderText.trimmingCharacters(in: .whitespaces)
        renamingFolderID = nil
        guard !trimmed.isEmpty, trimmed != folder.name, let folderId = folder.id else { return }
        Task { await viewModel.renameFolder(folderId: folderId, newName: trimmed) }
    }

    /// Cycles `selectedItems` off and back on so ContentView re-evaluates
    /// the map display after an edit sheet saves changes.
    private func cycleSelection(for itemId: Int64) {
        guard selectedItems.contains(where: { $0.id == itemId }) else { return }
        let snapshot = selectedItems
        selectedItems = []
        // TODO: [REFACTOR] Task.sleep is a fragile workaround for a selection-state race.
        // Replace with a proper observable signal or a ViewModel-driven refresh trigger.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            selectedItems = snapshot
        }
    }

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

    // MARK: - GPX export

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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let exportItems = try await DatabaseManager.shared.fetchItemsForExport(
                itemIds: itemIds
            )
            let gpxString = GPXExporter.exportGPX(items: exportItems, format: format)
            guard let data = gpxString.data(using: .utf8) else {
                exportErrorMessage = "The file couldn't be saved."
                showExportError    = true
                return
            }
            try data.write(to: url)
        } catch {
            exportErrorMessage = "The file couldn't be saved. Check that you have permission to write to the chosen location."
            showExportError = true
        }
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:?*\\\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}

// MARK: - Event handler modifier

/// Applies all onChange, onReceive, and onAppear modifiers to the sidebar's core view.
///
/// Extracted from `LibrarySidebarView.coreView` so the type-checker evaluates the
/// event-handler chain independently from the base view and focused-value chain.
private struct LibrarySidebarHandlers: ViewModifier {

    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?
    @Binding var selectedItems: Set<Item>
    @Binding var itemSelectionClearedList: Bool
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    @Binding var itemsScheduledForRemoval: [Item]
    @Binding var showRemoveItemConfirm: Bool
    @Binding var itemsScheduledForDeletion: [Item]
    @Binding var showDeleteItemConfirm: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .routeKeeperRemoveFromList)
            ) { _ in
                let items: Set<Item>   = selectedItems
                let list: RouteList?   = viewModel.currentList
                let listId: Int64?     = list?.id
                guard !items.isEmpty, let lid = listId, lid != -1 else { return }
                itemsScheduledForRemoval = Array(items)
                showRemoveItemConfirm    = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .routeKeeperDeleteSelected)
            ) { _ in
                let items: Set<Item> = selectedItems
                guard !items.isEmpty else { return }
                itemsScheduledForDeletion = Array(items)
                showDeleteItemConfirm     = true
            }
            .onChange(of: selectedList) { _, newList in
                if itemSelectionClearedList {
                    itemSelectionClearedList = false
                    return
                }
                // selectedList becoming nil while selectedItems is already populated
                // is the signature of a single-item restore completing.  The map is
                // already showing the correct single-item view — do not fire a list
                // render that would overwrite it.
                if newList == nil && !selectedItems.isEmpty { return }
                selectedItems = []
                Task {
                    if let list = newList {
                        await viewModel.loadItems(for: list)
                    } else {
                        viewModel.clearItems()
                    }
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                guard !newItems.isEmpty, selectedList != nil else { return }
                itemSelectionClearedList = true
                selectedList = nil
            }
            .onChange(of: viewModel.lastCreatedItem) { _, item in
                guard let item else { return }
                viewModel.lastCreatedItem = nil
                selectedItems = [item]
            }
            .onChange(of: viewModel.pendingRestoredItems) { _, items in
                guard let items else { return }
                viewModel.pendingRestoredItems = nil
                if items.count == 1 {
                    // Clear selectedList atomically before applying the selection so
                    // mapSelectionKey jumps directly to {nil, {id}} — the same state
                    // produced by a user clicking a single item — rather than passing
                    // through the intermediate {listId, {id}} state that can cause the
                    // list-display task to race ahead and render the full list view.
                    itemSelectionClearedList = true
                    selectedList = nil
                    selectedItems = items
                } else {
                    selectedItems = items
                }
            }
            .onChange(of: sortColumn) { _, _ in
                Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
            }
            .onChange(of: sortAscending) { _, _ in
                Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
            }
            .onAppear {
                let list: RouteList? = selectedList
                if let list {
                    Task { await viewModel.loadItems(for: list) }
                }
            }
    }
}

// MARK: - Modal view modifier

/// Applies all sheet, confirmation-dialog, and alert modifiers to the sidebar.
///
/// Extracted into a dedicated `ViewModifier` so the type-checker evaluates the
/// full modal chain inside `body(content:)` independently from
/// `LibrarySidebarView.body`, preventing expression-complexity timeouts in both.
private struct LibrarySidebarModals: ViewModifier {

    let viewModel: LibraryViewModel

    @Binding var showingNewFolderSheet: Bool
    @Binding var showingNewListSheet: Bool
    @Binding var newListPreselectedFolderID: Int64?
    @Binding var newWaypointPresentation: NewItemPresentation?
    @Binding var newRoutePresentation: NewItemPresentation?
    @Binding var routePropertiesTarget: RouteIdentity?
    @Binding var routeWaypointTarget: RouteIdentity?
    @Binding var waypointEditTarget: WaypointIdentity?
    @Binding var editListTarget: RouteList?
    @Binding var showingExportSheet: Bool
    @Binding var showExportError: Bool
    let exportErrorMessage: String
    @Binding var showRemoveItemConfirm: Bool
    @Binding var itemsScheduledForRemoval: [Item]
    @Binding var showDeleteItemConfirm: Bool
    @Binding var itemsScheduledForDeletion: [Item]
    @Binding var showNotEmptyAlert: Bool
    let notEmptyAlertTitle: String
    let notEmptyAlertMessage: String
    @Binding var showDeleteListConfirm: Bool
    @Binding var listScheduledForDeletion: RouteList?
    @Binding var selectedList: RouteList?
    @Binding var selectedItems: Set<Item>
    @Binding var showDeleteFolderConfirm: Bool
    @Binding var folderScheduledForDeletion: ListFolder?

    @Binding var trackPropertiesTarget: TrackIdentity?

    // Injected sheet-content builders (avoids re-capturing closures here)
    let routePropertiesSheetContent: (RouteIdentity) -> AnyView
    let routeWaypointSheetContent:   (RouteIdentity) -> AnyView
    let waypointEditSheetContent:    (WaypointIdentity) -> AnyView
    let trackPropertiesSheetContent: (TrackIdentity) -> AnyView
    let exportSheetContent:          () -> AnyView

    init(
        viewModel: LibraryViewModel,
        showingNewFolderSheet: Binding<Bool>,
        showingNewListSheet: Binding<Bool>,
        newListPreselectedFolderID: Binding<Int64?>,
        newWaypointPresentation: Binding<NewItemPresentation?>,
        newRoutePresentation: Binding<NewItemPresentation?>,
        routePropertiesTarget: Binding<RouteIdentity?>,
        routeWaypointTarget: Binding<RouteIdentity?>,
        waypointEditTarget: Binding<WaypointIdentity?>,
        editListTarget: Binding<RouteList?>,
        showingExportSheet: Binding<Bool>,
        showExportError: Binding<Bool>,
        exportErrorMessage: String,
        showRemoveItemConfirm: Binding<Bool>,
        itemsScheduledForRemoval: Binding<[Item]>,
        showDeleteItemConfirm: Binding<Bool>,
        itemsScheduledForDeletion: Binding<[Item]>,
        showNotEmptyAlert: Binding<Bool>,
        notEmptyAlertTitle: String,
        notEmptyAlertMessage: String,
        showDeleteListConfirm: Binding<Bool>,
        listScheduledForDeletion: Binding<RouteList?>,
        selectedList: Binding<RouteList?>,
        selectedItems: Binding<Set<Item>>,
        showDeleteFolderConfirm: Binding<Bool>,
        folderScheduledForDeletion: Binding<ListFolder?>,
        routePropertiesSheetContent: @escaping (RouteIdentity) -> some View,
        routeWaypointSheetContent:   @escaping (RouteIdentity) -> some View,
        waypointEditSheetContent:    @escaping (WaypointIdentity) -> some View,
        trackPropertiesTarget: Binding<TrackIdentity?>,
        trackPropertiesSheetContent: @escaping (TrackIdentity) -> some View,
        exportSheetContent:          @escaping () -> some View
    ) {
        self.viewModel = viewModel
        self._showingNewFolderSheet = showingNewFolderSheet
        self._showingNewListSheet = showingNewListSheet
        self._newListPreselectedFolderID = newListPreselectedFolderID
        self._newWaypointPresentation = newWaypointPresentation
        self._newRoutePresentation = newRoutePresentation
        self._routePropertiesTarget = routePropertiesTarget
        self._routeWaypointTarget = routeWaypointTarget
        self._waypointEditTarget = waypointEditTarget
        self._editListTarget = editListTarget
        self._showingExportSheet = showingExportSheet
        self._showExportError = showExportError
        self.exportErrorMessage = exportErrorMessage
        self._showRemoveItemConfirm = showRemoveItemConfirm
        self._itemsScheduledForRemoval = itemsScheduledForRemoval
        self._showDeleteItemConfirm = showDeleteItemConfirm
        self._itemsScheduledForDeletion = itemsScheduledForDeletion
        self._showNotEmptyAlert = showNotEmptyAlert
        self.notEmptyAlertTitle = notEmptyAlertTitle
        self.notEmptyAlertMessage = notEmptyAlertMessage
        self._showDeleteListConfirm = showDeleteListConfirm
        self._listScheduledForDeletion = listScheduledForDeletion
        self._selectedList = selectedList
        self._selectedItems = selectedItems
        self._showDeleteFolderConfirm = showDeleteFolderConfirm
        self._folderScheduledForDeletion = folderScheduledForDeletion
        self.routePropertiesSheetContent = { AnyView(routePropertiesSheetContent($0)) }
        self.routeWaypointSheetContent   = { AnyView(routeWaypointSheetContent($0)) }
        self.waypointEditSheetContent    = { AnyView(waypointEditSheetContent($0)) }
        self._trackPropertiesTarget      = trackPropertiesTarget
        self.trackPropertiesSheetContent = { AnyView(trackPropertiesSheetContent($0)) }
        self.exportSheetContent          = { AnyView(exportSheetContent()) }
    }

    func body(content: Content) -> some View {
        content
            // ── Sheets ──────────────────────────────────────────────────
            .sheet(isPresented: $showingNewFolderSheet) {
                NewFolderSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showingNewListSheet) {
                NewListSheet(
                    viewModel: viewModel,
                    preselectedFolderID: newListPreselectedFolderID
                )
            }
            .sheet(item: $newWaypointPresentation) { presentation in
                NewWaypointSheet(
                    viewModel: viewModel,
                    preselectedListID: presentation.preselectedListID,
                    prefilledCoordinate: nil
                )
            }
            .sheet(item: $newRoutePresentation) { presentation in
                NewRouteSheet(
                    viewModel: viewModel,
                    preselectedListID: presentation.preselectedListID
                )
            }
            .sheet(item: $routePropertiesTarget) { routePropertiesSheetContent($0) }
            .sheet(item: $routeWaypointTarget)   { routeWaypointSheetContent($0) }
            .sheet(item: $waypointEditTarget)    { waypointEditSheetContent($0) }
            .sheet(item: $trackPropertiesTarget) { trackPropertiesSheetContent($0) }
            .sheet(item: $editListTarget) { list in
                NewListSheet(viewModel: viewModel, preselectedFolderID: nil, editingList: list)
            }
            .sheet(isPresented: $showingExportSheet) { exportSheetContent() }
            // ── Confirmation dialogs ─────────────────────────────────────
            .confirmationDialog(
                itemsScheduledForRemoval.count > 1
                    ? "Remove \(itemsScheduledForRemoval.count) items from this list?"
                    : "Remove from this list?",
                isPresented: $showRemoveItemConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    let items  = itemsScheduledForRemoval
                    let listId = viewModel.currentList?.id
                    selectedItems = selectedItems.filter { s in !items.contains { $0.id == s.id } }
                    Task {
                        for item in items {
                            guard let itemId = item.id, let lid = listId else { continue }
                            await viewModel.removeItemFromList(itemId: itemId, listId: lid)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if itemsScheduledForRemoval.count > 1 {
                    Text("\(itemsScheduledForRemoval.count) items will be removed from this list.")
                } else if let item = itemsScheduledForRemoval.first {
                    Text("\(item.name) will be removed from this list and moved to Unclassified.")
                }
            }
            .confirmationDialog(
                itemsScheduledForDeletion.count > 1
                    ? "Delete \(itemsScheduledForDeletion.count) items?"
                    : "Delete item?",
                isPresented: $showDeleteItemConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let items = itemsScheduledForDeletion
                    selectedItems = selectedItems.filter { s in !items.contains { $0.id == s.id } }
                    Task {
                        for item in items {
                            guard let itemId = item.id else { continue }
                            await viewModel.deleteItem(itemId: itemId)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if itemsScheduledForDeletion.count > 1 {
                    Text("\(itemsScheduledForDeletion.count) items will be permanently deleted " +
                         "and cannot be recovered.")
                } else if let item = itemsScheduledForDeletion.first {
                    Text("\(item.name) will be permanently deleted and cannot be recovered.")
                }
            }
            .confirmationDialog(
                "Delete list?",
                isPresented: $showDeleteListConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let list = listScheduledForDeletion else { return }
                    if selectedList?.id == list.id || viewModel.currentList?.id == list.id {
                        selectedList  = nil
                        selectedItems = []
                    }
                    Task { await viewModel.deleteList(list) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let list = listScheduledForDeletion {
                    Text("\(list.name) will be permanently deleted.")
                }
            }
            .confirmationDialog(
                "Delete folder?",
                isPresented: $showDeleteFolderConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let folder = folderScheduledForDeletion else { return }
                    let currentFolderId = selectedList?.folderId
                        ?? viewModel.currentList?.folderId
                    if let fid = currentFolderId, fid == folder.id {
                        selectedList  = nil
                        selectedItems = []
                    }
                    Task { await viewModel.deleteFolder(folder) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let folder = folderScheduledForDeletion {
                    Text("\(folder.name) and all its lists will be permanently deleted.")
                }
            }
            // ── Alerts ───────────────────────────────────────────────────
            .alert(notEmptyAlertTitle, isPresented: $showNotEmptyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(notEmptyAlertMessage)
            }
            .alert("Export Failed", isPresented: $showExportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(exportErrorMessage)
            }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        LibrarySidebarView(
            viewModel: LibraryViewModel(),
            selectedList: .constant(nil),
            selectedItems: .constant([])
        )
    } detail: {
        Text("Select a list to view its contents")
            .foregroundStyle(.secondary)
    }
    .frame(width: 1000, height: 600)
}
