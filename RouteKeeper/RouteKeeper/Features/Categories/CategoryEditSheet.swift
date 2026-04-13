//
//  CategoryEditSheet.swift
//  RouteKeeper
//
//  Sheet for adding or editing a user-defined waypoint category.
//  Presented from CategoryManagementView as a sheet.
//
//  - Name field: validated non-empty and unique (case-insensitive).
//  - SF Symbol picker: scrollable grid of 45 curated symbols in eight groups.
//  - Save is disabled until both name and symbol are provided and the name is unique.
//

import SwiftUI

// MARK: - Symbol group model

private struct SymbolGroup {
    let title: String
    let items: [(symbol: String, label: String)]
}

// MARK: - Curated symbol catalogue

private let symbolGroups: [SymbolGroup] = [
    SymbolGroup(title: "Places & Settlements", items: [
        ("house.fill",        "Home"),
        ("briefcase.fill",    "Work"),
        ("building.2.fill",   "City"),
        ("building.fill",     "Town"),
        ("house.lodge.fill",  "Village"),
        ("storefront.fill",   "Shop or dealer"),
    ]),
    SymbolGroup(title: "Culture & Tourism", items: [
        ("photo.artframe",      "Museum"),
        ("camera.fill",         "Tourist attraction"),
        ("star.fill",           "Point of interest"),
        ("ticket.fill",         "Venue"),
        ("theatermasks.fill",   "Theatre"),
        ("books.vertical.fill", "Library"),
    ]),
    SymbolGroup(title: "Food & Drink", items: [
        ("cup.and.saucer.fill", "Café"),
        ("fork.knife",          "Restaurant"),
        ("wineglass.fill",      "Pub or bar"),
        ("cart.fill",           "Supermarket"),
    ]),
    SymbolGroup(title: "Accommodation", items: [
        ("bed.double.fill", "Hotel"),
        ("tent.fill",       "Campsite"),
    ]),
    SymbolGroup(title: "Transport & Navigation", items: [
        ("fuelpump.fill",        "Fuel"),
        ("airplane",             "Airport"),
        ("tram.fill",            "Railway station"),
        ("ferry.fill",           "Ferry"),
        ("parkingsign",          "Parking"),
        ("road.lanes",           "Road point"),
        ("signpost.right.fill",  "Junction"),
    ]),
    SymbolGroup(title: "Outdoors & Nature", items: [
        ("mountain.2.fill",  "Pass"),
        ("binoculars.fill",  "Viewpoint"),
        ("tree.fill",        "Forest or park"),
        ("beach.umbrella",   "Beach"),
        ("snowflake",        "Winter or ski"),
        ("flame.fill",       "Campfire"),
        ("figure.hiking",    "Walking trail"),
        ("bicycle",          "Cycle route"),
    ]),
    SymbolGroup(title: "Services", items: [
        ("wrench.and.screwdriver.fill", "Workshop"),
        ("cross.fill",                  "Hospital"),
        ("pills.fill",                  "Pharmacy"),
        ("banknote.fill",               "Bank or ATM"),
        ("wifi",                        "WiFi"),
        ("phone.fill",                  "Emergency contact"),
    ]),
    SymbolGroup(title: "General", items: [
        ("building.columns.fill", "Landmark"),
        ("mappin",                "Other"),
        ("flag.fill",             "Checkpoint"),
        ("star.circle.fill",      "Favourite"),
        ("map.fill",              "Reference point"),
        ("speedometer",           "Track or road"),
    ]),
]

// MARK: - CategoryEditSheet

struct CategoryEditSheet: View {
    let viewModel: CategoryViewModel
    /// `nil` when adding a new category; non-nil when editing an existing one.
    let editingCategory: Category?
    /// Called with the newly created category immediately before the sheet
    /// dismisses.  Only fires when adding (not editing) and only on success.
    /// `CategoryManagementView` passes `nil`; waypoint sheets supply a closure
    /// that refreshes their category picker and pre-selects the new item.
    var onSave: ((Category) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: Form state

    @State private var name: String = ""
    @State private var selectedSymbol: String? = nil
    @State private var nameError: String? = nil
    @State private var isCheckingName: Bool = false
    @State private var isSaving: Bool = false

    // MARK: Derived

    private var isEditing: Bool { editingCategory != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedSymbol != nil &&
        nameError == nil &&
        !isCheckingName &&
        !isSaving
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text(isEditing ? "Edit Category" : "New Category")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    symbolPickerSection
                }
                .padding(20)
            }

            Divider()

            // Inline error from the view model (e.g. database failure)
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Category") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 480)
        .frame(minHeight: 500)
        .onAppear { prepopulate() }
    }

    // MARK: - Name section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Name", systemImage: "character.cursor.ibeam")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, newValue in
                    nameError = nil
                    checkNameUniqueness(newValue)
                }

            if let err = nameError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Symbol picker section

    private var symbolPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Icon", systemImage: "square.grid.2x2")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(symbolGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    let columns = Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 6
                    )
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(group.items, id: \.symbol) { item in
                            symbolCell(symbol: item.symbol, label: item.label)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func symbolCell(symbol: String, label: String) -> some View {
        let isSelected = selectedSymbol == symbol
        Button {
            selectedSymbol = symbol
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(width: 44, height: 36)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
                    : RoundedRectangle(cornerRadius: 8).fill(.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? .clear : Color(nsColor: .separatorColor),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Private helpers

    private func prepopulate() {
        viewModel.errorMessage = nil
        if let cat = editingCategory {
            name           = cat.name
            selectedSymbol = cat.iconName
        }
    }

    private func checkNameUniqueness(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isCheckingName = true
        Task {
            let taken = await viewModel.isNameTaken(
                trimmed,
                excludingId: editingCategory?.id
            )
            isCheckingName = false
            if taken {
                nameError = "A category with that name already exists."
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let symbol = selectedSymbol else { return }
        isSaving = true
        Task {
            if let existing = editingCategory {
                await viewModel.updateCategory(
                    existing, name: trimmedName, iconName: symbol
                )
            } else {
                let newCat = await viewModel.createCategory(
                    name: trimmedName, iconName: symbol
                )
                // Notify the presenting context (e.g. a waypoint sheet) so it
                // can pre-select the newly created category before dismissing.
                if let cat = newCat {
                    onSave?(cat)
                }
            }
            isSaving = false
            if viewModel.errorMessage == nil {
                dismiss()
            }
        }
    }
}
