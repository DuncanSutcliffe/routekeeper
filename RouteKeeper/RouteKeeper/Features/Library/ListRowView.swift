//
//  ListRowView.swift
//  RouteKeeper
//
//  The row for a single list inside the folder tree.
//  Extracted from LibrarySidebarView to reduce the type-checker burden
//  on the parent body expression.
//

import AppKit
import SwiftUI

/// The row for a single list inside the folder tree.
struct ListRowView: View {
    let list: RouteList
    let sourceFolderId: Int64
    let viewModel: LibraryViewModel

    @Binding var editListTarget: RouteList?
    @Binding var newRoutePresentation: NewItemPresentation?
    @Binding var newWaypointPresentation: NewItemPresentation?
    @Binding var exportItemIds: [Int64]
    @Binding var exportFilename: String
    @Binding var showingExportSheet: Bool
    @Binding var notEmptyAlertTitle: String
    @Binding var notEmptyAlertMessage: String
    @Binding var showNotEmptyAlert: Bool
    @Binding var listScheduledForDeletion: RouteList?
    @Binding var showDeleteListConfirm: Bool

    var body: some View {
        Label {
            Text(list.name)
        } icon: {
            if list.id == -1 {
                Image(systemName: "map").foregroundStyle(.secondary)
            } else {
                Image(systemName: "map")
            }
        }
        .contextMenu { listContextMenu }
        .draggable(DraggableList(listId: list.id ?? 0, sourceFolderId: sourceFolderId))
        .overlay(
            Group {
                if list.id != -1 {
                    DoubleClickHandler { editListTarget = list }
                }
            }
        )
        .onDrop(
            of: [.routeKeeperItem],
            delegate: ListDropDelegate(targetList: list, viewModel: viewModel)
        )
    }

    @ViewBuilder
    private var listContextMenu: some View {
        Button {
            newRoutePresentation = NewItemPresentation(preselectedListID: list.id)
        } label: {
            Label("New Route", systemImage: "road.lanes")
        }
        Button {
            newWaypointPresentation = NewItemPresentation(preselectedListID: list.id)
        } label: {
            Label("New Waypoint", systemImage: "mappin.and.ellipse")
        }
        if list.id != -1 {
            Divider()
            Button("Edit List…") { editListTarget = list }
            Divider()
            Button("Export GPX…") {
                Task {
                    guard let listId = list.id else { return }
                    let count = (try? await DatabaseManager.shared
                        .fetchListItemCount(listId: listId)) ?? 0
                    if count == 0 {
                        notEmptyAlertTitle   = "Nothing to Export"
                        notEmptyAlertMessage = "\(list.name) contains no items to export."
                        showNotEmptyAlert    = true
                    } else {
                        let ids = (try? await DatabaseManager.shared
                            .fetchItemIdsForList(listId: listId)) ?? []
                        exportItemIds    = ids
                        exportFilename   = list.name
                        showingExportSheet = true
                    }
                }
            }
            Divider()
            Button("Delete List…", role: .destructive) {
                Task {
                    guard let listId = list.id else { return }
                    let count = (try? await DatabaseManager.shared
                        .fetchListItemCount(listId: listId)) ?? 0
                    if count > 0 {
                        notEmptyAlertTitle   = "Cannot Delete List"
                        notEmptyAlertMessage = "\(list.name) cannot be deleted because it contains items. Remove all items from the list before deleting it."
                        showNotEmptyAlert    = true
                    } else {
                        listScheduledForDeletion = list
                        showDeleteListConfirm    = true
                    }
                }
            }
        }
    }
}
