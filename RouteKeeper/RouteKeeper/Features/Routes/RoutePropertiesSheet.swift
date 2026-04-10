//
//  RoutePropertiesSheet.swift
//  RouteKeeper
//
//  Sheet for editing a route's name and routing criteria.
//  The "Edit Route Waypoints" button presents RouteWaypointSheet on top;
//  closing that returns the user here automatically.
//

import SwiftUI
import CoreLocation

struct RoutePropertiesSheet: View {
    let routeItemId: Int64
    let initialName: String
    /// Called after a successful save so the parent can refresh the sidebar.
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Waypoint editor state

    @State private var showingWaypointEditor = false

    // MARK: - Form state

    @State private var routeName: String = ""

    // MARK: - Routing profile state

    @State private var profiles: [RoutingProfile] = []
    @State private var baselineProfile: RoutingProfile? = nil
    @State private var appliedProfileName: String? = nil
    @State private var avoidMotorways = false
    @State private var avoidTolls     = false
    @State private var avoidUnpaved   = false
    @State private var avoidFerries   = false
    @State private var shortestRoute  = false

    // MARK: - Original values (snapshot on appear for change detection)

    @State private var originalAvoidMotorways = false
    @State private var originalAvoidTolls     = false
    @State private var originalAvoidUnpaved   = false
    @State private var originalAvoidFerries   = false
    @State private var originalShortestRoute  = false

    // MARK: - Async / error state

    @State private var isSaving = false
    @State private var isRecalculating = false
    @State private var showSaveError = false
    @State private var showRecalcFailAlert = false

    // MARK: - Derived

    private var routingCriteriaChanged: Bool {
        avoidMotorways != originalAvoidMotorways ||
        avoidTolls     != originalAvoidTolls     ||
        avoidUnpaved   != originalAvoidUnpaved   ||
        avoidFerries   != originalAvoidFerries   ||
        shortestRoute  != originalShortestRoute
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
                self.baselineProfile    = profile
                self.appliedProfileName = profile.name
                self.avoidMotorways     = profile.avoidMotorways
                self.avoidTolls         = profile.avoidTolls
                self.avoidUnpaved       = profile.avoidUnpaved
                self.avoidFerries       = profile.avoidFerries
                self.shortestRoute      = profile.shortestRoute
            }
        )
    }

    private var canSave: Bool {
        !routeName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isRecalculating {
                // ── Recalculation progress ─────────────────────────────
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Recalculating route…")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 420, height: 200)
            } else {
                // ── Normal sheet content ───────────────────────────────
                VStack(spacing: 0) {

                    // ── Title bar ──────────────────────────────────────
                    HStack {
                        Text("Route Properties")
                            .font(.headline)
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isSaving)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            nameSection
                            profileSection
                        }
                        .padding(20)
                    }

                    Divider()

                    // ── Edit Route Waypoints ───────────────────────────
                    Button("Edit Route Waypoints") {
                        showingWaypointEditor = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)

                    Divider()

                    // ── Save / error footer ────────────────────────────
                    if showSaveError {
                        Text("Save failed. Please try again.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(isSaving)
                        if isSaving {
                            ProgressView()
                                .controlSize(.regular)
                                .padding(.leading, 4)
                        } else {
                            Button("Save") { save() }
                                .disabled(!canSave)
                        }
                    }
                    .padding(20)
                }
                .frame(width: 420)
                .fixedSize()
            }
        }
        .sheet(isPresented: $showingWaypointEditor) {
            RouteWaypointSheet(routeItemId: routeItemId, routeName: routeName) {
                // Waypoint save triggers map refresh in the parent; no extra
                // action needed here — the user is returned to this sheet automatically.
            }
        }
        .alert("Route Calculation Failed", isPresented: $showRecalcFailAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Route recalculation failed. Your route settings have been saved " +
                 "but the route has not been redrawn. You can try recalculating by " +
                 "editing the route again.")
        }
        .onAppear {
            routeName = initialName
            Task { await loadData() }
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
        }
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

    // MARK: - Actions

    private func loadData() async {
        do {
            // Load profiles and the route's stored criteria in parallel.
            async let profilesFetch = DatabaseManager.shared.fetchRoutingProfiles()
            async let routeFetch    = DatabaseManager.shared.fetchRouteRecord(itemId: routeItemId)
            let (fetchedProfiles, route) = try await (profilesFetch, routeFetch)

            profiles = fetchedProfiles

            if let route {
                // Populate criteria from the stored route values.
                avoidMotorways = route.avoidMotorways
                avoidTolls     = route.avoidTolls
                avoidUnpaved   = route.avoidUnpaved
                avoidFerries   = route.avoidFerries
                shortestRoute  = route.shortestRoute
                appliedProfileName = route.appliedProfileName

                // Snapshot originals for change detection.
                originalAvoidMotorways = route.avoidMotorways
                originalAvoidTolls     = route.avoidTolls
                originalAvoidUnpaved   = route.avoidUnpaved
                originalAvoidFerries   = route.avoidFerries
                originalShortestRoute  = route.shortestRoute

                // Pre-select the matching profile as the baseline (if still present).
                if let name = route.appliedProfileName {
                    baselineProfile = profiles.first(where: { $0.name == name })
                }
            }
        } catch {
            // Profiles unavailable; criteria section shows empty picker.
        }
    }

    private func save() {
        let trimmed = routeName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let needsRecalc = routingCriteriaChanged

        isSaving = true
        Task {
            // Step 1: Always persist name, profile name, and all five criteria.
            do {
                try await DatabaseManager.shared.updateRouteProperties(
                    itemId:             routeItemId,
                    name:               trimmed,
                    appliedProfileName: appliedProfileName,
                    avoidMotorways:     avoidMotorways,
                    avoidTolls:         avoidTolls,
                    avoidUnpaved:       avoidUnpaved,
                    avoidFerries:       avoidFerries,
                    shortestRoute:      shortestRoute
                )
            } catch {
                showSaveError = true
                isSaving = false
                return
            }

            // Step 2: Recalculate the route geometry if criteria changed.
            if needsRecalc {
                isRecalculating = true
                do {
                    let points = try await DatabaseManager.shared.fetchRoutePoints(
                        routeItemId: routeItemId
                    )
                    let coords = points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    let geometry = try await RoutingService.shared.calculateRoute(
                        through:        coords,
                        avoidMotorways: avoidMotorways,
                        avoidTolls:     avoidTolls,
                        avoidUnpaved:   avoidUnpaved,
                        avoidFerries:   avoidFerries,
                        shortestRoute:  shortestRoute
                    )
                    try await DatabaseManager.shared.updateRouteGeometry(
                        itemId: routeItemId, geometry: geometry
                    )
                } catch {
                    // Properties are already saved; only geometry update failed.
                    isRecalculating = false
                    isSaving = false
                    showRecalcFailAlert = true
                    return
                }
            }

            onSave()
            dismiss()
        }
    }
}
