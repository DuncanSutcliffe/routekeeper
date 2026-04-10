//
//  RoutingProfileRecords.swift
//  RouteKeeper
//
//  GRDB record type for the routing_profiles table.
//
//  A routing profile captures the set of routing preferences (avoid motorways,
//  tolls, unpaved roads, ferries, or prefer shortest route) that the user wants
//  to apply when calculating a new route.  Exactly one profile has is_default = 1
//  at any time; the others have is_default = 0.
//

import Foundation
import GRDB

// MARK: - RoutingProfile

/// A saved set of routing preferences applied when calculating a motorcycle route.
///
/// The four built-in profiles are seeded on first launch and cannot be deleted
/// through the normal delete path in the initial implementation.  User-created
/// profiles can be added and removed freely.
struct RoutingProfile: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "routing_profiles"

    var id: Int64?
    var name: String
    /// Exactly one profile has this set to `true` at any time.
    var isDefault: Bool
    var avoidMotorways: Bool
    var avoidTolls: Bool
    var avoidUnpaved: Bool
    var avoidFerries: Bool
    var shortestRoute: Bool
    /// Populated by the database on insert; read back when fetched.
    var createdAt: String = ""

    init(
        id: Int64? = nil,
        name: String,
        isDefault: Bool = false,
        avoidMotorways: Bool = false,
        avoidTolls: Bool = false,
        avoidUnpaved: Bool = false,
        avoidFerries: Bool = false,
        shortestRoute: Bool = false
    ) {
        self.id            = id
        self.name          = name
        self.isDefault     = isDefault
        self.avoidMotorways = avoidMotorways
        self.avoidTolls    = avoidTolls
        self.avoidUnpaved  = avoidUnpaved
        self.avoidFerries  = avoidFerries
        self.shortestRoute = shortestRoute
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault      = "is_default"
        case avoidMotorways = "avoid_motorways"
        case avoidTolls     = "avoid_tolls"
        case avoidUnpaved   = "avoid_unpaved"
        case avoidFerries   = "avoid_ferries"
        case shortestRoute  = "shortest_route"
        case createdAt      = "created_at"
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]               = id
        container["name"]             = name
        container["is_default"]       = isDefault ? 1 : 0
        container["avoid_motorways"]  = avoidMotorways ? 1 : 0
        container["avoid_tolls"]      = avoidTolls ? 1 : 0
        container["avoid_unpaved"]    = avoidUnpaved ? 1 : 0
        container["avoid_ferries"]    = avoidFerries ? 1 : 0
        container["shortest_route"]   = shortestRoute ? 1 : 0
        // created_at omitted — database provides default.
    }

    // MARK: Hashable — identity based on id only

    static func == (lhs: RoutingProfile, rhs: RoutingProfile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
