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
│   │   ├── Tracks/
│   │   │   └── TrackPropertiesSheet.swift
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

Increments 1–51 complete. The application has a full working shell with:
library sidebar (folders, lists, drag-and-drop, inline rename/edit),
waypoint creation and editing (coordinate pick, reverse geocode, category
icons, address storage and editing, elevation capture), route creation
(waypoint picker, Valhalla routing, costing criteria, named routing
profiles, colour picker, intermediate via and shaping points, elevation
profile chart), GPX export (Standard, Garmin, Beeline formats), GPX
import (waypoints and routes from .gpx/.xml files, Garmin shaping-point
detection via gpxx:RoutePointExtension subclass hex string,
duplicate-name deduplication with (1)/(2) suffix, shared-name
deduplication between <wpt> elements and route endpoints, deferred
Valhalla geometry with default routing profile association, list picker
with inline new-list creation, File menu and list context menu entry
points, post-import library refresh and auto-selection of target list),
live MapLibre map (Streets/Satellite/Topo style switcher, scale bar,
context menu "add waypoint here"), multi-select and list-selection map
display with labels toggle, draggable route and waypoint markers with
live Valhalla recalculation, rubber-band shaping point insertion via
Option+drag on the route line, stack-based undo (Cmd+Z) for all drag
operations, consistent library refresh via NotificationCenter
(routeKeeperLibraryDidChange) with auto-selection of newly created
waypoints and routes on the map, multi-item delete and remove (context
menu, Delete/⌘Delete keyboard shortcuts, Edit menu — all respect the
full multi-selection with count-aware confirmation dialogs), multi-select
drag and drop between lists (DraggableItem carries itemIds: [Int64];
when a dragged row is part of the selection all selected IDs are
included; single-item drag behaviour unchanged), shaping point marker
offset fix in showMultipleItems matching the offset already applied in
showRoute, a native Settings window (units, export format, API keys
via Keychain), route properties sheet fixes (redundant Done button
removed; Cancel shows an unsaved-changes confirmation dialog — 'Discard
changes?' with 'Discard' and 'Keep Editing' — when any local state
differs from its initial snapshot, and dismisses immediately otherwise;
onSave triggers a full library reload so name and colour changes are
immediately visible in the sidebar and bottom panel; if the edited route
is currently selected the map is also refreshed to reflect the changes),
and GPX track import and display (DB migration v7 adds color defaulting
to #3E515A and line_style defaulting to solid to tracks, and timestamp
as nullable ISO 8601 string to track_points; GPXImporter extended to
parse <trk> elements, flattening all <trkseg> children into a single
ordered point sequence; import coordinator handles tracks alongside
routes and waypoints with the same duplicate-name deduplication logic;
importGPXResult returns a 4-tuple including trackCount; success message
reports routes/tracks/waypoints grammatically; Track and TrackPoint model
structs define a lineStyleDashArray computed property resolving four
presets (dotted → [1,3], short_dash → [4,3], long_dash → [8,4],
solid → nil) and a static eight-colour track palette as darker shades
of the route palette; tracks appear in the sidebar with the SF Symbol
point.bottomleft.forward.to.point.topright.scurvepath.fill and a colour
dot; track display uses a MapLibre line layer with optional dasharray,
start/end standard maplibregl.Marker teardrop markers in the track
colour, and a name label anchored at the geometric midpoint using the
existing lineMidpoint helper; TrackPropertiesSheet provides name, colour,
and line style editing with the same Cancel/Save pattern as
RoutePropertiesSheet; context menu "Track Properties…" and double-click
open the sheet; TrackDisplay drives the Coordinator/updateNSView pattern
matching WaypointDisplay/RouteDisplay; track display, labels, and
start/end markers are applied in both single-select and multi-select
paths; track labels are cleared correctly on selection change including
track-to-track transitions; tracks/showTrack/hideTrack survive map style
reloads via mapStyleLoaded re-apply; the route and waypoint blue colour
has been standardised to #1A73E8 throughout).

**Known issues / deferred:**
- Valhalla uses the public OSM community instance — rate-limited.
  To be replaced before release.
- Intermittent rendering artefact on first track selection — not
  reliably reproducible, deferred.

Increment 48 — Per-type labels toggles. The single showListItemLabels toggle has
been replaced with three separate @AppStorage booleans: showRouteLabels,
showTrackLabels, and showWaypointLabels, all defaulting to true. The floating
labels panel shows three labelled toggle rows — Routes, Tracks, Waypoints — each
as an HStack with the label on the left, a Spacer, and a right-aligned switch
using .toggleStyle(.switch) with .labelsHidden(). The panel has a fixed width of
approximately 170 points to prevent it expanding to fill available space. Each
toggle is enabled only when the currently selected list contains at least one item
of that type; the enabled state is derived from the item data already loaded at
list selection time without additional database queries. Toggling any switch off
calls hideAllLabels() then restores labels for all types whose toggle remains on;
toggling on restores showLabel calls for all currently displayed items of that
type. All three types — routes, tracks, and waypoints — are handled consistently
across the initial list render path, the toggle-on restore path, and the
toggle-off hide path.

Increment 49 — Label improvements and track label icon. Label truncation now uses
CSS text-overflow: ellipsis, overflow: hidden, and white-space: nowrap so names
exceeding the maximum label width are cut off cleanly with an ellipsis rather than
abruptly mid-character; a title attribute on the popup content element shows the
full name on hover. The floating labels panel gained a Text("Show labels") heading
styled with .font(.caption) and .foregroundStyle(.secondary). A bug was fixed where
label toggle preferences were not respected on the first list selection after app
launch — the initial list display path now reads the three @AppStorage booleans
consistently with all subsequent selections. Track labels now include a white
rendering of the track SF Symbol
point.bottomleft.forward.to.point.topright.scurvepath.fill passed as the
iconBase64 parameter to showLabel, matching the pattern already used for route and
waypoint label icons.

Increment 50 — Route direction arrows. Direction arrows are drawn on route lines
using canvas-rendered isosceles triangle images registered with MapLibre via
map.addImage. A createArrowImage(color) function draws a 9×12px triangle on an
HTMLCanvasElement and returns { width, height, data } for MapLibre. A darkenHex(hex,
factor) helper darkens the route's colorHex by factor 0.75 for the arrow fill. A
computeArrowPoints(coordinates, targetCount) function flattens all FeatureCollection
coordinates into a single LineString, distributes targetCount evenly-spaced points
along it, and calculates a spherical bearing for each. Arrow count uses an
exponential formula Math.min(500, Math.max(4, Math.round(Math.pow(2, zoom - 3))))
so density doubles with each zoom level. Arrows use icon-rotate with
icon-rotation-alignment: 'map', icon-allow-overlap: true, and
icon-ignore-placement: true. A zoomend listener rebuilds arrow sources for all
currently displayed routes on zoom changes. The same implementation applies to
showMultipleItems using arrow-multi-{routeItemId} image and source IDs, with
clearMultipleItems cleaning up all arrow layers and sources.

Increment 51 — Fix single-item session restore rendering. When the app was closed
with exactly one item selected, restoration correctly selected the item but then
immediately overwrote the single-item map view with the full list render. The root
cause was handleSelectionChange() firing the list-display path before the
single-item restore signal had been applied. Fixed by adding an early return in
handleSelectionChange() when pendingRestoreItemIds is non-empty, preventing the
list render from racing ahead of the restoration. List-only restores are unaffected
since pendingRestoreItemIds is empty in that case.

**Next step: Increment 52 — TBD.**
