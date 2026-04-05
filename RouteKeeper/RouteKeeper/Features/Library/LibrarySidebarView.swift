//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  The left-column sidebar showing the library: folders containing lists.
//

import SwiftUI

struct LibrarySidebarView: View {
    let folders: [ListFolder]
    @Binding var selectedList: RouteList?

    var body: some View {
        List(selection: $selectedList) {
            ForEach(folders) { folder in
                Section(folder.name) {
                    ForEach(folder.lists) { list in
                        Label(list.name, systemImage: "map")
                            .tag(list)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }
}

#Preview {
    NavigationSplitView {
        LibrarySidebarView(
            folders: ListFolder.placeholders,
            selectedList: .constant(nil)
        )
    } detail: {
        Text("Select a list to view its contents")
            .foregroundStyle(.secondary)
    }
    .frame(width: 1000, height: 600)
}
