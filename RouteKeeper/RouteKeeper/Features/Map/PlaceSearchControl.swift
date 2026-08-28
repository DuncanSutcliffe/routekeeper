//
//  PlaceSearchControl.swift
//  RouteKeeper
//
//  Floating map overlay for searching a place and showing it on the map without
//  creating a waypoint. Display-only — nothing here is ever written to the
//  database. Reuses GeocodingService.shared.search(), the same Nominatim search
//  and debounce logic used by NewWaypointSheet.
//

import SwiftUI

// MARK: - PlaceSearchControl

/// Collapsed: a single square button. Expanded: the button plus a text field and
/// a results list. Selecting a result shows a provisional marker on the map via
/// `MapViewModel.showSearchResult(_:)`; the marker is cleared only on full
/// dismissal (clear button, deleting all text, collapsing, or Escape).
struct PlaceSearchControl: View {
    let mapViewModel: MapViewModel

    @State private var isExpanded = false
    @State private var query = ""
    @State private var resultsState: ResultsState = .hidden
    @State private var selectedResultId: UUID? = nil
    @FocusState private var fieldFocused: Bool

    private let fieldWidth: CGFloat = 280
    private let buttonSize: CGFloat = 32

    private enum ResultsState {
        case hidden
        case loading
        case empty
        case failed
        case found([GeocodingResult])
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if isExpanded {
                    fieldRow
                }
                toggleButton
            }
            if isExpanded, showResultsList {
                resultsListView
                    .frame(width: fieldWidth + 6 + buttonSize)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { fieldFocused = true }
        }
        .onChange(of: query) { oldValue, newValue in
            if newValue.isEmpty {
                if !oldValue.isEmpty {
                    performFullDismissal()
                }
                return
            }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else {
                resultsState = .hidden
                return
            }
            selectedResultId = nil
            performSearch(trimmed)
        }
    }

    // MARK: - Toggle button

    private var toggleButton: some View {
        Button {
            if isExpanded {
                performFullDismissal()
                isExpanded = false
                fieldFocused = false
            } else {
                isExpanded = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .help("Search for a place")
    }

    // MARK: - Search field

    private var fieldRow: some View {
        HStack(spacing: 4) {
            TextField("Search for a place", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onKeyPress(.escape) {
                    performFullDismissal()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    activateSelected()
                    return .handled
                }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    performFullDismissal()
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: fieldWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    // MARK: - Results list

    private var showResultsList: Bool {
        switch resultsState {
        case .hidden, .loading: return false
        case .empty, .failed, .found: return true
        }
    }

    private var isSearching: Bool {
        if case .loading = resultsState { return true }
        return false
    }

    private var currentResults: [GeocodingResult] {
        if case .found(let results) = resultsState { return results }
        return []
    }

    @ViewBuilder
    private var resultsListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch resultsState {
                case .hidden, .loading:
                    EmptyView()
                case .empty:
                    placeholderRow("No places found")
                case .failed:
                    placeholderRow("Search failed")
                case .found(let results):
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result)
                        if index != results.count - 1 {
                            Divider().padding(.leading, 10)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ result: GeocodingResult) -> some View {
        Button {
            selectResult(result)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .lineLimit(1)
                Text(secondaryLine(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                selectedResultId == result.id ? Color.accentColor.opacity(0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
    }

    /// Formats a row's secondary line as `display_name` with the leading `name`
    /// component (and its following comma) stripped, e.g. "Buxton" / "Buxton,
    /// Derbyshire, England". Falls back to `subtitle` if nothing remains.
    private func secondaryLine(for result: GeocodingResult) -> String {
        var remainder = result.displayName
        if remainder.hasPrefix(result.name) {
            remainder = String(remainder.dropFirst(result.name.count))
            if remainder.hasPrefix(",") { remainder = String(remainder.dropFirst()) }
        }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? result.subtitle : remainder
    }

    // MARK: - Selection

    /// Highlights the result and sends it to the map. The list stays open and the
    /// search text is unchanged so the user can compare another result next.
    private func selectResult(_ result: GeocodingResult) {
        selectedResultId = result.id
        mapViewModel.showSearchResult(
            SearchResultDisplay(
                latitude:  result.latitude,
                longitude: result.longitude,
                name:      result.name,
                bounds:    result.bounds
            )
        )
    }

    private func moveSelection(by delta: Int) {
        let results = currentResults
        guard !results.isEmpty else { return }
        let currentIndex = selectedResultId.flatMap { id in results.firstIndex { $0.id == id } }
        let newIndex: Int
        if let currentIndex {
            newIndex = min(max(currentIndex + delta, 0), results.count - 1)
        } else {
            newIndex = delta > 0 ? 0 : results.count - 1
        }
        selectResult(results[newIndex])
    }

    private func activateSelected() {
        guard let id = selectedResultId,
              let result = currentResults.first(where: { $0.id == id }) else { return }
        selectResult(result)
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        resultsState = .loading
        Task {
            do {
                let found = try await GeocodingService.shared.search(query)
                resultsState = found.isEmpty ? .empty : .found(found)
            } catch is CancellationError {
                // Superseded by a newer search — a later call will update state.
            } catch {
                resultsState = .failed
            }
        }
    }

    // MARK: - Dismissal

    /// Clears the search text, clears the results list, and removes the search
    /// result marker from the map. Does not collapse the control — see the
    /// magnifying-glass toggle button for the one trigger that also collapses.
    private func performFullDismissal() {
        query = ""
        resultsState = .hidden
        selectedResultId = nil
        mapViewModel.clearSearchResult()
    }
}

#Preview {
    PlaceSearchControl(mapViewModel: MapViewModel())
        .padding()
}
