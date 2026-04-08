# RouteKeeper — Claude Code Project Brief

## What This Project Is

RouteKeeper is a macOS application for planning and managing 
motorcycle routes. It's an open-source alternative to Garmin 
Basecamp — a desktop tool that Garmin has abandoned but which 
introduced library management concepts no other software has 
replicated.

The application is Mac-only, targeting macOS 14+ on Apple Silicon.
It is written in Swift and distributed under GPL v3.

## The Developer

The lead developer is a database professional, not a general 
software developer. He has strong SQL and data modelling skills 
and can review and critique the database layer directly. For Swift, 
SwiftUI, and the map layer, he is relying on Claude Code — so 
explanations of non-database code should be clear and not assume 
prior Swift knowledge.

Always discuss schema changes before implementing them. Prefer 
explicit SQL via GRDB over the higher-level query interface where 
it gives more control and transparency.

## Tech Stack

- **Language:** Swift (Swift 6, strict concurrency)
- **UI:** SwiftUI, macOS target only — no iOS
- **Map:** MapLibre GL JS embedded in a WKWebView
- **Database:** SQLite via GRDB.swift
- **Routing:** Valhalla API (hosted, via HTTPS) — motorcycle 
  costing model preferred
- **GPX:** XMLCoder for import and export
- **Package manager:** Swift Package Manager (no CocoaPods)

## Architecture Overview

The application follows MVVM throughout. The layers are:

1. **Database layer** — SQLite via GRDB. All persistent data lives 
   here. Routes, waypoints, tracks, folders, lists, and list 
   membership are stored in a normalised schema. This layer is 
   entirely independent of the UI.

2. **Map layer** — MapLibre GL JS runs inside a WKWebView. Swift 
   communicates with it via WKScriptMessageHandler (Swift → JS) 
   and window.webkit.messageHandlers (JS → Swift). The map 
   receives display instructions from the app; user interactions 
   on the map send events back to Swift.

3. **Routing layer** — Route calculations are made by calling 
   the Valhalla API over HTTPS. Results are returned as GeoJSON 
   and stored in the database. The motorcycle costing profile 
   should be used by default.

4. **UI layer** — SwiftUI for all native panels, sidebar, 
   library browser, and application chrome.

## Library Management — Core Concept

This is the most important feature of the application. The data 
model must support:

- Items (routes, waypoints, tracks) stored once in the database
- Lists, which are named collections of items
- List folders, which organise lists hierarchically
- Many-to-many membership: a single item can belong to multiple 
  lists simultaneously without duplication
- Smart lists: automatically populated by rules (e.g. all routes 
  created this month, all waypoints of a certain type)
- Unlisted data: items not assigned to any list remain accessible

This is implemented via a junction table (item_list_membership) 
that records which items belong to which lists. The organisational 
structure (folders, lists, membership) is separate from the item 
data itself.

## GPX Compatibility

GPX is the interchange format. The app must:
- Import GPX files containing routes, tracks, and waypoints
- Export any item or list as a valid GPX file
- Be compatible with Garmin Zumo devices (XT, XT2)
- Understand the difference between via points (announced, 
  shown as flags on device) and shaping points (silent, used 
  only to shape the route)

When transferring to a Garmin device, routes should include the 
GPX extension data (gpxx:rpt points) that forces the device to 
follow the exact planned route rather than recalculating.

## Critical Rules

- **NEVER modify .xcodeproj or .pbxproj files under any 
  circumstances.** This rule has already been broken once. 
  Do not modify Xcode project files. Create Swift files only 
  and tell the developer which files were created.
- No force unwrapping (`!`) in production code.
- Use Swift concurrency (async/await and actors) throughout — 
  no callback-based async patterns.
- Use the `@Observable` macro, not the older `ObservableObject` 
  protocol.
- All public API must have documentation comments.
- No third-party dependencies beyond those listed in the tech 
  stack without discussion first.

## What To Avoid

- Do not suggest Core Data — GRDB is the chosen persistence layer.
- Do not suggest Electron, Tauri, or any web-based app shell — 
  this is a native SwiftUI application.
- Do not suggest MapKit as the map renderer — MapLibre GL JS in 
  a WKWebView is the chosen approach.
- Do not attempt to handle Xcode project file configuration.


## Current Status

**Increments 1–14 complete, schema v5 applied, drag and drop and context menus implemented.**
The application has a working shell, database layer, live map (MapTiler tiles),
motorcycle routing, a reworked library sidebar, folder creation, list creation,
the waypoints schema, a tested geocoding service, a full waypoint creation flow
with Nominatim search integration, sidebar item selection wired to the map, a
route creation sheet that calls Valhalla and persists the GeoJSON geometry so
selecting a route in the sidebar draws it on the map with bounds fitting, a
polished sidebar control strip with correctly coloured item icons, drag and
drop to move or copy items between lists, and a right-click context menu on
item rows providing Move and Copy actions as an alternative to drag and drop.

### Increment 1 — Application shell
- Two-column `NavigationSplitView` with library sidebar and detail area
- Window opens at 1200×750 via `.defaultSize`

### Increment 2 — Database layer
- GRDB.swift added via Swift Package Manager
- Full SQLite schema (currently at migration `"v4"` via `DatabaseMigrator`)
- `DatabaseManager` actor: opens DB in Application Support, runs
  migrations on launch, seeds placeholder data on first run
- GRDB record structs for all tables
- Sidebar reads folders and lists from SQLite

### Increment 3 — Map
- MapLibre GL JS running in a `WKWebView` (`NSViewRepresentable`)
- `MapLibreMap.html` bundled as a resource; loaded via
  `loadFileURL(allowingReadAccessTo:)`
- Full Swift↔JS bridge via `WKScriptMessageHandler` (`routekeeper`)
- Map shown in detail area when a list is selected

### Increment 4 — Routing
- `RoutingService` actor calls the Valhalla API (motorcycle costing)
  via `URLSession` async/await
- Valhalla precision-6 encoded polyline decoded in Swift; result
  serialised as a GeoJSON FeatureCollection string
- Route drawn on map as a blue line layer via `drawRoute()` JS function
- In-memory cache keyed on coordinate pair prevents redundant API calls
  within a session
- Map-ready gate in `Coordinator`: routes that arrive before MapLibre's
  `load` event are queued and flushed the moment `mapReady` is received

### Increment 5 — Library sidebar rework
- Folders styled as bold `DisclosureGroup` rows with `folder.fill` icon
  (previously plain `Section` headers)
- `VSplitView` replaced with a manual split using `GeometryReader` and a
  draggable divider; `splitFraction` persisted in `@AppStorage` (70/30
  default), immune to content-driven resizing
- Bottom panel shows items in the selected list with per-type SF Symbols:
  `mappin` (waypoint), `arrow.triangle.turn.up.right.diamond` (route),
  `scribble` (track)
- Sort toolbar above the top panel: sort by Name or Date Created with
  ascending/descending toggle; preference stored in `@AppStorage`
- `selectedItem: Item?` added alongside `selectedList`; selecting a list
  clears the item selection
- **Unclassified system folder** implemented entirely in the application
  layer — sentinel `ListFolder` and `RouteList` with `id == -1`; rendered
  with `tray.fill` icon; populates via `fetchUnclassifiedItems()` which
  queries `items` rows absent from `item_list_membership`

### Increment 6 — New Folder creation and uniqueness constraints
- `DatabaseManager.createFolder(name:)` inserts into `list_folders` and
  returns the newly created `ListFolder` with its database-assigned id
- `LibraryViewModel.createFolder(name:)` calls the DB method then reloads
  the folder list using the user's current sort preference
- `NewFolderSheet` — modal sheet with an auto-focused `TextField`, OK
  disabled when the name is blank, Cancel and OK buttons with standard
  keyboard shortcuts; OK dismisses and creates the folder asynchronously
- Three entry points all set `showingNewFolderSheet = true`:
  - Toolbar button (`folder.badge.plus`) above the sidebar top panel
  - Right-click context menu on blank space in the folder list
  - File menu item "New Folder" with ⌘⇧N, wired via `FocusedValue` /
    `FocusedValueKey` so the menu item is disabled when the sidebar is
    not focused
- **Uniqueness constraints** enforced at two levels:
  - Schema: `list_folders.name UNIQUE`, `lists UNIQUE(name, folder_id)`,
    `items.name UNIQUE` — added to DDL for new installs; existing databases
    upgraded via a `"v2"` `DatabaseMigrator` migration that creates named
    unique indexes (`idx_list_folders_name`, `idx_lists_name_folder`,
    `idx_items_name`). Migration tracking moved from the hand-rolled
    `app_settings` approach to GRDB's `DatabaseMigrator` (schema version 2).
  - Application: `LibraryViewModel.createFolder(name:)` and
    `createList(name:folderId:)` catch `DatabaseError` where
    `resultCode == .SQLITE_CONSTRAINT` and set `creationError: String?`
    with a human-readable message. `NewFolderSheet` displays the error in
    red below the text field and clears it when the user edits the name;
    the sheet stays open so the user can correct the duplicate.
- `DatabaseManager.createList(name:folderId:)` and
  `LibraryViewModel.createList(name:folderId:)` added (used by the
  forthcoming `NewListSheet`)

### Increment 7 — New List creation
- `DatabaseManager.createList(name:folderId:)` inserts into `lists` and
  returns the newly created `RouteList` with its database-assigned id
- `LibraryViewModel.createList(name:folderId:)` calls the DB method then
  reloads the folder list; catches `DatabaseError` where
  `resultCode == .SQLITE_CONSTRAINT` and sets `creationError` to
  "A list with that name already exists in this folder."
- `NewListSheet` — modal sheet with an auto-focused `TextField` for the
  list name, a `.menu`-style `Picker` showing all real folders
  (Unclassified sentinel excluded), pre-selected to the folder that was
  right-clicked or defaulting to the first real folder; red error text
  shown below the name field on constraint violation, cleared on edit;
  OK disabled when name is blank or no real folders exist; sheet stays
  open on error so the user can correct it
- Three entry points all set `showingNewListSheet = true`:
  - Toolbar button (`rectangle.badge.plus`) above the sidebar top panel,
    opens with no pre-selection (defaults to first real folder)
  - Right-click context menu on each real folder row, passes that folder
    as the pre-selection; not shown on the Unclassified sentinel
  - File menu item "New List" with ⌘N, wired via `FocusedValue` /
    `ShowNewListSheetKey`; disabled when the sidebar is not focused

### Schema v3 — waypoints data model (superseded by v4)
- **Old `waypoints` satellite table dropped** (previously linked to `items.id`
  via `item_id`; Garmin-style geometry store). Items of type `"waypoint"` remain
  in the `items` table but their geometry rows are gone. The old `Waypoint`
  struct in `ItemRecords.swift` was removed accordingly.
- **`categories` table** — lookup table for waypoint POI types. Seeded with
  twelve defaults in alphabetical order on first run (migration `"v3"`):
  Café (`cup.and.saucer.fill`), Campsite (`tent.fill`), Ferry (`ferry.fill`),
  Fuel (`fuelpump.fill`), Hotel (`bed.double.fill`), Landmark
  (`building.columns.fill`), Other (`mappin`), Parking (`parkingsign`),
  Pass (`mountain.2.fill`), Restaurant (`fork.knife`), Viewpoint
  (`binoculars.fill`), Workshop (`wrench.and.screwdriver.fill`).
- v3 `waypoints` table was a standalone store with its own autoincrement `id`,
  preventing participation in `item_list_membership`. Replaced by v4 (below).

### Schema v4 — waypoints linked to items
- **`waypoints` table redesigned** — `item_id INTEGER PRIMARY KEY REFERENCES
  items(id) ON DELETE CASCADE` replaces the standalone `id` autoincrement key.
  This makes waypoints full participants in the library membership system: the
  same `item_list_membership` junction table used by routes and tracks.
  Columns: `item_id`, `name`, `latitude`, `longitude`,
  `category_id` (nullable FK → `categories.id` ON DELETE SET NULL),
  `color_hex` (default `#E8453C`), `notes`, `created_at`.
- **`WaypointRecords.swift`** — `Waypoint` struct updated: `var itemId: Int64`
  is the stored PK/FK; `var id: Int64 { itemId }` satisfies `Identifiable`.
  `Category` struct unchanged. Both use `encode(to:)` to omit `created_at`.

### GeocodingService
- **`Services/GeocodingService.swift`** — `@MainActor final class` wrapping the
  Nominatim search endpoint
  (`https://nominatim.openstreetmap.org/search?q=…&format=json&limit=8&addressdetails=1`).
  Returns `[GeocodingResult]` — each with `name` (Nominatim `display_name`),
  `subtitle` (city/town/village + country), `latitude`, `longitude`.
  Sends `User-Agent: RouteKeeper/1.0` on every request (required by Nominatim).
  300 ms debounce via task cancellation: each call to `search(_:)` cancels the
  previous `Task` before sleeping 300 ms then fetching; the previous caller
  receives `CancellationError`, which callers should catch and ignore.
- **`RouteKeeperTests/GeocodingServiceTests.swift`** — five Swift Testing tests,
  suite marked `@Suite(.serialized)` to prevent singleton state interference:
  1. `testSearchReturnsResults` — real network call; verifies non-empty results
     and UK bounding box (lat 49–61, lon −8–2) for "Matlock, Derbyshire"
  2. `testSearchResultHasSubtitle` — real network call; verifies non-empty
     subtitle for "Chamonix"
  3. `testEmptyQueryReturnsEmptyResults` — no network call; verifies the empty
     query short-circuit
  4. `testInvalidQueryReturnsEmptyResults` — real network call; verifies empty
     array for a nonsense query
  5. `testDuplicateSearchCancelsPrevious` — no network call for Bath; verifies
     Bristol succeeds and Bath raises `CancellationError`

### Increment 8 — Waypoint creation
- **Schema v4** applied (see above) — `waypoints.item_id` is now both PK and FK
  to `items.id ON DELETE CASCADE`, enabling list membership via the existing
  `item_list_membership` junction table.
- **`DatabaseManager.createWaypoint(name:latitude:longitude:categoryId:colorHex:notes:listIds:)`**
  — inserts into `items` (type = `"waypoint"`), then `waypoints` (using the new
  `item_id`), then `item_list_membership` for each requested list, all within a
  single write transaction. Returns the persisted `Waypoint`.
- **`LibraryViewModel`** gains:
  - `private(set) var categories: [Category]` — loaded on demand.
  - `loadCategories()` — fetches from DB once; no-ops on subsequent calls.
  - `createWaypoint(...)` — calls the DB method, catches `SQLITE_CONSTRAINT`
    for duplicate names, reloads the sidebar on success.
- **`Features/Waypoints/NewWaypointSheet.swift`** (new file) — three-section
  creation sheet:
  1. **Location** — `TextField` with live Nominatim search results (300 ms
     debounced via `GeocodingService`); selecting a result shows a confirmed-
     location chip with a clear button; waypoint name pre-filled from the
     first comma-component of the result's subtitle.
  2. **Details** — name field, category `Picker` (menu style, includes None),
     eight preset colour swatches (`#E8453C`, `#E8873C`, `#E8D83C`, `#4CAF50`,
     `#2196F3`, `#9C27B0`, `#795548`, `#607D8B`), notes `TextEditor`.
  3. **Add to Lists** — checkbox list of all real lists with folder context;
     pre-checks the list that was right-clicked.
  - "Add Waypoint" button disabled until a location is confirmed and name is
    non-empty. Duplicate name error shown in red; sheet stays open to correct.
- **Three entry points** all set `showingNewWaypointSheet = true`:
  - Toolbar button (`mappin.and.ellipse`) above the sidebar top panel.
  - Right-click context menu on each real list row ("New Waypoint"), passes
    that list as the pre-selection.
  - File menu item "New Waypoint" with ⌘⌥N, wired via `FocusedValue` /
    `ShowNewWaypointSheetKey`; disabled when the sidebar is not focused.

### Increment 9 — MapTiler tile provider
- **`Config.plist`** (excluded from git) — holds `MapTilerAPIKey` string;
  never committed to version control.
- **`Services/ConfigService.swift`** — `enum ConfigService` with static
  property `mapTilerAPIKey: String` that reads from `Config.plist` at
  runtime; logs a warning and returns `""` if the key is missing.
- **`MapLibreMap.html`** updated — hardcoded `demotiles.maplibre.org` style
  URL replaced with a `mapStyleURL` JavaScript variable. The map
  initialisation reads `mapStyleURL`; falls back to `""` (visible in the
  console) if injection failed.
- **`MapView.swift`** updated — `makeConfiguration(coordinator:)` builds the
  MapTiler streets-v2 URL (`https://api.maptiler.com/maps/streets-v2/style.json?key=…`)
  from `ConfigService.mapTilerAPIKey` and injects it as
  `var mapStyleURL = "…"` via `WKUserScript` at `.atDocumentStart`.

### Increment 10 — Sidebar item selection wired to map
- **Hardcoded demo route removed** — `ContentView` no longer calls
  `RoutingService` on list selection; `import CoreLocation` dropped; the
  `MapTaskKey` struct removed. The map now starts empty.
- **`MapLibreMap.html`** — two new JS functions:
  - `showWaypoint(lat, lng, colour)` — removes any existing marker, adds a
    GeoJSON point source (`"waypoint-source"`) and circle layer
    (`"waypoint-layer"`) with `circle-radius: 10` and a white
    `circle-stroke-width: 2` in the given colour, then flies to zoom 13.
    Guards on `isStyleLoaded()` with an idle-event defer.
  - `clearWaypoint()` — removes the layer and source if they exist.
- **`MapView.swift`** — new `WaypointDisplay` struct (`latitude`,
  `longitude`, `colorHex`); `MapViewModel` gains `waypointDisplay:
  WaypointDisplay?`, `showWaypoint(latitude:longitude:colorHex:)`, and
  `clearWaypoint()`; `MapView` gains `let waypointDisplay: WaypointDisplay?`;
  `updateNSView` calls `applyWaypointDisplay(_:in:)` when the value changes
  or queues it in `pendingWaypointDisplay` before mapReady; `Coordinator`
  flushes the pending waypoint in the `mapReady` handler.
- **`ContentView.swift`** — `.task(id: selectedItem?.id)` calls
  `handleItemSelection(_:)`: waypoints fetch coordinates and colour via
  `DatabaseManager.fetchWaypointDetails(itemId:)` and call
  `mapViewModel.showWaypoint(...)`; routes and tracks call
  `mapViewModel.clearWaypoint()`; nil selection clears the marker.
- **`DatabaseManager.swift`** — new method `fetchWaypointDetails(itemId:
  Int64) async throws -> Waypoint?` queries `waypoints` by `item_id`.
- **Seed data note** — the seeded waypoints (`Col du Galibier`, etc.) have
  no rows in the v4 `waypoints` table (the seed ran against the v1 schema
  which was later dropped by migrations v3 and v4), so selecting them
  correctly does nothing.

### Increment 11 — Route creation and map display
- **Schema v5** — `ALTER TABLE routes ADD COLUMN geometry TEXT` adds a nullable
  GeoJSON geometry column to the `routes` table. Existing rows receive NULL.
- **`Models/ItemRecords.swift`** — `Route` struct gains `var geometry: String?`
  and the matching `CodingKeys` entry.
- **`DatabaseManager.swift`** additions:
  - `setUp(path:)` — optional `path` parameter (defaults to Application Support
    file; pass `":memory:"` for unit tests).
  - `static makeInMemory()` — test factory; fully migrated in-memory instance.
  - `fetchWaypointsWithCoordinates()` — returns waypoints with non-null lat/lon,
    used to populate the start/end pickers in `NewRouteSheet`.
  - `createRoute(name:geometry:listIds:)` — single write transaction: inserts
    into `items`, `routes` (with geometry), and `item_list_membership`.
  - `fetchRouteGeometry(itemId:)` — returns the `geometry` string for a route
    item, or `nil` if absent.
  - `fetchRouteRecord(itemId:)` — returns the full `Route` row; used by tests.
- **`Features/Routes/NewRouteSheet.swift`** (new file) — four-section sheet:
  name field, start-waypoint `Picker`, end-waypoint `Picker` (start excluded),
  checkbox list assignment. Save disabled until name + both endpoints are set.
  While Valhalla is running, `ProgressView` replaces the Save button and Cancel
  is disabled. A Valhalla error is shown via `.alert`. Calls
  `RoutingService.shared.calculateRoute` then `viewModel.createRoute(...)`.
- **`LibraryViewModel.swift`** additions:
  - `availableWaypoints: [Waypoint]` — populated by `loadAvailableWaypoints()`.
  - `createRoute(name:geometry:listIds:)` — catches `SQLITE_CONSTRAINT`,
    reloads sidebar on success.
- **`MapLibreMap.html`** additions:
  - `showRoute(geojsonString)` — clears any existing route, adds source
    `"route-source"` and layer `"route-layer"` (`line-color: "#2F7CF6"`,
    `line-width: 4`, rounded cap/join), fits map bounds with 60 px padding.
    Guards on `isStyleLoaded()` with idle-event defer.
  - `clearRoute()` (replaces the old stub) — removes both the new
    `"route-source"`/`"route-layer"` and the legacy `"active-route"` ids.
- **`MapView.swift`** additions — `MapViewModel` gains `var routeDisplay:
  String?`, `showRoute(geojson:)`, and `clearRoute()`; `MapView` gains
  `let routeDisplay: String?`; `updateNSView` drives `applyRouteDisplay(_:in:)`;
  `Coordinator` gains `lastRouteDisplay`, `pendingRouteDisplay`, and flushes
  on `mapReady`.
- **`ContentView.swift`** — `handleItemSelection` updated: `.waypoint` clears
  route before showing pin; `.route` clears waypoint, fetches geometry, calls
  `mapViewModel.showRoute(geojson:)` or `mapViewModel.clearRoute()` silently
  if geometry is nil; `.track` and nil clear both.
- **Three entry points** for New Route following the established pattern:
  toolbar button (`road.lanes`), context menu on list rows ("New Route"),
  File menu item "New Route" ⌘⌥R.
- **`RouteKeeperTests/RouteCreationTests.swift`** (new file) — two Swift
  Testing tests using in-memory `DatabaseManager.makeInMemory()`:
  - `testCreateRoutePersistsToAllTables` — verifies rows in `items`, `routes`
    (with correct geometry string and routing profile), and `item_list_membership`.
  - `testCreateRouteWithNoListsAssignsToUnclassified` — verifies a route with
    empty `listIds` appears in `fetchUnclassifiedItems()` with no membership row.

### Files in place

```
RouteKeeper/
├── Database/
│   └── DatabaseManager.swift
├── Models/
│   ├── ItemRecords.swift
│   ├── LibraryRecords.swift
│   ├── WaypointRecords.swift  (Category, Waypoint — schema v4)
│   ├── LibraryModels.swift    (stub)
│   └── SystemFolders.swift    (sentinel values for Unclassified)
├── Features/
│   ├── Library/
│   │   ├── LibrarySidebarView.swift
│   │   ├── LibraryViewModel.swift
│   │   ├── NewFolderSheet.swift
│   │   └── NewListSheet.swift
│   ├── Map/
│   │   └── MapView.swift      (includes MapViewModel)
│   ├── Routing/
│   │   └── RoutingService.swift
│   ├── Routes/
│   │   └── NewRouteSheet.swift
│   └── Waypoints/
│       └── NewWaypointSheet.swift
├── Services/
│   ├── ConfigService.swift
│   └── GeocodingService.swift
├── Resources/
│   └── MapLibreMap.html
├── ContentView.swift
└── RouteKeeperApp.swift
```

### Bridge notes

- JS → Swift: `window.webkit.messageHandlers.routekeeper.postMessage({ type: "...", ... })`
- Swift → JS: `webView.evaluateJavaScript("drawRoute(\"...\");")`
- Message types in use: `mapReady`, `routeDrawn`
- JS functions callable from Swift: `drawRoute(geojsonString)`, `showRoute(geojsonString)`,
  `clearRoute()`, `showWaypoint(lat, lng, colour)`, `clearWaypoint()`

## Known Limitations

- **Valhalla routing** — uses the public OpenStreetMap community
  instance (`valhalla1.openstreetmap.de`). This is rate-limited and
  occasionally unavailable. To be replaced with a self-hosted or
  commercial instance before release.
- **Waypoint editing** — `NewWaypointSheet` handles creation only.
  Editing an existing waypoint's name, location, category, colour,
  notes, or list membership is not yet implemented.
- **Route editing** — `NewRouteSheet` handles creation only. Editing an
  existing route's name, endpoints, or list membership is not yet implemented.
- **List selection not wired to map** — selecting a list in the top
  panel does not yet display all its items on the map simultaneously.
- **Seed data waypoints** — the seeded waypoints have no v4 geometry
  rows (lost during schema migrations); selecting them does nothing.
  New waypoints created via the sheet display correctly.
- **Seed data routes** — the seeded routes have no geometry (NULL in the
  `geometry` column); selecting them silently shows nothing on the map.

### Increment 12 — UI tidy-up
- **Sidebar control strip** — sort control and new-item icons moved from
  the window title bar into the sidebar content area as the first (non-
  selectable) row of the `List`, sitting correctly below the window chrome.
  `List` with `.listStyle(.sidebar)` is now the sidebar root so macOS
  handles title-bar safe-area insets automatically; the items panel is
  attached as a `.safeAreaInset(edge: .bottom)` with a restored draggable
  divider whose height is persisted in `@AppStorage`.
- **Control strip sizing and spacing** — icons resized to
  `.font(.system(size: 16))`, `HStack` spacing increased to 16 pt.
  Tooltips added to all five controls.
- **New-item icon order** changed to folder → list → waypoint → route,
  matching the containment hierarchy.
- **Nominatim result title** — `GeocodingService` now decodes the `name`
  field from the API response and uses it as the result title (falling back
  to the first comma-component of `display_name` when `name` is absent).
  The same value is pre-populated in the waypoint name field when the user
  confirms a search result. Result rows in `NewWaypointSheet` now show the
  proper name as the primary line and city/country as the secondary line.
- **Sidebar icon colour** — `fetchItems(for:)` and `fetchUnclassifiedItems()`
  now `LEFT JOIN waypoints` and alias `color_hex` as `colour` so
  `Item.colour` is populated for waypoint rows without any schema change.
  Sidebar list rows apply `foregroundStyle` to the icon only; waypoints
  use their stored colour and routes/tracks fall back to `.secondary`.

### Increment 13 — Drag and drop between lists
- **Item rows are draggable** — each row in the bottom panel carries a
  `DraggableItem` payload (JSON-encoded `itemId` + `sourceListId`) via
  SwiftUI's `.draggable()` modifier using a custom `Transferable` type.
- **Drop targets are list rows only** — `.onDrop(of:delegate:)` is attached
  to every list row; `ListDropDelegate.validateDrop` rejects the Unclassified
  sentinel (id == −1) and folder headers receive no drop modifier at all.
- **Operation semantics:**
  - Source is Unclassified → always a move (insert target membership; no
    source row exists to delete).
  - Source is a real list, no modifier → copy (insert target membership,
    source membership untouched).
  - Source is a real list, Command held → move (delete source membership,
    insert target membership in a single write transaction).
- **Badge behaviour** — `dropUpdated` returns `.copy` (shows +) by default
  and `.move` (no badge) when Command is held, via `NSEvent.modifierFlags`.
- **Same-list drops are no-ops** — `INSERT OR IGNORE` in `copyItemToList`
  and an early-exit guard in `moveItemBetweenLists` prevent duplicate rows.
- **`DatabaseManager`** gains two new methods, each in a single write
  transaction: `copyItemToList(itemId:targetListId:)` and
  `moveItemBetweenLists(itemId:sourceListId:targetListId:)`.
- **`LibraryViewModel`** gains `currentList: RouteList?` (set by
  `loadItems(for:)`, cleared by `clearItems()`), `copyItem(itemId:toList:)`,
  and `moveItem(itemId:fromListId:toList:)` — both reload the bottom panel
  from `currentList` after a successful DB write.
- **UTType** — `com.routekeeper.libraryitem` is declared as an exported type
  in the Xcode target's Info settings and referenced in code via
  `UTType(exportedAs: "com.routekeeper.libraryitem")`.

### Increment 14 — Right-click context menu on item rows
- **Context menu on item rows** — each row in the bottom panel gains a
  `.contextMenu` with two submenus: "Move to…" and "Copy to…".
- **Submenu structure** — all real lists are listed grouped by folder,
  matching the sidebar tree; the Unclassified sentinel is excluded as a
  target. The list the item is currently being viewed in is excluded from
  both submenus.
- **"Copy to…" suppressed from Unclassified** — when the source is the
  Unclassified list, only "Move to…" is shown; "Copy to…" is omitted
  entirely (matching the drag-and-drop semantics where Unclassified items
  can only be moved into a real list).
- **Greyed-out already-member lists** — lists the item already belongs to
  are shown disabled and non-selectable in both submenus. Membership data
  is pre-loaded by `loadItems(for:)` into `LibraryViewModel.itemMemberships`
  so the context menu reads it synchronously with no extra DB round-trip.
- **Reuses Increment 13 DB methods** — copy actions call
  `copyItemToList(itemId:targetListId:)` and move actions call
  `moveItemBetweenLists(itemId:sourceListId:targetListId:)`.
- **`DatabaseManager`** gains one new read method:
  `fetchListIds(for itemId:) -> Set<Int64>` — queries
  `item_list_membership` to determine which lists an item already belongs
  to; used to populate `itemMemberships` at load time.
- **`LibraryViewModel`** gains `private(set) var itemMemberships:
  [Int64: Set<Int64>]`; `loadItems(for:)` populates it and `clearItems()`
  clears it alongside `listItems`.
- **Sidebar auto-refreshes** — after a successful context-menu action the
  bottom panel reloads via the same `loadItems(for: currentList)` path
  used by drag and drop.

Next step: Increment 15 — to be decided.

## File Structure (Planned)
```
RouteKeeper/
├── RouteKeeper.xcodeproj
├── RouteKeeper/
│   ├── App/
│   ├── Features/
│   │   ├── Library/
│   │   ├── Map/
│   │   ├── Routing/
│   │   └── GPX/
│   ├── Models/
│   ├── Database/
│   └── Resources/
├── CLAUDE.md
├── README.md
├── LICENSE
└── .gitignore
```
