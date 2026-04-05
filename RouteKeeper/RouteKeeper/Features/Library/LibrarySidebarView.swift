//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  The left-column sidebar showing the library: folders containing lists.
//  Data is provided by LibraryViewModel, which loads from the database.
//

import SwiftUI

struct LibrarySidebarView: View {
    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?

    var body: some View {
        List(selection: $selectedList) {
            ForEach(viewModel.folderContents, id: \.folder.id) { folder, lists in
                Section(folder.name) {
                    ForEach(lists) { list in
                        Label(list.name, systemImage: "map")
                            .tag(list)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }
}

#Preview {
    NavigationSplitView {
        LibrarySidebarView(
            viewModel: LibraryViewModel(),
            selectedList: .constant(nil)
        )
    } detail: {
        Text("Select a list to view its contents")
            .foregroundStyle(.secondary)
    }
    .frame(width: 1000, height: 600)
}
