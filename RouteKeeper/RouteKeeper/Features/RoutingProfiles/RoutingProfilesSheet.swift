//
//  RoutingProfilesSheet.swift
//  RouteKeeper
//
//  Management sheet for routing profiles.  Users can add, rename, delete,
//  and set a default profile, and edit the routing criteria inline.
//

import SwiftUI

struct RoutingProfilesSheet: View {

    @State private var profiles: [RoutingProfile] = []
    @State private var selectedProfileId: Int64? = nil
    /// Tracks the name currently shown in the selected row's TextField.
    @State private var editingName: String = ""
    @State private var showDeleteConfirm = false
    @FocusState private var nameFieldFocused: Bool

    @Environment(\.dismiss) private var dismiss

    // MARK: - Derived

    private var selectedProfile: RoutingProfile? {
        guard let id = selectedProfileId else { return nil }
        return profiles.first { $0.id == id }
    }

    private var canDelete: Bool {
        guard let profile = selectedProfile else { return false }
        return profiles.count > 1 && !profile.isDefault
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Title bar ──────────────────────────────────────────────
            HStack {
                Text("Routing Profiles")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // ── Profile list ───────────────────────────────────────────
            List(selection: $selectedProfileId) {
                ForEach(profiles) { profile in
                    profileRow(for: profile)
                        .tag(profile.id)
                }
            }
            .listStyle(.bordered)
            .frame(height: 180)
            .onChange(of: nameFieldFocused) { _, focused in
                if !focused { commitNameEdit() }
            }
            .onChange(of: selectedProfileId) { oldId, newId in
                // Commit any pending rename for the row being deselected.
                if let id = oldId, let idx = profiles.firstIndex(where: { $0.id == id }) {
                    let trimmed = editingName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed != profiles[idx].name {
                        profiles[idx].name = trimmed
                        let updated = profiles[idx]
                        Task { await save(updated) }
                    }
                }
                // Load the new selection's name into the editing field.
                if let id = newId, let profile = profiles.first(where: { $0.id == id }) {
                    editingName = profile.name
                }
            }

            // ── List toolbar ───────────────────────────────────────────
            HStack(spacing: 0) {
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Add profile")

                Divider().frame(height: 16)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!canDelete)
                .help("Delete selected profile")

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }

            Divider()

            // ── Criteria ───────────────────────────────────────────────
            criteriaSection

            Divider()

            // ── Make Default ───────────────────────────────────────────
            defaultSection
        }
        .frame(width: 420)
        .fixedSize()
        .task {
            await loadProfiles()
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let name = selectedProfile?.name {
                Text("\"\(name)\" will be permanently deleted.")
            }
        }
    }

    // MARK: - Profile row

    @ViewBuilder
    private func profileRow(for profile: RoutingProfile) -> some View {
        HStack {
            if profile.id == selectedProfileId {
                // Selected row: editable TextField for inline rename.
                TextField("Profile name", text: $editingName)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .onSubmit { commitNameEdit() }
            } else {
                Text(profile.name)
            }

            Spacer()

            if profile.isDefault {
                Text("Default")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Criteria section

    @ViewBuilder
    private var criteriaSection: some View {
        if selectedProfile == nil {
            Text("Select a profile to view its criteria.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                criteriaToggle("Avoid motorways",     \.avoidMotorways)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid toll roads",    \.avoidTolls)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid unpaved roads", \.avoidUnpaved)
                Divider().padding(.leading, 16)
                criteriaToggle("Avoid ferries",       \.avoidFerries)
                Divider().padding(.leading, 16)
                routeOptimisationRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func criteriaToggle(
        _ label: String,
        _ keyPath: WritableKeyPath<RoutingProfile, Bool>
    ) -> some View {
        Toggle(label, isOn: toggleBinding(keyPath))
            .toggleStyle(.switch)
            .padding(.vertical, 6)
    }

    /// Segmented picker replacing the shortest_route toggle.
    private var routeOptimisationRow: some View {
        HStack {
            Text("Route optimisation")
            Spacer()
            Picker("", selection: toggleBinding(\.shortestRoute)) {
                Text("Fastest").tag(false)
                Text("Shortest").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Make Default section

    @ViewBuilder
    private var defaultSection: some View {
        Group {
            if let profile = selectedProfile {
                if profile.isDefault {
                    Text("Default Profile")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                } else {
                    Button("Make Default") { setDefault() }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }
            } else {
                Color.clear.frame(height: 36)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Binding helpers

    /// Returns a `Binding<Bool>` for a criteria flag on the selected profile.
    /// Changes are persisted immediately via `saveRoutingProfile`.
    private func toggleBinding(
        _ keyPath: WritableKeyPath<RoutingProfile, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let id = selectedProfileId,
                      let profile = profiles.first(where: { $0.id == id })
                else { return false }
                return profile[keyPath: keyPath]
            },
            set: { newValue in
                guard let id = selectedProfileId,
                      let idx = profiles.firstIndex(where: { $0.id == id })
                else { return }
                profiles[idx][keyPath: keyPath] = newValue
                let updated = profiles[idx]
                Task { await save(updated) }
            }
        )
    }

    // MARK: - Actions

    private func loadProfiles() async {
        do {
            profiles = try await DatabaseManager.shared.fetchRoutingProfiles()
            if selectedProfileId == nil ||
               !profiles.contains(where: { $0.id == selectedProfileId }) {
                let defaultId = profiles.first(where: { $0.isDefault })?.id
                    ?? profiles.first?.id
                selectedProfileId = defaultId
                if let id = defaultId,
                   let profile = profiles.first(where: { $0.id == id }) {
                    editingName = profile.name
                }
            }
        } catch {
            // profiles stays empty
        }
    }

    private func save(_ profile: RoutingProfile) async {
        do {
            try await DatabaseManager.shared.saveRoutingProfile(profile)
            await loadProfiles()
        } catch {
            // A future increment can surface this.
        }
    }

    private func addProfile() {
        Task {
            let name = uniqueNewProfileName()
            let newProfile = RoutingProfile(name: name)
            do {
                try await DatabaseManager.shared.saveRoutingProfile(newProfile)
                await loadProfiles()
                if let inserted = profiles.first(where: { $0.name == name }) {
                    selectedProfileId = inserted.id
                    editingName       = inserted.name
                    // Brief delay so the List row renders before focusing.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    nameFieldFocused  = true
                }
            } catch {
                // Name collision or DB error — no action needed.
            }
        }
    }

    private func deleteSelected() {
        guard let id = selectedProfileId else { return }
        Task {
            do {
                try await DatabaseManager.shared.deleteRoutingProfile(id: id)
                selectedProfileId = nil
                editingName = ""
                await loadProfiles()
            } catch {
                // A future increment can surface this.
            }
        }
    }

    private func setDefault() {
        guard let id = selectedProfileId else { return }
        Task {
            do {
                try await DatabaseManager.shared.setDefaultRoutingProfile(id: id)
                await loadProfiles()
            } catch {
                // A future increment can surface this.
            }
        }
    }

    private func commitNameEdit() {
        guard let id = selectedProfileId,
              let idx = profiles.firstIndex(where: { $0.id == id })
        else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != profiles[idx].name else { return }
        profiles[idx].name = trimmed
        let updated = profiles[idx]
        Task { await save(updated) }
    }

    private func uniqueNewProfileName() -> String {
        let base = "New Profile"
        if !profiles.contains(where: { $0.name == base }) { return base }
        var i = 1
        while profiles.contains(where: { $0.name == "\(base) \(i)" }) { i += 1 }
        return "\(base) \(i)"
    }
}
