//
//  LibrarySidebarView.swift
//  RouteKeeper
//
//  The root of the sidebar is a List with .listStyle(.sidebar) — macOS
//  applies the title-bar safe-area inset automatically for this pattern.
//  The items panel is attached as a .safeAreaInset(edge: .bottom) so the
//  List scrolls above it.  A draggable divider lets the user resize the
//  two panels.
//
//  The sort control and new-item buttons live in a control strip that is
//  the first row of the List (no .tag, so it is not selectable).
//

import SwiftUI

struct LibrarySidebarView: View {
    let viewModel: LibraryViewModel
    @Binding var selectedList: RouteList?
    @Binding var selectedItem: Item?

    // Sort preference — persisted across launches.
    @AppStorage("library.sortColumn")        private var sortColumn: String    = "name"
    @AppStorage("library.sortAscending")     private var sortAscending: Bool   = true

    // Height of the bottom (items) panel in points — persisted.
    @AppStorage("library.bottomPanelHeight") private var bottomPanelHeight: Double = 200

    // Drag state — not persisted; initialised from bottomPanelHeight on appear.
    @State private var isDragging      = false
    @State private var dragStartHeight: CGFloat = 200

    @State private var showingNewFolderSheet   = false
    @State private var showingNewListSheet     = false
    @State private var newListPreselectedFolderID: Int64?

    @State private var showingNewWaypointSheet = false
    @State private var newWaypointPreselectedListID: Int64?

    @State private var showingNewRouteSheet    = false
    @State private var newRoutePreselectedListID: Int64?

    private let dividerHeight:  CGFloat = 8
    private let minPanelHeight: CGFloat = 80
    private let maxPanelHeight: CGFloat = 600

    var body: some View {
        List(selection: $selectedList) {
            // ── Control strip ──────────────────────────────────────────
            // No .tag() → not selectable; transparent background so it
            // reads as a toolbar strip rather than a list row.
            controlStrip
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            // ── Folder / list hierarchy ────────────────────────────────
            ForEach(viewModel.folderContents, id: \.folder.id) { folder, lists in
                DisclosureGroup(isExpanded: expansionBinding(for: folder)) {
                    ForEach(lists) { list in
                        Label(list.name, systemImage: "map")
                            .tag(list)
                            .contextMenu {
                                Button {
                                    newRoutePreselectedListID = list.id
                                    showingNewRouteSheet = true
                                } label: {
                                    Label("New Route", systemImage: "road.lanes")
                                }
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
        // Items panel pinned to the bottom; the List adjusts its own
        // scroll-content inset automatically to stay above this area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Draggable divider — dragging up enlarges the items panel.
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
                                // Negative translation (drag up) → panel grows.
                                let proposed = dragStartHeight - value.translation.height
                                bottomPanelHeight = Double(
                                    min(max(proposed, minPanelHeight), maxPanelHeight)
                                )
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .cursor(.resizeUpDown)

                bottomPanel
                    .frame(height: CGFloat(bottomPanelHeight))
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showingNewFolderSheet) {
            NewFolderSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingNewListSheet) {
            NewListSheet(viewModel: viewModel, preselectedFolderID: newListPreselectedFolderID)
        }
        .sheet(isPresented: $showingNewWaypointSheet) {
            NewWaypointSheet(viewModel: viewModel, preselectedListID: newWaypointPreselectedListID)
        }
        .sheet(isPresented: $showingNewRouteSheet) {
            NewRouteSheet(viewModel: viewModel, preselectedListID: newRoutePreselectedListID)
        }
        .focusedValue(\.showNewFolderSheet,   $showingNewFolderSheet)
        .focusedValue(\.showNewListSheet,     $showingNewListSheet)
        .focusedValue(\.showNewWaypointSheet, $showingNewWaypointSheet)
        .focusedValue(\.showNewRouteSheet,    $showingNewRouteSheet)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
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
        .onChange(of: sortColumn)    { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        .onChange(of: sortAscending) { _, _ in
            Task { await viewModel.load(sortColumn: sortColumn, ascending: sortAscending) }
        }
        .onAppear {
            dragStartHeight = CGFloat(bottomPanelHeight)
            if let list = selectedList {
                Task { await viewModel.loadItems(for: list) }
            }
        }
    }

    // MARK: - Control strip

    /// Sort menu on the left; new-item buttons on the right.
    /// Placed as the first List row with no .tag so it is never selectable.
    private var controlStrip: some View {
        HStack(spacing: 16) {
            // Sort menu
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

            // New Folder (outermost container — leftmost)
            Button {
                showingNewFolderSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New folder")

            // New List
            Button {
                newListPreselectedFolderID = nil
                showingNewListSheet = true
            } label: {
                Image(systemName: "rectangle.badge.plus")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New list")

            // New Waypoint
            Button {
                newWaypointPreselectedListID = nil
                showingNewWaypointSheet = true
            } label: {
                Image(systemName: "mappin.and.ellipse")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New waypoint")

            // New Route (leaf item — rightmost)
            Button {
                newRoutePreselectedListID = nil
                showingNewRouteSheet = true
            } label: {
                Image(systemName: "road.lanes")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .help("New route")
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        Group {
            if selectedList != nil {
                List(selection: $selectedItem) {
                    ForEach(viewModel.listItems) { item in
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(systemName: item.type.systemImage)
                                .foregroundStyle(iconColor(for: item))
                        }
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

    // MARK: - Helpers

    /// Returns the colour to apply to `item`'s sidebar icon.
    ///
    /// Waypoints carry a `colour` hex string populated from `waypoints.color_hex`
    /// by the fetch query.  Routes and tracks have no colour yet, so they fall
    /// back to `.secondary`.
    private func iconColor(for item: Item) -> Color {
        if let hex = item.colour, !hex.isEmpty {
            return Color(itemHex: hex)
        }
        return .secondary
    }

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

// MARK: - Color from hex string

private extension Color {
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

private extension View {
    /// Pushes a vertical-resize cursor while the pointer is over this view.
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
