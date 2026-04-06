//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  Split sidebar: top panel shows folders and lists; bottom panel shows
//  the contents (items) of the selected list.
//
//  The split is implemented manually with a GeometryReader and a draggable
//  divider so that content changes never affect panel heights. splitFraction
//  is stored in @AppStorage so the user's preferred split persists.
//

import SwiftUI

struct LibrarySidebarView: View {
    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?
    @Binding var selectedItem: Item?

    // Sort preference — persisted across launches.
    @AppStorage("library.sortColumn")    private var sortColumn: String = "name"
    @AppStorage("library.sortAscending") private var sortAscending: Bool = true

    // Fraction of total height given to the top panel.
    // Persisted so the user's preferred split survives relaunch.
    @AppStorage("library.splitFraction") private var splitFraction: Double = 0.7

    @State private var showingNewFolderSheet = false
    @State private var showingNewListSheet = false
    @State private var newListPreselectedFolderID: Int64?

    @State private var showingNewWaypointSheet = false
    @State private var newWaypointPreselectedListID: Int64?

    private let dividerHeight: CGFloat = 8
    private let minFraction:   CGFloat = 0.3
    private let maxFraction:   CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let totalHeight    = geometry.size.height
            let topHeight      = CGFloat(splitFraction) * totalHeight
            let bottomHeight   = totalHeight - topHeight - dividerHeight

            VStack(spacing: 0) {
                topPanel
                    .frame(height: topHeight)

                // Draggable divider
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: dividerHeight)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let proposed = (topHeight + value.translation.height) / totalHeight
                                splitFraction = Double(proposed.clamped(to: minFraction...maxFraction))
                            }
                    )
                    .cursor(.resizeUpDown)

                bottomPanel
                    .frame(height: bottomHeight)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button {
                    newWaypointPreselectedListID = nil
                    showingNewWaypointSheet = true
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .help("New Waypoint")
            }
            ToolbarItem {
                Button {
                    newListPreselectedFolderID = nil
                    showingNewListSheet = true
                } label: {
                    Image(systemName: "rectangle.badge.plus")
                }
                .help("New List")
            }
            ToolbarItem {
                Button {
                    showingNewFolderSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New Folder")
            }
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            NewFolderSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingNewListSheet) {
            NewListSheet(viewModel: viewModel, preselectedFolderID: newListPreselectedFolderID)
        }
        .sheet(isPresented: $showingNewWaypointSheet) {
            NewWaypointSheet(viewModel: viewModel, preselectedListID: newWaypointPreselectedListID)
        }
        .focusedValue(\.showNewFolderSheet, $showingNewFolderSheet)
        .focusedValue(\.showNewListSheet, $showingNewListSheet)
        .focusedValue(\.showNewWaypointSheet, $showingNewWaypointSheet)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        // When the selected list changes, clear the item selection and
        // load the new list's contents.
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
        // When sort preference changes, reload folders.
        .onChange(of: sortColumn) { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        .onChange(of: sortAscending) { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        // Load items for any list that's already selected on first appear.
        .onAppear {
            if let list = selectedList {
                Task { await viewModel.loadItems(for: list) }
            }
        }
    }

    // MARK: - Top panel

    private var topPanel: some View {
        VStack(spacing: 0) {
            sortToolbar
            Divider()
            List(selection: $selectedList) {
                ForEach(viewModel.folderContents, id: \.folder.id) { folder, lists in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: folder)
                    ) {
                        ForEach(lists) { list in
                            Label(list.name, systemImage: "map")
                                .tag(list)
                                .contextMenu {
                                    Button {
                                        newWaypointPreselectedListID = list.id
                                        showingNewWaypointSheet = true
                                    } label: {
                                        Label("New Waypoint", systemImage: "mappin.and.ellipse")
                                    }
                                }
                        }
                    } label: {
                        Label(
                            folder.name,
                            systemImage: folder.id == -1 ? "tray.fill" : "folder.fill"
                        )
                        .fontWeight(.bold)
                        .contextMenu {
                            if folder.id != -1 {
                                Button {
                                    newListPreselectedFolderID = folder.id
                                    showingNewListSheet = true
                                } label: {
                                    Label("New List", systemImage: "list.bullet.rectangle.portrait")
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
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        Group {
            if selectedList != nil {
                List(selection: $selectedItem) {
                    ForEach(viewModel.listItems) { item in
                        Label(item.name, systemImage: item.type.systemImage)
                            .tag(item)
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

    // MARK: - Sort toolbar

    private var sortToolbar: some View {
        HStack(spacing: 4) {
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
                Image(systemName: sortAscending ? "chevron.up.chevron.down" : "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort folders")

            Text(sortColumn == "name" ? "Name" : "Date Created")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

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

// MARK: - Comparable clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Resize cursor

private extension View {
    /// Sets the cursor to a vertical resize arrow on hover.
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
