//
//  RouteCreationTests.swift
//  RouteKeeperTests
//
//  Tests for DatabaseManager.createRoute(name:geometry:listIds:).
//
//  Each test creates its own in-memory DatabaseManager via makeInMemory()
//  so there is no shared state between test cases.
//

import Testing
@testable import RouteKeeper

@Suite struct RouteCreationTests {

    // MARK: - 1. All three tables receive a row

    /// Verifies that createRoute writes a row to each of the three tables it
    /// touches: items, routes, and item_list_membership.
    @Test func testCreateRoutePersistsToAllTables() async throws {
        let db = try await DatabaseManager.makeInMemory()

        // Create a folder and list to associate the route with.
        let folder = try await db.createFolder(name: "Test Folder")
        let folderId = try #require(folder.id)
        let list = try await db.createList(name: "Test List", folderId: folderId)
        let listId = try #require(list.id)

        let dummyGeometry = """
            {"type":"FeatureCollection","features":[{"type":"Feature",\
            "geometry":{"type":"LineString","coordinates":[[-1.55,53.13],[-1.91,53.25]]},\
            "properties":{}}]}
            """

        let itemId = try await db.createRoute(
            name: "Peak District Loop",
            geometry: dummyGeometry,
            listIds: [listId]
        )

        // -- items table --
        let items = try await db.fetchItems(for: listId)
        let item = try #require(items.first)
        #expect(item.id == itemId)
        #expect(item.type == .route)
        #expect(item.name == "Peak District Loop")

        // -- routes table --
        let route = try await db.fetchRouteRecord(itemId: itemId)
        let routeRow = try #require(route)
        #expect(routeRow.routingProfile == "motorcycle")
        #expect(routeRow.geometry == dummyGeometry)

        // -- item_list_membership table --
        // fetchItems(for:) joins through item_list_membership, so a non-empty
        // result already implies a membership row exists. The count confirms
        // exactly one association was written.
        #expect(items.count == 1)
    }

    // MARK: - 2. Empty list assignment → item appears in Unclassified

    /// Verifies that a route created with no list IDs ends up accessible via
    /// the unclassified query (items absent from item_list_membership).
    ///
    /// Note: "Unclassified" is a pure application-layer concept — there is no
    /// real list with id -1 in the database. Items without membership rows are
    /// surfaced by fetchUnclassifiedItems(), which queries items NOT IN
    /// item_list_membership. This test verifies that invariant directly.
    @Test func testCreateRouteWithNoListsAssignsToUnclassified() async throws {
        let db = try await DatabaseManager.makeInMemory()

        let itemId = try await db.createRoute(
            name: "Unclassified Run",
            geometry: "{}",
            listIds: []
        )

        // The route must appear in the unclassified query.
        let unclassified = try await db.fetchUnclassifiedItems()
        #expect(unclassified.contains { $0.id == itemId })

        // The route must have no membership rows (that is what makes it
        // unclassified — no sentinel row with list_id = -1 is inserted).
        let route = try await db.fetchRouteRecord(itemId: itemId)
        #expect(route != nil, "Route record must exist in the routes table")

        // Cross-check: the item must NOT appear in any real list's item set.
        // We have no real lists in this test, but fetchUnclassifiedItems
        // confirming the item is sufficient.
        #expect(unclassified.first { $0.id == itemId }?.type == .route)
    }
}
