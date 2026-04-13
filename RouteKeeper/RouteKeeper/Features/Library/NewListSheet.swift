//
//  NewListSheet.swift
//  RouteKeeper
//
//  Sheet for creating a new list or editing an existing one.
//  Pass `editingList: nil` (default) for create mode, or a `RouteList` for
//  edit mode. In edit mode the sheet is pre-populated with the list's current
//  name and folder; saving calls updateList rather than createList.
//

import SwiftUI

struct NewListSheet: View {
    let viewModel: LibraryViewModel
    /// Folder to pre-select when creating a new list. Ignored in edit mode.
    let preselectedFolderID: Int64?
    /// Non-nil when the sheet is in edit mode.
    var editingList: RouteList? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var listName = ""
    @State private var selectedFolderID: Int64?
    @FocusState private var fieldIsFocused: Bool

    private var isEditMode: Bool { editingList != nil }

    /// All non-sentinel folders available for selection.
    private var realFolders: [(folder: ListFolder, lists: [RouteList])] {
        viewModel.folderContents.filter {
            guard let id = $0.folder.id else { return false }
            return id != -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditMode ? "Edit List" : "New List")
                .font(.headline)

            TextField("List name", text: $listName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)
                .onSubmit { submit() }
                .onChange(of: listName) {
                    viewModel.creationError = nil
                }

            if let error = viewModel.creationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Folder", selection: $selectedFolderID) {
                ForEach(realFolders, id: \.folder.id) { item in
                    Text(item.folder.name)
                        .tag(item.folder.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(realFolders.isEmpty)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditMode ? "Save" : "OK") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty
                          || selectedFolderID == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            viewModel.creationError = nil
            fieldIsFocused = true
            if let editing = editingList {
                listName = editing.name
                selectedFolderID = editing.folderId
                    ?? preselectedFolderID
                    ?? realFolders.first?.folder.id
            } else {
                selectedFolderID = preselectedFolderID ?? realFolders.first?.folder.id
            }
        }
    }

    private func submit() {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let folderID = selectedFolderID else { return }
        Task {
            if let editing = editingList, let listId = editing.id {
                await viewModel.updateList(
                    listId: listId,
                    newName: trimmed,
                    newFolderId: folderID
                )
            } else {
                await viewModel.createList(name: trimmed, folderId: folderID)
            }
            if viewModel.creationError == nil {
                dismiss()
            }
        }
    }
}

#Preview {
    NewListSheet(viewModel: LibraryViewModel(), preselectedFolderID: nil)
}
