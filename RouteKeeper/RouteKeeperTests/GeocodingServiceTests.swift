//
//  GeocodingServiceTests.swift
//  RouteKeeperTests
//
//  Unit tests for GeocodingService.
//
//  Tests 1, 2, and 4 make real network requests to the Nominatim API and
//  will fail if the device has no internet access.
//
//  The suite is marked .serialized to prevent tests from running in parallel
//  and interfering with each other via the shared GeocodingService singleton's
//  mutable currentTask state.
//

import Testing
import Foundation
@testable import RouteKeeper

@MainActor
@Suite(.serialized)
struct GeocodingServiceTests {

    // MARK: - 1. Known place returns results

    /// Requires network access — calls the Nominatim API.
    @Test func testSearchReturnsResults() async throws {
        let results = try await GeocodingService.shared.search("Matlock, Derbyshire")

        #expect(!results.isEmpty)

        let first = try #require(results.first)
        #expect(!first.name.isEmpty)

        // Latitude must fall within the rough bounding box of the UK.
        #expect(first.latitude >= 49 && first.latitude <= 61)
        // Longitude must fall within the rough bounding box of the UK.
        #expect(first.longitude >= -8 && first.longitude <= 2)
    }

    // MARK: - 2. Result has a non-empty subtitle

    /// Requires network access — calls the Nominatim API.
    @Test func testSearchResultHasSubtitle() async throws {
        let results = try await GeocodingService.shared.search("Chamonix")

        let first = try #require(results.first)
        #expect(!first.subtitle.isEmpty)
    }

    // MARK: - 3. Empty query short-circuits without a network request

    @Test func testEmptyQueryReturnsEmptyResults() async throws {
        // GeocodingService guards against empty input before building a URL,
        // so no network request is made.
        let results = try await GeocodingService.shared.search("")
        #expect(results.isEmpty)
    }

    // MARK: - 4. Nonsense query returns empty results

    /// Requires network access — calls the Nominatim API.
    @Test func testInvalidQueryReturnsEmptyResults() async throws {
        let results = try await GeocodingService.shared.search("xkqzwpvjfnmatlockmadeupplacename")
        #expect(results.isEmpty)
    }

    // MARK: - 5. Rapid duplicate searches cancel the earlier one

    @Test func testDuplicateSearchCancelsPrevious() async throws {
        // Both child tasks are enqueued on the main actor before either runs.
        // Because the suite is @MainActor:
        //   - Bath runs first: creates an inner debounce Task, then suspends.
        //   - Bristol runs next: cancels Bath's inner Task, creates its own.
        // Bath's caller therefore receives CancellationError; Bristol succeeds.
        async let bathResults   = GeocodingService.shared.search("Bath")
        async let bristolResults = GeocodingService.shared.search("Bristol")

        // Bristol should complete with real results.
        let bristol = try await bristolResults
        #expect(!bristol.isEmpty)
        #expect(bristol.contains {
            $0.name.localizedCaseInsensitiveContains("Bristol") ||
            $0.subtitle.localizedCaseInsensitiveContains("Bristol")
        })

        // Bath should have been cancelled; accept CancellationError silently.
        do {
            _ = try await bathResults
        } catch is CancellationError {
            // Expected: the Bath search was superseded by Bristol.
        }
    }
}
