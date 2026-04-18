# RouteKeeper — Claude Code Project Brief

## What This Project Is

RouteKeeper is a macOS application for planning and managing motorcycle
routes. It is an open-source alternative to Garmin Basecamp — a desktop
tool Garmin has abandoned but which introduced library management concepts
no other software has replicated.

Mac-only, targeting macOS 14+ on Apple Silicon. Written in Swift,
distributed under GPL v3.

## The Developer

The lead developer is a database professional, not a general software
developer. He has strong SQL and data modelling skills and can review the
database layer directly. For Swift, SwiftUI, and the map layer he is
relying on Claude Code — explanations of non-database code should be
clear and not assume prior Swift knowledge.

Always discuss schema changes before implementing them. Prefer explicit
SQL via GRDB over the higher-level query interface.

## Tech Stack

- **Language:** Swift (Swift 6, strict concurrency)
- **UI:** SwiftUI, macOS target only — no iOS
- **Map:** MapLibre GL JS embedded in a WKWebView
- **Database:** SQLite via GRDB.swift
- **Routing:** Valhalla API (hosted, HTTPS) — motorcycle costing model
- **Geocoding:** Nominatim (forward and reverse)
- **Elevation:** MapTiler Elevation API
- **GPX:** XMLCoder for import and export
- **Package manager:** Swift Package Manager (no CocoaPods)

## Architecture

MVVM throughout. Four layers:

1. **Database** — SQLite via GRDB. All persistent data. Independent of UI.
2. **Map** — MapLibre GL JS in WKWebView. Swift ↔ JS via
   WKScriptMessageHandler and `window.webkit.messageHandlers`.
3. **Routing** — Valhalla API over HTTPS. Results stored as GeoJSON.
4. **UI** — SwiftUI for all native panels, sidebar, and chrome.

## Library Management — Core Concept

The most important feature. The data model supports:

- Items (routes, waypoints, tracks) stored once in the database
- Lists — named collections of items
- List folders — hierarchical organisation of lists
- Many-to-many membership via `item_list_membership` junction table;
  one item can belong to multiple lists without duplication
- Unclassified — items with no list membership accessible via a sentinel
  folder/list with `id == -1`, implemented entirely in the application layer

## GPX Compatibility

- Import GPX files (routes, tracks, waypoints)
- Export any item or list as GPX — three formats: Standard GPX 1.1,
  Garmin GPX 1.1, Beeline
- Garmin Zumo (XT, XT2) compatibility; routes include `gpxx:rpt`
  extension data so the device follows the planned route exactly
- Via points announce arrival (shown as flags on device); shaping points
  are silent routing constraints only

## Database Schema

Managed via GRDB `DatabaseMigrator`. Migrations `"v1"` through `"v6"`.
Database file lives in Application Support.

**`items`** — one row per route, waypoint, or track.
`id`, `name` (UNIQUE), `type` (`"waypoint"` | `"route"` | `"track"`),
`created_at`

**`waypoints`** — satellite to `items`. `item_id` is PK and FK →
`items.id ON DELETE CASCADE`.
`item_id`, `name`, `latitude`, `longitude`,
`category_id` (nullable FK → `categories.id` ON DELETE SET NULL),
`color_hex` (default `#E8453C`), `notes`, `elevation` (REAL nullable),
`created_at`,
`address_house_number`, `address_road`, `address_suburb`,
`address_neighbourhood`, `address_city`, `address_town`,
`address_village`, `address_municipality`, `address_county`,
`address_state_district`, `address_state`, `address_postcode`,
`address_country`, `address_country_code` (all nullable TEXT)

**`routes`** — satellite to `items`. `item_id` is PK and FK →
`items.id ON DELETE CASCADE`.
`item_id`, `geometry` (TEXT nullable — GeoJSON FeatureCollection from
Valhalla), `distance_km` (REAL nullable), `duration_seconds` (INTEGER
nullable), `elevation_profile` (TEXT nullable — JSON array of metres,
one sample per 30 m), `notes` (TEXT nullable),
`routing_profile_id` (nullable FK → `routing_profiles.id`),
`color_hex` (TEXT NOT NULL default `#1A73E8`),
`needs_recalculation` (INTEGER NOT NULL default 0),
`avoid_motorways`, `avoid_tolls`, `avoid_unpaved`, `avoid_ferries`,
`shortest_route` (all INTEGER NOT NULL default 0),
`applied_profile_name` (TEXT nullable)

**`route_points`** — ordered waypoints for a route.
`id` (autoincrement), `route_item_id` (FK → `routes.item_id` ON DELETE
CASCADE), `sequence_number`, `latitude`, `longitude`,
`elevation` (REAL nullable), `announces_arrival` (INTEGER default 0),
`name`, `waypoint_item_id` (nullable FK → `waypoints.item_id`
ON DELETE SET NULL),
UNIQUE(`route_item_id`, `sequence_number`)

**`list_folders`** — `id`, `name` (UNIQUE), `sort_order`, `created_at`

**`lists`** — `id`, `folder_id` (FK → `list_folders.id`), `name`,
UNIQUE(`name`, `folder_id`), `sort_order`, `created_at`

**`item_list_membership`** — junction.
`item_id` (FK → `items.id`), `list_id` (FK → `lists.id`),
PRIMARY KEY (`item_id`, `list_id`)

**`categories`** — waypoint POI types.
`id`, `name`, `icon_name` (SF Symbol name),
`is_default` (INTEGER NOT NULL default 0). Seeded with 12 defaults.

**`routing_profiles`** — named Valhalla costing option sets.
`id`, `name`, `use_highways` (REAL), `use_tolls` (REAL),
`use_trails` (REAL), `is_default` (INTEGER)

**`app_settings`** — key/value store for user preferences.
`key` (PK), `value`

## Map Bridge

- JS → Swift: `window.webkit.messageHandlers.routekeeper.postMessage({type, ...})`
- Swift → JS: `webView.evaluateJavaScript("functionName(args)")`

Message types Swift receives: `mapReady`, `routeDrawn`, `mapStyleLoaded`,
`addWaypointAtCoordinate`, `waypointDragged`, `waypointMoved`,
`insertShapingPoint`, `debugLog`

Key JS functions called from Swift:
- `showWaypoint(lat, lng, colorHex, itemId, name, iconBase64)` — single waypoint marker + label
- `clearWaypoint()` — removes waypoint marker and label
- `showRoute(geojson, viaWaypoints, shapingWaypoints, lineColour, name, routeIconBase64, startSeq, endSeq)` — draws route line, markers, label
- `clearRoute()` — removes route line, markers, labels
- `showMultipleItems(itemsJson)` — renders multiple waypoints/routes, fits bounds
- `clearMultipleItems()` — removes all multi-display layers
- `showLabel(itemId, lng, lat, name, iconBase64)` / `hideLabel(itemId)` / `hideAllLabels()`
- `setMapStyle(styleName)`, `setScaleUnits(unit)`
- `registerCategoryIcons(iconsJson)` — registers base64 SF Symbol PNGs

All route point markers (start, end, via, shaping) use native
`maplibregl.Marker` instances. Marker drags require the Option key to be
held — captured at `dragstart`, checked at `dragend`. `routePointCoords`
is a module-level JS array of the actual user-defined route points (not
dense Valhalla-interpolated coords), populated by `showRoute` and used
for the rubber-band drag preview and `findNearestSegment`.

## Map Drag / Undo

Option+drag on a route marker repositions it; Option+click+drag on the
route line inserts a new shaping point via a rubber-band preview.
All drag operations push an `UndoRecord` onto `MapViewModel.undoStack`
(capped at depth 1 via `undoStackMaxDepth`). Edit > Undo (Cmd+Z) in the
menu bar reverses the last operation: `movedPoint` restores previous
coordinates; `insertedPoint` deletes the inserted point. Both paths
recalculate via Valhalla and redraw. Drags without Option held snap back
silently without posting to Swift.

## File Structure

```
RouteKeeper/
├── RouteKeeper.xcodeproj
├── RouteKeeper/
│   ├── RouteKeeperApp.swift
│   ├── ContentView.swift
│   ├── Database/
│   │   └── DatabaseManager.swift
│   ├── Features/
│   │   ├── Categories/
│   │   │   ├── CategoryEditSheet.swift
│   │   │   ├── CategoryManagementView.swift
│   │   │   └── CategoryViewModel.swift
│   │   ├── GPX/
│   │   │   ├── ExportFormatSheet.swift
│   │   │   ├── GPXExporter.swift
│   │   │   ├── GPXImporter.swift
│   │   │   └── GPXImportSheet.swift
│   │   ├── Library/
│   │   │   ├── FolderLabelView.swift
│   │   │   ├── LibraryBottomPanel.swift
│   │   │   ├── LibrarySidebarView.swift
│   │   │   ├── LibraryViewModel.swift
│   │   │   ├── ListRowView.swift
│   │   │   ├── NewFolderSheet.swift
│   │   │   ├── NewListSheet.swift
│   │   │   └── NewWaypointSheet.swift
│   │   ├── Map/
│   │   │   ├── MapStylePicker.swift
│   │   │   ├── MapView.swift
│   │   │   ├── RouteStatsOverlay.swift
│   │   │   └── ShowLabelsButton.swift
│   │   ├── Routes/
│   │   │   ├── NewRouteSheet.swift
│   │   │   ├── RouteEditSheet.swift
│   │   │   ├── RoutePropertiesSheet.swift
│   │   │   ├── RouteWaypointSheet.swift
│   │   │   └── WaypointPickerSheet.swift
│   │   ├── Routing/
│   │   │   └── RoutingService.swift
│   │   ├── RoutingProfiles/
│   │   │   └── RoutingProfilesSheet.swift
│   │   ├── Settings/
│   │   │   ├── APIKeysSettingsView.swift
│   │   │   ├── ExportSettingsView.swift
│   │   │   └── GeneralSettingsView.swift
│   │   └── Waypoints/
│   │       ├── AddressEditSheet.swift
│   │       └── EditWaypointSheet.swift
│   ├── Managers/
│   │   └── PreferencesManager.swift
│   ├── Models/
│   │   ├── ItemRecords.swift
│   │   ├── LibraryRecords.swift
│   │   ├── RoutingProfileRecords.swift
│   │   ├── SystemFolders.swift
│   │   └── WaypointRecords.swift
│   ├── Services/
│   │   ├── APIKeysManager.swift
│   │   ├── ConfigService.swift
│   │   ├── GeocodingService.swift
│   │   ├── KeychainManager.swift
│   │   └── What3WordsService.swift
│   ├── Shared/
│   │   └── ColourSwatch.swift
│   └── Resources/
│       ├── MapLibreMap.html
│       └── Config.plist  ← excluded from git, holds MapTilerAPIKey
├── RouteKeeperTests/
├── CLAUDE.md
├── README.md
├── LICENSE
└── .gitignore
```

## Code Style

- String literals must stay on a single line or be broken explicitly with
  `+`. Never let a literal wrap — this inserts a literal newline and
  causes a build error.
- Use `@Observable`, not `ObservableObject`.
- Swift concurrency (async/await, actors) throughout — no callbacks.
- No force unwrapping (`!`) in production code.
- All public API must have documentation comments.
- No third-party dependencies beyond the tech stack without discussion.

## Critical Rules

- **NEVER modify `.xcodeproj` or `.pbxproj` files.** Create Swift files
  only and tell the developer which files were created so he can add them
  to the Xcode target manually.
- Do not suggest Core Data — GRDB is the persistence layer.
- Do not suggest Electron, Tauri, or any web-based shell — this is native SwiftUI.
- Do not suggest MapKit — MapLibre GL JS in WKWebView is the map renderer.

## Current Status

Increments 1–44 complete. The application has a full working shell with:
library sidebar (folders, lists, drag-and-drop, inline rename/edit),
waypoint creation and editing (coordinate pick, reverse geocode, category
icons, address storage and editing, elevation capture), route creation
(waypoint picker, Valhalla routing, costing criteria, named routing
profiles, colour picker, intermediate via and shaping points, elevation
profile chart), GPX export (Standard, Garmin, Beeline formats), GPX
import (waypoints and routes from .gpx/.xml files, Garmin shaping-point
detection, duplicate-name deduplication, deferred Valhalla geometry,
list picker with inline new-list creation, File menu and list context
menu entry points), live MapLibre map (Streets/Satellite/Topo style
switcher, scale bar, context menu "add waypoint here"), multi-select and
list-selection map display with labels toggle, draggable route and
waypoint markers with live Valhalla recalculation, rubber-band shaping
point insertion via Option+drag on the route line, stack-based undo
(Cmd+Z) for all drag operations, and a native Settings window (units,
export format, API keys via Keychain).

**Known issues / deferred:**
- Valhalla uses the public OSM community instance — rate-limited.
  To be replaced before release.
- Route direction arrows were attempted and fully reverted. To be
  revisited using an SDF image approach.

**Next step: Increment 45 — TBD.**
