//
//  CategoryManagementView.swift
//  RouteKeeper
//
//  Main content of the standalone "Categories" window.
//
//  Displays all categories in alphabetical order.  The twelve built-in
//  (default) categories are read-only; user-created categories have
//  edit and delete controls.  The delete button is disabled — and shows a
//  tooltip — when any waypoints are currently assigned to that category.
//

import SwiftUI

// MARK: - Sheet mode

private enum CategorySheetMode: Identifiable {
    case add
    case edit(Category)

    var id: String {
        switch self {
        case .add:           return "add"
        case .edit(let cat): return "edit-\(cat.id.map(String.init) ?? "?")"
        }
    }
}

// MARK: - CategoryManagementView

struct CategoryManagementView: View {

    @State private var viewModel = CategoryViewModel()
    @State private var sheetMode: CategorySheetMode? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // List
            if viewModel.categories.isEmpty {
                Spacer()
                Text("No categories yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(viewModel.categories) { cat in
                        categoryRow(cat)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer: Add Category button
            HStack {
                Button {
                    sheetMode = .add
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding(12)
                Spacer()
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .task { await viewModel.load() }
        .sheet(item: $sheetMode) { mode in
            switch mode {
            case .add:
                CategoryEditSheet(viewModel: viewModel, editingCategory: nil)
            case .edit(let cat):
                CategoryEditSheet(viewModel: viewModel, editingCategory: cat)
            }
        }
    }

    // MARK: - Row view

    @ViewBuilder
    private func categoryRow(_ cat: Category) -> some View {
        let catId = cat.id ?? 0
        let usageCount = viewModel.usageCounts[catId] ?? 0
        let isInUse = usageCount > 0

        HStack(spacing: 10) {
            // Icon in accent colour
            Image(systemName: cat.iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, alignment: .center)

            // Name — secondary style for default categories
            Text(cat.name)
                .foregroundStyle(cat.isDefault ? .secondary : .primary)

            // Lock badge for default categories
            if cat.isDefault {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Edit / delete controls for user-created categories only
            if !cat.isDefault {
                Button {
                    sheetMode = .edit(cat)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit category")

                Button {
                    Task { await viewModel.deleteCategory(cat) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(isInUse ? .tertiary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isInUse)
                .help(isInUse ? "This category is in use" : "Delete category")
            }
        }
        .padding(.vertical, 4)
    }
}
