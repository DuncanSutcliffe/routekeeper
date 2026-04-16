//
//  NewWaypointSheet.swift
//  RouteKeeper
//
//  Sheet for creating a new favourite waypoint.
//
//  The user searches for a place using the Nominatim geocoding service,
//  picks a result to set the coordinates, fills in a name, category, colour,
//  and optional notes, then optionally assigns the waypoint to one or more lists.
//

import SwiftUI

// MARK: - NewWaypointSheet

struct NewWaypointSheet: View {
    let viewModel: LibraryViewModel
    /// List to pre-check in the list-assignment panel. Pass `nil` for no pre-selection.
    let preselectedListID: Int64?
    /// When non-nil the sheet opens with the location already confirmed at this
    /// coordinate (from a map right-click), skipping the search step entirely.
    var prefilledCoordinate: MapCoordinate? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(APIKeysManager.self) private var apiKeysManager

    // MARK: Location search state

    @State private var searchQuery = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var selectedLocation: GeocodingResult?
    @State private var isSearching = false
    @FocusState private var searchFieldFocused: Bool

    /// Elevation in metres fetched from MapTiler after a location is confirmed.
    /// `nil` if the fetch failed or has not yet completed — stored silently.
    @State private var confirmedElevation: Double? = nil

    // MARK: Waypoint detail state

    @State private var waypointName = ""
    @State private var selectedCategoryId: Int64? = nil
    @State private var selectedColorHex = "#E8453C"
    @State private var notes = ""

    // MARK: List assignment state

    @State private var selectedListIDs: Set<Int64> = []

    // MARK: Add-category sheet state

    @State private var showingAddCategorySheet = false
    @State private var addCategoryViewModel = CategoryViewModel()

    // MARK: Constants

    private let presetColours = waypointPresetColours

    // MARK: Derived

    /// All non-sentinel lists, flattened from every real folder.
    private var allLists: [(list: RouteList, folderName: String)] {
        viewModel.folderContents
            .filter { guard let id = $0.folder.id else { return false }; return id != -1 }
            .flatMap { folder, lists in
                lists.map { list in (list: list, folderName: folder.name) }
            }
    }

    private var canSubmit: Bool {
        selectedLocation != nil &&
        !waypointName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Waypoint")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    locationSection
                    detailsSection
                    listsSection
                }
                .padding(20)
            }

            Divider()

            if let error = viewModel.creationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Waypoint") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 460)
        .frame(minHeight: 560)
        .onAppear {
            viewModel.creationError = nil
            if let listID = preselectedListID {
                selectedListIDs.insert(listID)
            }
            Task { await viewModel.loadCategories() }

            if let coord = prefilledCoordinate {
                // Confirm the location immediately from the map tap coordinate,
                // showing the chip without requiring a Nominatim search first.
                selectedLocation = GeocodingResult(
                    name: "Map location",
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    subtitle: "Map location"
                )
                fetchElevation(latitude: coord.latitude, longitude: coord.longitude)
                Task {
                    if let result = await GeocodingService.shared.reverseGeocode(
                        latitude: coord.latitude, longitude: coord.longitude
                    ), waypointName.isEmpty {
                        waypointName = result.name
                    }
                }
            } else {
                searchFieldFocused = true
            }
        }
        .sheet(isPresented: $showingAddCategorySheet) {
            CategoryEditSheet(
                viewModel: addCategoryViewModel,
                editingCategory: nil,
                onSave: { newCat in
                    Task { @MainActor in
                        await viewModel.forceReloadCategories()
                        selectedCategoryId = newCat.id
                    }
                }
            )
        }
    }

    // MARK: - Location section

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location", systemImage: "magnifyingglass")
                .font(.subheadline)
                .fontWeight(.semibold)

            if let loc = selectedLocation {
                // Confirmed location — show a summary chip with a clear button.
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waypointName.isEmpty ? loc.name : waypointName)
                            .lineLimit(1)
                        Text(loc.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        selectedLocation = nil
                        searchResults = []
                        searchQuery = ""
                        searchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear location")
                }
                .padding(10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                // Nominatim search field.
                HStack(spacing: 6) {
                    TextField("Search for a place…", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFieldFocused)
                        .onChange(of: searchQuery) { _, query in
                            performSearch(query: query)
                        }
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !searchResults.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(searchResults) { result in
                            Button { selectResult(result) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name)
                                            .lineLimit(1)
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                            }
                            .buttonStyle(.plain)

                            if result.id != searchResults.last?.id {
                                Divider()
                                    .padding(.leading, 10)
                            }
                        }
                    }
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Details", systemImage: "info.circle")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Waypoint name", text: $waypointName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: waypointName) { viewModel.creationError = nil }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                categoryMenu
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Colour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(presetColours, id: \.self) { hex in
                        ColourSwatch(hex: hex, isSelected: selectedColorHex == hex) {
                            selectedColorHex = hex
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .frame(height: 64)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }
        }
    }

    // MARK: - List assignment section

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Add to Lists", systemImage: "list.bullet")
                .font(.subheadline)
                .fontWeight(.semibold)

            if allLists.isEmpty {
                Text("No lists available. Create a list first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(allLists, id: \.list.id) { item in
                            Toggle(
                                isOn: Binding(
                                    get: { item.list.id.map { selectedListIDs.contains($0) } ?? false },
                                    set: { checked in
                                        guard let id = item.list.id else { return }
                                        if checked { selectedListIDs.insert(id) }
                                        else       { selectedListIDs.remove(id) }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.list.name)
                                    Text(item.folderName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)

                            if item.list.id != allLists.last?.list.id {
                                Divider()
                                    .padding(.leading, 10)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Category menu

    /// A `Menu`-style category selector that includes an "Add category…" action
    /// at the bottom, separated from the category list by a `Divider`.
    ///
    /// "Add category…" presents `CategoryEditSheet` directly on top of this
    /// sheet.  The `onSave` callback refreshes the category list and
    /// pre-selects the new item without leaving the waypoint sheet.
    private var categoryMenu: some View {
        let selectedCat = selectedCategoryId.flatMap { id in
            viewModel.categories.first { $0.id == id }
        }
        return Menu {
            Button("None") { selectedCategoryId = nil }
            Divider()
            ForEach(viewModel.categories) { cat in
                Button {
                    selectedCategoryId = cat.id
                } label: {
                    Label(cat.name, systemImage: cat.iconName)
                }
            }
            Divider()
            Button("Add category…") {
                addCategoryViewModel.errorMessage = nil
                showingAddCategorySheet = true
            }
        } label: {
            HStack {
                if let cat = selectedCat {
                    Label(cat.name, systemImage: cat.iconName)
                } else {
                    Text("None")
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: - Private helpers

    private func selectResult(_ result: GeocodingResult) {
        selectedLocation = result
        searchResults = []
        // Pre-fill name from the result title (place's own name or first
        // component of display_name) if the field is still empty.
        if waypointName.isEmpty {
            waypointName = result.name
        }
        fetchElevation(latitude: result.latitude, longitude: result.longitude)
    }

    /// Fetches the elevation for the given coordinate from the MapTiler Elevation API.
    ///
    /// Updates `confirmedElevation` on success. Fails silently on any error
    /// since elevation is supplementary data and not critical to waypoint creation.
    private func fetchElevation(latitude: Double, longitude: Double) {
        let key = apiKeysManager.mapTilerKey
        guard !key.isEmpty else { return }
        let urlStr = "https://api.maptiler.com/elevation/point" +
            "?coordinates=\(longitude),\(latitude)&key=\(key)"
        guard let url = URL(string: urlStr) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let geometry = json["geometry"] as? [String: Any],
                   let coords = geometry["coordinates"] as? [Any],
                   coords.count >= 3,
                   let elev = coords[2] as? Double {
                    confirmedElevation = elev
                }
            } catch {
                // Fail silently — elevation is non-critical.
            }
        }
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        Task {
            do {
                let results = try await GeocodingService.shared.search(trimmed)
                searchResults = results
            } catch is CancellationError {
                // Superseded by a newer search — results will arrive from the later call.
            } catch {
                searchResults = []
            }
            isSearching = false
        }
    }

    private func submit() {
        let trimmedName = waypointName.trimmingCharacters(in: .whitespaces)
        guard let location = selectedLocation, !trimmedName.isEmpty else { return }
        let listIds = Array(selectedListIDs)
        Task {
            await viewModel.createWaypoint(
                name: trimmedName,
                latitude: location.latitude,
                longitude: location.longitude,
                elevation: confirmedElevation,
                categoryId: selectedCategoryId,
                colorHex: selectedColorHex,
                notes: notes.isEmpty ? nil : notes,
                listIds: listIds
            )
            if viewModel.creationError == nil {
                dismiss()
            }
        }
    }
}


#Preview {
    NewWaypointSheet(viewModel: LibraryViewModel(), preselectedListID: nil)
}
