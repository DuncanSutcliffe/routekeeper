//
//  NewRouteSheet.swift
//  RouteKeeper
//
//  Sheet for creating a new motorcycle route between two saved waypoints.
//
//  The user names the route, picks start and end waypoints from the library,
//  and optionally assigns the route to one or more lists. On save, the sheet
//  calls Valhalla to calculate the route geometry before writing to the database.
//

import SwiftUI
import CoreLocation

struct NewRouteSheet: View {
    let viewModel: LibraryViewModel
    /// List to pre-check in the list-assignment panel. Pass `nil` for no pre-selection.
    let preselectedListID: Int64?

    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var routeName = ""
    @State private var nameWasManuallyEdited = false
    @State private var lastAutoName = ""
    @State private var startWaypoint: Waypoint? = nil
    @State private var endWaypoint: Waypoint? = nil

    // MARK: - Colour state

    @State private var selectedColorHex = "#1A73E8"

    // MARK: - List assignment state

    @State private var selectedListIDs: Set<Int64> = []

    // MARK: - Routing profile state

    @State private var profiles: [RoutingProfile] = []
    /// The profile whose criteria were last loaded into the fields below.
    @State private var baselineProfile: RoutingProfile? = nil
    /// Stored on the route record; not changed when the user tweaks criteria manually.
    @State private var appliedProfileName: String? = nil
    @State private var avoidMotorways = false
    @State private var avoidTolls     = false
    @State private var avoidUnpaved   = false
    @State private var avoidFerries   = false
    @State private var shortestRoute  = false

    // MARK: - Picker sheet state

    @State private var showingStartPicker = false
    @State private var showingEndPicker   = false

    // MARK: - Async / error state

    @State private var isCalculating = false
    @State private var showRoutingError = false

    // MARK: - Derived

    /// All non-sentinel lists with their parent folder name.
    private var allLists: [(list: RouteList, folderName: String)] {
        viewModel.folderContents
            .filter { guard let id = $0.folder.id else { return false }; return id != -1 }
            .flatMap { folder, lists in
                lists.map { list in (list: list, folderName: folder.name) }
            }
    }

    /// True when the user has manually changed a criterion away from the loaded profile's values.
    private var criteriaModified: Bool {
        guard let base = baselineProfile else { return false }
        return avoidMotorways != base.avoidMotorways ||
               avoidTolls     != base.avoidTolls     ||
               avoidUnpaved   != base.avoidUnpaved   ||
               avoidFerries   != base.avoidFerries   ||
               shortestRoute  != base.shortestRoute
    }

    /// Binding for the profile picker.  Returns nil (the "modified" virtual entry)
    /// when criteria have drifted from the loaded profile; returns the profile id otherwise.
    private var pickerBinding: Binding<Int64?> {
        Binding(
            get: { self.criteriaModified ? nil : self.baselineProfile?.id },
            set: { newId in
                guard let id = newId,
                      let profile = self.profiles.first(where: { $0.id == id })
                else { return }
                self.baselineProfile   = profile
                self.appliedProfileName = profile.name
                self.avoidMotorways    = profile.avoidMotorways
                self.avoidTolls        = profile.avoidTolls
                self.avoidUnpaved      = profile.avoidUnpaved
                self.avoidFerries      = profile.avoidFerries
                self.shortestRoute     = profile.shortestRoute
            }
        )
    }

    private var canSubmit: Bool {
        !routeName.trimmingCharacters(in: .whitespaces).isEmpty &&
        startWaypoint != nil &&
        endWaypoint != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Route")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    startSection
                    endSection
                    colourSection
                    profileSection
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
                    .disabled(isCalculating)
                if isCalculating {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.leading, 4)
                } else {
                    Button("Save") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
            .padding(20)
        }
        .frame(width: 420)
        .frame(minHeight: 480)
        .onAppear {
            viewModel.creationError = nil
            if let listID = preselectedListID {
                selectedListIDs.insert(listID)
            }
            Task {
                await viewModel.loadAvailableWaypoints()
                do {
                    profiles = try await DatabaseManager.shared.fetchRoutingProfiles()
                    if let defaultProfile = try await DatabaseManager.shared.fetchDefaultRoutingProfile() {
                        baselineProfile    = defaultProfile
                        appliedProfileName = defaultProfile.name
                        avoidMotorways     = defaultProfile.avoidMotorways
                        avoidTolls         = defaultProfile.avoidTolls
                        avoidUnpaved       = defaultProfile.avoidUnpaved
                        avoidFerries       = defaultProfile.avoidFerries
                        shortestRoute      = defaultProfile.shortestRoute
                    }
                } catch {
                    // profiles stays empty; section shows disabled picker
                }
            }
        }
        .sheet(isPresented: $showingStartPicker) {
            WaypointPickerSheet(
                onSelect: { summary in
                    startWaypoint = viewModel.availableWaypoints
                        .first { $0.itemId == summary.itemId }
                },
                excludingId: endWaypoint?.itemId,
                title: "Select Start Point"
            )
        }
        .sheet(isPresented: $showingEndPicker) {
            WaypointPickerSheet(
                onSelect: { summary in
                    endWaypoint = viewModel.availableWaypoints
                        .first { $0.itemId == summary.itemId }
                },
                excludingId: startWaypoint?.itemId,
                title: "Select End Point"
            )
        }
        .alert("Route Calculation Failed", isPresented: $showRoutingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Route calculation failed. Please check your internet connection and try again.")
        }
        // If the selected start and end become the same after a waypoint list refresh,
        // clear the end selection; then attempt auto-name with the new pairing.
        .onChange(of: startWaypoint) { _, newStart in
            if let start = newStart, start.itemId == endWaypoint?.itemId {
                endWaypoint = nil
            }
            tryAutoPopulateName()
        }
        .onChange(of: endWaypoint) { _, _ in
            tryAutoPopulateName()
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Route Name", systemImage: "road.lanes")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Route name", text: $routeName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: routeName) { _, newValue in
                    viewModel.creationError = nil
                    // Mark as manually edited only if this change didn't come from
                    // the auto-populate logic (auto-populate keeps lastAutoName in sync).
                    if newValue != lastAutoName {
                        nameWasManuallyEdited = true
                    }
                }
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Start Point", systemImage: "flag.fill")
                .font(.subheadline)
                .fontWeight(.semibold)

            if viewModel.availableWaypoints.isEmpty {
                Text("No waypoints with coordinates found. Create a waypoint first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                waypointPickerRow(
                    placeholder: "Select start point…",
                    selected: startWaypoint,
                    action: { showingStartPicker = true }
                )
            }
        }
    }

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("End Point", systemImage: "flag.checkered")
                .font(.subheadline)
                .fontWeight(.semibold)

            if viewModel.availableWaypoints.isEmpty {
                Text("No waypoints with coordinates found. Create a waypoint first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                waypointPickerRow(
                    placeholder: "Select end point…",
                    selected: endWaypoint,
                    action: { showingEndPicker = true }
                )
            }
        }
    }

    /// A tappable row that displays the selected waypoint name or a placeholder.
    private func waypointPickerRow(
        placeholder: String,
        selected: Waypoint?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if let wp = selected {
                    Text(wp.name)
                        .foregroundStyle(.primary)
                } else {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Routing Profile", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("Routing Profile", selection: pickerBinding) {
                if criteriaModified {
                    Text("\(appliedProfileName ?? "") (modified)").tag(nil as Int64?)
                }
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(profiles.isEmpty)

            VStack(alignment: .leading, spacing: 0) {
                criteriaToggle("Avoid motorways",     isOn: $avoidMotorways)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid toll roads",    isOn: $avoidTolls)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid unpaved roads", isOn: $avoidUnpaved)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid ferries",       isOn: $avoidFerries)
                Divider().padding(.leading, 16)
                routeOptimisationRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func criteriaToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .padding(.vertical, 6)
    }

    private var routeOptimisationRow: some View {
        HStack {
            Text("Route optimisation")
            Spacer()
            Picker("", selection: $shortestRoute) {
                Text("Fastest").tag(false)
                Text("Shortest").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.vertical, 6)
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Colour", systemImage: "paintpalette")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                ForEach(routePresetColours, id: \.self) { hex in
                    ColourSwatch(hex: hex, isSelected: selectedColorHex == hex) {
                        selectedColorHex = hex
                    }
                }
            }
        }
    }

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
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Actions

    /// Auto-populates the route name with "[Start] to [End]" when both waypoints
    /// are selected and the user hasn't manually typed anything.
    ///
    /// Clears the manual-edit flag so subsequent waypoint changes can continue
    /// to update the name automatically, as long as the name still matches the
    /// last auto-generated value or is empty.
    private func tryAutoPopulateName() {
        guard let start = startWaypoint, let end = endWaypoint else { return }
        guard !nameWasManuallyEdited || routeName.isEmpty || routeName == lastAutoName
        else { return }
        let candidate = "\(start.name) to \(end.name)"
        lastAutoName = candidate
        routeName = candidate
        // The onChange(of: routeName) will see newValue == lastAutoName and will
        // NOT set nameWasManuallyEdited, so auto-populate remains active.
    }

    private func submit() {
        let trimmedName = routeName.trimmingCharacters(in: .whitespaces)
        guard let start = startWaypoint, let end = endWaypoint, !trimmedName.isEmpty else { return }

        isCalculating = true
        Task {
            do {
                let result = try await RoutingService.shared.calculateRoute(
                    through: [
                        CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude),
                        CLLocationCoordinate2D(latitude: end.latitude,   longitude: end.longitude)
                    ],
                    avoidMotorways: avoidMotorways,
                    avoidTolls:     avoidTolls,
                    avoidUnpaved:   avoidUnpaved,
                    avoidFerries:   avoidFerries,
                    shortestRoute:  shortestRoute
                )
                await viewModel.createRoute(
                    name:               trimmedName,
                    geometry:           result.geometry,
                    distanceKm:         result.distanceKm,
                    durationSeconds:    result.durationSeconds,
                    listIds:            Array(selectedListIDs),
                    startWaypoint:      start,
                    endWaypoint:        end,
                    appliedProfileName: appliedProfileName,
                    avoidMotorways:     avoidMotorways,
                    avoidTolls:         avoidTolls,
                    avoidUnpaved:       avoidUnpaved,
                    avoidFerries:       avoidFerries,
                    shortestRoute:      shortestRoute,
                    colorHex:           selectedColorHex,
                    elevationProfile:   result.elevationProfile
                )
                if viewModel.creationError == nil {
                    dismiss()
                }
            } catch {
                showRoutingError = true
            }
            isCalculating = false
        }
    }
}

#Preview {
    NewRouteSheet(viewModel: LibraryViewModel(), preselectedListID: nil)
}
