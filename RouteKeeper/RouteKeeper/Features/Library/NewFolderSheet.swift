//
//  NewFolderSheet.swift
//  RouteKeeper
//
//  Sheet presented when the user chooses File > New Folder, clicks the
//  toolbar button, or right-clicks the sidebar. Creates a new library folder.
//

import SwiftUI

struct NewFolderSheet: View {
    let viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)
                .onSubmit { submit() }

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
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            fieldIsFocused = true
        }
    }

    private func submit() {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            await viewModel.createFolder(name: trimmed)
            dismiss()
        }
    }
}

#Preview {
    NewFolderSheet(viewModel: LibraryViewModel())
}
