//
//  NewListSheet.swift
//  RouteKeeper
//
//  Sheet presented when the user creates a new list. Allows the user to
//  name the list and choose which folder to place it in.
//

import SwiftUI

struct NewListSheet: View {
    let viewModel: LibraryViewModel
    /// Folder to pre-select in the picker. Defaults to the first real folder
    /// when nil.
    let preselectedFolderID: Int64?

    @Environment(\.dismiss) private var dismiss
    @State private var listName = ""
    @State private var selectedFolderID: Int64?
    @FocusState private var fieldIsFocused: Bool

    /// All non-sentinel folders available for selection.
    private var realFolders: [(folder: ListFolder, lists: [RouteList])] {
        viewModel.folderContents.filter {
            guard let id = $0.folder.id else { return false }
            return id != -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New List")
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

                Button("OK") {
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
            selectedFolderID = preselectedFolderID ?? realFolders.first?.folder.id
        }
    }

    private func submit() {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let folderID = selectedFolderID else { return }
        Task {
            await viewModel.createList(name: trimmed, folderId: folderID)
            if viewModel.creationError == nil {
                dismiss()
            }
        }
    }
}

#Preview {
    NewListSheet(viewModel: LibraryViewModel(), preselectedFolderID: nil)
}
