//
//  LibraryBottomPanel.swift
//  RouteKeeper
//
//  The resizable bottom panel containing the items list.
//  Owns the panel height preference, the drag-to-resize gesture, and all
//  item-level interactions (context menus, double-click, drag for move/copy).
//  Extracted from LibrarySidebarView to reduce the type-checker burden
//  on the parent body expression.
//

import AppKit
import SwiftUI

/// The resizable panel pinned to the bottom of the sidebar.
///
/// Contains the draggable divider, the items `List`, and all item-level
/// interactions. Receives bindings for state that the parent also needs
/// (sheet triggers, confirmation dialogs, export state).
struct LibraryBottomPanel: View {
    let viewModel: LibraryViewModel

    @Binding var selectedItems: Set<Item>
    @Binding var routePropertiesTarget: RouteIdentity?
    @Binding var routeWaypointTarget: RouteIdentity?
    @Binding var waypointEditTarget: WaypointIdentity?
    @Binding var trackPropertiesTarget: TrackIdentity?
    @Binding var exportItemIds: [Int64]
    @Binding var exportFilename: String
    @Binding var showingExportSheet: Bool
    @Binding var showRemoveItemConfirm: Bool
    @Binding var itemsScheduledForRemoval: [Item]
    @Binding var showDeleteItemConfirm: Bool
    @Binding var itemsScheduledForDeletion: [Item]

    @AppStorage("library.bottomPanelHeight") private var bottomPanelHeight: Double = 200
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat = 200

    private let dividerHeight:  CGFloat = 8
    private let minPanelHeight: CGFloat = 80
    private let maxPanelHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
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
                            let proposed = dragStartHeight - value.translation.height
                            bottomPanelHeight = Double(
                                min(max(proposed, minPanelHeight), maxPanelHeight)
                            )
                        }
                        .onEnded { _ in isDragging = false }
                )
                .cursor(.resizeUpDown)

            itemsPanel
                .frame(height: CGFloat(bottomPanelHeight))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Items panel

    private var itemsPanel: some View {
        Group {
            if viewModel.currentList != nil {
                List(selection: $selectedItems) {
                    ForEach(viewModel.listItems) { item in
                        itemRow(item)
                    }
                }
                .listStyle(.sidebar)
                .onKeyPress(phases: .down) { keyPress in
                    guard !selectedItems.isEmpty else { return .ignored }
                    let isCmd = keyPress.modifiers.contains(.command)
                    if keyPress.key == .delete && isCmd {
                        NotificationCenter.default.post(
                            name: .routeKeeperDeleteSelected, object: nil)
                        return .handled
                    }
                    if (keyPress.key == .delete || keyPress.key == .deleteForward) && !isCmd {
                        NotificationCenter.default.post(
                            name: .routeKeeperRemoveFromList, object: nil)
                        return .handled
                    }
                    return .ignored
                }
                .overlay {
                    if viewModel.listItems.isEmpty {
                        Text("No items in this list").foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Select a list")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: Item) -> some View {
        Label {
            Text(item.name)
        } icon: {
            Image(systemName: item.type == .waypoint
                ? (item.categoryIcon ?? item.type.systemImage)
                : item.type.systemImage)
                .foregroundStyle(iconColor(for: item))
        }
        .tag(item)
        .contextMenu {
            itemContextMenu(for: item)
        }
        .draggable(DraggableItem(
            itemIds: selectedItems.contains(item)
                ? selectedItems.compactMap(\.id)
                : [item.id ?? 0],
            sourceListId: viewModel.currentList?.id ?? -1
        ))
        .overlay(
            DoubleClickHandler {
                guard let itemId = item.id else { return }
                selectedItems = [item]
                if item.type == .route {
                    routePropertiesTarget = RouteIdentity(id: itemId, name: item.name)
                } else if item.type == .waypoint {
                    waypointEditTarget = WaypointIdentity(id: itemId, name: item.name)
                } else if item.type == .track {
                    trackPropertiesTarget = TrackIdentity(id: itemId, name: item.name)
                }
            }
        )
    }

    // MARK: - Item context menu

    @ViewBuilder
    private func itemContextMenu(for item: Item) -> some View {
        let currentListId   = viewModel.currentList?.id ?? -1
        let isUnclassified  = currentListId == -1
        let itemId          = item.id ?? -1
        let alreadyIn       = viewModel.itemMemberships[itemId] ?? []
        let realFolders     = viewModel.folderContents.filter { $0.folder.id != -1 }

        // If the right-clicked item is part of the current multi-selection, the
        // remove/delete operations apply to every selected item; otherwise only to
        // the item that was right-clicked.
        let effectiveItems: [Item] = selectedItems.contains(item)
            ? Array(selectedItems)
            : [item]
        let effectiveCount = effectiveItems.count

        if effectiveCount == 1 {
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
            } else if item.type == .track {
                Button("Track Properties…") {
                    trackPropertiesTarget = TrackIdentity(id: itemId, name: item.name)
                }
                Divider()
            }

            Menu("Move to…") {
                ForEach(realFolders, id: \.folder.id) { folder, lists in
                    let targets = lists.filter { ($0.id ?? -1) != currentListId }
                    if !targets.isEmpty {
                        Section(folder.name) {
                            ForEach(targets) { list in
                                Button(list.name) {
                                    Task {
                                        if isUnclassified {
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

            Divider()

            Button("Export GPX…") {
                guard item.id != nil else { return }
                exportItemIds  = [itemId]
                exportFilename = item.name
                showingExportSheet = true
            }

            Divider()
        }

        // ── Remove / Delete (single or multi) ────────────────────────────────

        if !isUnclassified {
            if effectiveCount == 1 && alreadyIn.count > 1 {
                // Single item that remains in other lists — no confirmation needed.
                Button("Remove from this list") {
                    Task {
                        selectedItems = selectedItems.filter { $0.id != itemId }
                        await viewModel.removeItemFromList(
                            itemId: itemId, listId: currentListId
                        )
                    }
                }
            } else {
                let removeLabel = effectiveCount > 1
                    ? "Remove \(effectiveCount) Items from This List…"
                    : "Remove from this list…"
                Button(removeLabel) {
                    itemsScheduledForRemoval = effectiveItems
                    showRemoveItemConfirm    = true
                }
            }
        }

        let deleteLabel = effectiveCount > 1
            ? "Delete \(effectiveCount) Items…"
            : "Delete…"
        Button(deleteLabel, role: .destructive) {
            itemsScheduledForDeletion = effectiveItems
            showDeleteItemConfirm     = true
        }
    }

    // MARK: - Helpers

    private func iconColor(for item: Item) -> Color {
        if let hex = item.colour, !hex.isEmpty {
            return Color(itemHex: hex)
        }
        return .secondary
    }
}
