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
    @State private var startWaypoint: Waypoint? = nil
    @State private var endWaypoint: Waypoint? = nil

    // MARK: - List assignment state

    @State private var selectedListIDs: Set<Int64> = []

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

    /// End-point options exclude whichever waypoint is already selected as start.
    private var endWaypointOptions: [Waypoint] {
        guard let start = startWaypoint else { return viewModel.availableWaypoints }
        return viewModel.availableWaypoints.filter { $0.itemId != start.itemId }
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
            Task { await viewModel.loadAvailableWaypoints() }
        }
        .alert("Route Calculation Failed", isPresented: $showRoutingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Route calculation failed. Please check your internet connection and try again.")
        }
        // If the selected start and end become the same after a waypoint list refresh,
        // clear the end selection.
        .onChange(of: startWaypoint) { _, newStart in
            if let start = newStart, start.itemId == endWaypoint?.itemId {
                endWaypoint = nil
            }
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
                .onChange(of: routeName) { viewModel.creationError = nil }
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
                Picker("Start Point", selection: $startWaypoint) {
                    Text("Select a waypoint…").tag(nil as Waypoint?)
                    ForEach(viewModel.availableWaypoints) { wp in
                        Text(wp.name).tag(wp as Waypoint?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
                Picker("End Point", selection: $endWaypoint) {
                    Text("Select a waypoint…").tag(nil as Waypoint?)
                    ForEach(endWaypointOptions) { wp in
                        Text(wp.name).tag(wp as Waypoint?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(startWaypoint == nil)
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

    private func submit() {
        let trimmedName = routeName.trimmingCharacters(in: .whitespaces)
        guard let start = startWaypoint, let end = endWaypoint, !trimmedName.isEmpty else { return }

        isCalculating = true
        Task {
            do {
                let geojson = try await RoutingService.shared.calculateRoute(
                    from: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude),
                    to:   CLLocationCoordinate2D(latitude: end.latitude,   longitude: end.longitude)
                )
                await viewModel.createRoute(
                    name:          trimmedName,
                    geometry:      geojson,
                    listIds:       Array(selectedListIDs),
                    startWaypoint: start,
                    endWaypoint:   end
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
