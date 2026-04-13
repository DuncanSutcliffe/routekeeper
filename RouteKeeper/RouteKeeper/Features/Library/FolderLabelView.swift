//
//  FolderLabelView.swift
//  RouteKeeper
//
//  The label content for a folder's DisclosureGroup.
//  Handles inline rename, the folder context menu, the double-click trigger,
//  and drop-destination for list-to-folder drags.
//  Extracted from LibrarySidebarView to reduce the type-checker burden
//  on the parent body expression.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The label content for a folder's `DisclosureGroup`.
struct FolderLabelView: View {
    let folder: ListFolder
    let lists: [RouteList]
    let viewModel: LibraryViewModel

    @Binding var renamingFolderID: Int64?
    @Binding var renamingFolderText: String
    @Binding var newListPreselectedFolderID: Int64?
    @Binding var showingNewListSheet: Bool
    @Binding var newWaypointPresentation: NewItemPresentation?
    @Binding var newRoutePresentation: NewItemPresentation?
    @Binding var exportItemIds: [Int64]
    @Binding var exportFilename: String
    @Binding var showingExportSheet: Bool
    @Binding var notEmptyAlertTitle: String
    @Binding var notEmptyAlertMessage: String
    @Binding var showNotEmptyAlert: Bool
    @Binding var folderScheduledForDeletion: ListFolder?
    @Binding var showDeleteFolderConfirm: Bool

    let onCommitRename: (ListFolder) -> Void

    @FocusState private var textFieldFocused: Bool

    private var isRenaming: Bool {
        renamingFolderID == folder.id && folder.id != nil && folder.id != -1
    }

    var body: some View {
        Label {
            if isRenaming {
                TextField("", text: $renamingFolderText)
                    .textFieldStyle(.plain)
                    .focused($textFieldFocused)
                    .onSubmit { onCommitRename(folder) }
                    .onKeyPress(.escape) {
                        renamingFolderID = nil
                        return .handled
                    }
            } else {
                Text(folder.name)
            }
        } icon: {
            if folder.id == -1 {
                Image(systemName: "tray.fill").foregroundStyle(.secondary)
            } else {
                Image(systemName: "folder.fill")
            }
        }
        .fontWeight(.bold)
        .contextMenu { folderContextMenu }
        .overlay(
            Group {
                if folder.id != -1 && !isRenaming {
                    DoubleClickHandler {
                        renamingFolderText = folder.name
                        renamingFolderID   = folder.id
                    }
                }
            }
        )
        .onDrop(
            of: [.routeKeeperListItem],
            delegate: FolderDropDelegate(targetFolder: folder, viewModel: viewModel)
        )
        .onChange(of: isRenaming) { _, renaming in
            if renaming { textFieldFocused = true }
        }
    }

    @ViewBuilder
    private var folderContextMenu: some View {
        if folder.id != -1 {
            Button("Rename…") {
                renamingFolderText = folder.name
                renamingFolderID   = folder.id
            }
            Divider()
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
                        notEmptyAlertMessage = "\(folder.name) contains no items to export."
                        showNotEmptyAlert    = true
                    } else {
                        let ids = (try? await DatabaseManager.shared
                            .fetchItemIdsForFolder(folderId: folderId)) ?? []
                        exportItemIds    = ids
                        exportFilename   = folder.name
                        showingExportSheet = true
                    }
                }
            }
            Divider()
            Button("Delete Folder…", role: .destructive) {
                Task {
                    guard let folderId = folder.id else { return }
                    let hasItems = (try? await DatabaseManager.shared
                        .folderHasItems(folderId: folderId)) ?? false
                    if hasItems {
                        notEmptyAlertTitle   = "Cannot Delete Folder"
                        notEmptyAlertMessage = "\(folder.name) cannot be deleted because one or more of its lists contain items. Remove all items from the lists before deleting the folder."
                        showNotEmptyAlert = true
                    } else {
                        folderScheduledForDeletion = folder
                        showDeleteFolderConfirm    = true
                    }
                }
            }
        }
    }
}
