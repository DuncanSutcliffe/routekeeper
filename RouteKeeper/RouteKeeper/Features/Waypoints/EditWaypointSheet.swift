//
//  EditWaypointSheet.swift
//  RouteKeeper
//
//  Sheet for editing an existing waypoint.
//
//  On open the sheet pre-populates all fields from the stored waypoint record
//  and ticks the list-assignment checkboxes to match the waypoint's current
//  memberships.  The location chip is shown immediately; the user can clear it
//  to search for a new location via Nominatim.
//

import SwiftUI

struct EditWaypointSheet: View {
    let viewModel: LibraryViewModel
    /// The `items.id` / `waypoints.item_id` of the waypoint being edited.
    let waypointItemId: Int64
    /// Called after a successful save so the caller can reload the sidebar and
    /// refresh the map marker.
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Location state

    /// `true` while the chip is shown (either pre-populated or newly confirmed).
    @State private var isLocationConfirmed: Bool = true
    /// Top-line text shown inside the chip.
    @State private var chipDisplayName: String = ""
    /// Secondary-line text shown inside the chip.
    @State private var chipSubtitle: String = ""
    /// Current coordinates — pre-populated from the stored waypoint; updated
    /// when the user picks a new Nominatim result.
    @State private var confirmedLatitude: Double = 0
    @State private var confirmedLongitude: Double = 0
    /// Elevation in metres — fetched from MapTiler when a new location is
    /// confirmed.  Carries the stored value until the location is changed.
    @State private var confirmedElevation: Double? = nil
    /// Structured address from Nominatim; loaded from the stored record or
    /// refreshed when the user picks a new location.
    @State private var confirmedAddress: AddressData? = nil

    @State private var searchQuery: String = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var isSearching: Bool = false
    @FocusState private var searchFieldFocused: Bool

    // MARK: - Detail state

    @State private var waypointName: String = ""
    @State private var selectedCategoryId: Int64? = nil
    @State private var selectedColorHex: String = "#E8453C"
    @State private var notes: String = ""

    // MARK: - List assignment state

    @State private var selectedListIDs: Set<Int64> = []

    // MARK: - Add-category sheet state

    @State private var showingAddCategorySheet = false
    @State private var addCategoryViewModel = CategoryViewModel()

    // MARK: - Address edit sheet state

    @State private var showingAddressEditSheet = false

    // MARK: - Loading state

    @State private var isLoaded: Bool = false

    // MARK: - Constants

    private let presetColours = waypointPresetColours

    // MARK: - Derived

    private var allLists: [(list: RouteList, folderName: String)] {
        viewModel.folderContents
            .filter { guard let id = $0.folder.id else { return false }; return id != -1 }
            .flatMap { folder, lists in
                lists.map { list in (list: list, folderName: folder.name) }
            }
    }

    private var canSubmit: Bool {
        isLocationConfirmed &&
        !waypointName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedListIDs.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Waypoint")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            if !isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        locationSection
                        detailsSection
                        listsSection
                    }
                    .padding(20)
                }
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
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || !isLoaded)
            }
            .padding(20)
        }
        .frame(width: 460)
        .frame(minHeight: 560)
        .task {
            await loadWaypointData()
        }
        .onAppear {
            viewModel.creationError = nil
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
        .sheet(isPresented: $showingAddressEditSheet) {
            AddressEditSheet(
                initialAddress: confirmedAddress ?? AddressData(),
                onDone: { updated in
                    confirmedAddress = updated
                    Task {
                        try? await DatabaseManager.shared.updateWaypointAddress(
                            itemId: waypointItemId,
                            address: updated
                        )
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

            if isLocationConfirmed {
                // Chip showing the current (stored or newly confirmed) location.
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(waypointName.isEmpty ? chipDisplayName : waypointName)
                            .lineLimit(1)
                        Text(chipSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        isLocationConfirmed = false
                        searchResults = []
                        searchQuery = ""
                        searchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Change location")
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

            addressSummarySection

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
            Label("Lists", systemImage: "list.bullet")
                .font(.subheadline)
                .fontWeight(.semibold)

            if allLists.isEmpty {
                Text("No lists available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(allLists, id: \.list.id) { item in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    item.list.id.map { selectedListIDs.contains($0) } ?? false
                                },
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
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Address summary section

    private var addressSummarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(confirmedAddress?.formattedSummary ?? "No address stored")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Edit Address") { showingAddressEditSheet = true }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
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

    /// Loads the waypoint record and its current list memberships from the database.
    private func loadWaypointData() async {
        await viewModel.loadCategories()
        if let wp = try? await DatabaseManager.shared.fetchWaypointDetails(
            itemId: waypointItemId
        ) {
            confirmedLatitude  = wp.latitude
            confirmedLongitude = wp.longitude
            confirmedElevation = wp.elevation
            chipDisplayName    = wp.name
            chipSubtitle       = String(format: "%.5f, %.5f", wp.latitude, wp.longitude)
            waypointName       = wp.name
            selectedCategoryId = wp.categoryId
            selectedColorHex   = wp.colorHex
            notes              = wp.notes ?? ""
            confirmedAddress   = AddressData(
                houseNumber:   wp.addressHouseNumber,
                road:          wp.addressRoad,
                suburb:        wp.addressSuburb,
                neighbourhood: wp.addressNeighbourhood,
                city:          wp.addressCity,
                municipality:  wp.addressMunicipality,
                county:        wp.addressCounty,
                stateDistrict: wp.addressStateDistrict,
                state:         wp.addressState,
                postcode:      wp.addressPostcode,
                country:       wp.addressCountry,
                countryCode:   wp.addressCountryCode
            )
        }
        if let ids = try? await DatabaseManager.shared.fetchListIds(for: waypointItemId) {
            selectedListIDs = ids
        }
        isLoaded = true
    }

    private func selectResult(_ result: GeocodingResult) {
        confirmedLatitude  = result.latitude
        confirmedLongitude = result.longitude
        confirmedElevation = nil
        chipDisplayName    = result.name
        chipSubtitle       = result.subtitle
        isLocationConfirmed = true
        searchResults      = []
        confirmedAddress   = result.address
        if waypointName.isEmpty {
            waypointName = result.name
        }
        fetchElevation(latitude: result.latitude, longitude: result.longitude)
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
                // Superseded by a newer search.
            } catch {
                searchResults = []
            }
            isSearching = false
        }
    }

    /// Fetches the elevation for the given coordinate from the MapTiler Elevation API.
    ///
    /// Updates `confirmedElevation` on success. Fails silently — elevation is
    /// supplementary and not critical to saving the waypoint.
    private func fetchElevation(latitude: Double, longitude: Double) {
        let key = ConfigService.mapTilerAPIKey
        guard !key.isEmpty else { return }
        let urlStr = "https://api.maptiler.com/elevation/point" +
            "?coordinates=\(longitude),\(latitude)&key=\(key)"
        guard let url = URL(string: urlStr) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let geometry = json["geometry"] as? [String: Any],
                   let coords   = geometry["coordinates"] as? [Any],
                   coords.count >= 3,
                   let elev = coords[2] as? Double {
                    confirmedElevation = elev
                }
            } catch {
                // Fail silently.
            }
        }
    }

    private func submit() {
        let trimmedName = waypointName.trimmingCharacters(in: .whitespaces)
        guard isLocationConfirmed, !trimmedName.isEmpty else { return }
        Task {
            await viewModel.updateWaypoint(
                itemId: waypointItemId,
                name: trimmedName,
                latitude: confirmedLatitude,
                longitude: confirmedLongitude,
                elevation: confirmedElevation,
                categoryId: selectedCategoryId,
                colorHex: selectedColorHex,
                notes: notes.isEmpty ? nil : notes,
                address: confirmedAddress,
                selectedListIds: selectedListIDs
            )
            if viewModel.creationError == nil {
                onSave()
                dismiss()
            }
        }
    }
}

