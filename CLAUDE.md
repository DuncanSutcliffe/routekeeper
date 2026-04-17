# RouteKeeper — Claude Code Project Brief

## What This Project Is

RouteKeeper is a macOS application for planning and managing motorcycle
routes. It's an open-source alternative to Garmin Basecamp — a desktop
tool that Garmin has abandoned but which introduced library management
concepts no other software has replicated.

The application is Mac-only, targeting macOS 14+ on Apple Silicon.
It is written in Swift and distributed under GPL v3.

## The Developer

The lead developer is a database professional, not a general software
developer. He has strong SQL and data modelling skills and can review
and critique the database layer directly. For Swift, SwiftUI, and the
map layer, he is relying on Claude Code — so explanations of
non-database code should be clear and not assume prior Swift knowledge.

Always discuss schema changes before implementing them. Prefer explicit
SQL via GRDB over the higher-level query interface where it gives more
control and transparency.

## Tech Stack

- **Language:** Swift (Swift 6, strict concurrency)
- **UI:** SwiftUI, macOS target only — no iOS
- **Map:** MapLibre GL JS embedded in a WKWebView
- **Database:** SQLite via GRDB.swift
- **Routing:** Valhalla API (hosted, via HTTPS) — motorcycle costing
  model preferred
- **Geocoding:** Nominatim (forward and reverse)
- **Elevation:** MapTiler Elevation API
- **GPX:** XMLCoder for import and export
- **Package manager:** Swift Package Manager (no CocoaPods)

## Architecture Overview

The application follows MVVM throughout. The layers are:

1. **Database layer** — SQLite via GRDB. All persistent data lives
   here. Routes, waypoints, tracks, folders, lists, and list membership
   are stored in a normalised schema. This layer is entirely independent
   of the UI.

2. **Map layer** — MapLibre GL JS runs inside a WKWebView. Swift
   communicates with it via WKScriptMessageHandler (Swift → JS) and
   window.webkit.messageHandlers (JS → Swift). The map receives display
   instructions from the app; user interactions on the map send events
   back to Swift.

3. **Routing layer** — Route calculations are made by calling the
   Valhalla API over HTTPS. Results are returned as GeoJSON and stored
   in the database. The motorcycle costing profile is used by default.
   Routing criteria (avoid motorways, tolls, unpaved roads) and named
   routing profiles are supported via `costing_options`.

4. **UI layer** — SwiftUI for all native panels, sidebar, library
   browser, and application chrome.

## Library Management — Core Concept

This is the most important feature of the application. The data model
supports:

- Items (routes, waypoints, tracks) stored once in the database
- Lists, which are named collections of items
- List folders, which organise lists hierarchically
- Many-to-many membership: a single item can belong to multiple lists
  simultaneously without duplication
- Smart lists: automatically populated by rules (future)
- Unclassified: items not assigned to any list remain accessible via a
  sentinel folder/list with id == -1, implemented entirely in the
  application layer

This is implemented via a junction table (`item_list_membership`) that
records which items belong to which lists.

## GPX Compatibility

GPX is the interchange format. The app must:
- Import GPX files containing routes, tracks, and waypoints
- Export any item or list as a valid GPX file
- Be compatible with Garmin Zumo devices (XT, XT2)
- Understand the difference between via points (announced, shown as
  flags on device) and shaping points (silent, used only to shape
  the route)

When transferring to a Garmin device, routes should include the GPX
extension data (`gpxx:rpt` points) that forces the device to follow
the exact planned route rather than recalculating.

## Database Schema (current)

Managed via GRDB `DatabaseMigrator`. Current migrations: `"v1"` through
`"v2"`. The database file lives in Application Support.

### Core tables

**`items`** — one row per route, waypoint, or track.
`id`, `name` (UNIQUE), `type` (`"waypoint"` | `"route"` | `"track"`),
`created_at`

**`waypoints`** — satellite to `items`. `item_id` is both PK and FK to
`items.id ON DELETE CASCADE`.
`item_id`, `name`, `latitude`, `longitude`, `category_id` (nullable FK
→ `categories.id` ON DELETE SET NULL), `color_hex` (default `#E8453C`),
`notes`, `elevation` (REAL, nullable), `created_at`

**`routes`** — satellite to `items`. `item_id` is both PK and FK to
`items.id ON DELETE CASCADE`.
`item_id`, `geometry` (TEXT, nullable — GeoJSON LineString from
Valhalla), `distance_km` (REAL, nullable), `duration_seconds` (INTEGER,
nullable), `routing_profile_id` (nullable FK → `routing_profiles.id`)

**`route_points`** — ordered waypoints for a route.
`id` (autoincrement), `route_item_id` (FK → `routes.item_id` ON DELETE
CASCADE), `sequence_number`, `latitude`, `longitude`, `elevation`
(REAL, nullable), `announces_arrival` (INTEGER, default 0), `name`,
UNIQUE(`route_item_id`, `sequence_number`)

**`list_folders`** — `id`, `name` (UNIQUE), `sort_order`, `created_at`

**`lists`** — `id`, `folder_id` (FK → `list_folders.id`), `name`,
UNIQUE(`name`, `folder_id`), `sort_order`, `created_at`

**`item_list_membership`** — junction table.
`item_id` (FK → `items.id`), `list_id` (FK → `lists.id`),
PRIMARY KEY (`item_id`, `list_id`)

**`categories`** — waypoint POI types. `id`, `name`, `icon_name`
(SF Symbol). Seeded with 12 defaults on first run.

**`routing_profiles`** — named sets of Valhalla costing options.
`id`, `name`, `use_highways` (REAL), `use_tolls` (REAL),
`use_trails` (REAL), `is_default` (INTEGER)

**`app_settings`** — key/value store for user preferences.
`key` (PK), `value`

## Map Bridge

- JS → Swift: `window.webkit.messageHandlers.routekeeper.postMessage({ type: "...", ... })`
- Swift → JS: `webView.evaluateJavaScript("functionName(args)")`
- Message types received by Swift: `mapReady`, `routeDrawn`, `mapContextMenu`
- JS functions callable from Swift:
  - `showWaypoint(lat, lng, colour)` — displays a coloured circle marker
  - `clearWaypoint()` — removes the waypoint marker
  - `showRoute(geojsonString)` — draws a blue LineString and fits bounds
  - `clearRoute()` — removes the route line and markers
  - `showMultipleItems(itemsJson)` — renders multiple waypoints and/or
    routes simultaneously and fits bounds to all of them
  - `sfSymbolBase64(_:color:size:)` — Swift helper used to pass SF Symbol
    PNG data to MapLibre for use as custom icons

## File Structure

```
RouteKeeper/
├── RouteKeeper.xcodeproj
├── RouteKeeper/
│   ├── App/
│   │   └── RouteKeeperApp.swift
│   ├── Features/
│   │   ├── Library/
│   │   │   ├── LibrarySidebarView.swift
│   │   │   ├── LibraryViewModel.swift
│   │   │   ├── NewFolderSheet.swift
│   │   │   └── NewListSheet.swift
│   │   ├── Map/
│   │   │   ├── MapView.swift
│   │   │   └── RouteStatsOverlay.swift
│   │   ├── Routes/
│   │   │   ├── NewRouteSheet.swift
│   │   │   ├── RouteEditSheet.swift
│   │   │   └── RoutePropertiesSheet.swift
│   │   ├── Waypoints/
│   │   │   ├── NewWaypointSheet.swift
│   │   │   └── EditWaypointSheet.swift
│   │   ├── GPX/
│   │   └── Settings/
│   ├── Models/
│   │   ├── ItemRecords.swift
│   │   ├── LibraryRecords.swift
│   │   ├── WaypointRecords.swift
│   │   └── SystemFolders.swift
│   ├── Database/
│   │   └── DatabaseManager.swift
│   ├── Services/
│   │   ├── ConfigService.swift
│   │   ├── GeocodingService.swift
│   │   └── RoutingService.swift
│   └── Resources/
│       ├── MapLibreMap.html
│       └── Config.plist  ← excluded from git, holds MapTilerAPIKey
├── RouteKeeperTests/
├── CLAUDE.md
├── README.md
├── LICENSE
└── .gitignore
```

## Code Style and Working Practices

- String literals must always be kept on a single line or broken
  explicitly using the `+` concatenation operator. Do not allow string
  literals to wrap across lines — this inserts literal newline characters
  into the string and causes build errors. If a string is too long to fit
  comfortably, break it deliberately with `+` at a logical point rather
  than letting the tooling wrap it.
- Use `@Observable`, not `ObservableObject`.
- Use Swift concurrency (async/await and actors) throughout — no
  callback-based async patterns.
- No force unwrapping (`!`) in production code.
- All public API must have documentation comments.
- No third-party dependencies beyond those listed in the tech stack
  without discussion first.

## Critical Rules

- **NEVER modify `.xcodeproj` or `.pbxproj` files under any
  circumstances.** This rule has already been broken once. Create Swift
  files only and tell the developer which files were created so they can
  be added to the Xcode target manually.
- Do not suggest Core Data — GRDB is the chosen persistence layer.
- Do not suggest Electron, Tauri, or any web-based app shell — this is
  a native SwiftUI application.
- Do not suggest MapKit as the map renderer — MapLibre GL JS in a
  WKWebView is the chosen approach.
- Do not attempt to handle Xcode project file configuration.

## Current Status

**Increments 1–39 complete.**

The application has a working shell, database layer, live map (MapTiler
tiles), motorcycle routing via Valhalla, a library sidebar with folder
and list management, full waypoint creation and editing (including
silent elevation capture via MapTiler), route creation with intermediate
waypoints, GPX export (Standard GPX 1.1 and Garmin GPX 1.1), drag and
drop and context menu move/copy between lists, full delete functionality,
numbered intermediate waypoint markers, a native Settings window, routing
profiles and criteria-based routing, a floating route stats overlay,
multi-select in the sidebar with simultaneous map display of all selected
items and auto-fit bounds, right-click on the map to add a waypoint
directly at the clicked coordinate, a floating map style switcher
(Streets / Satellite / Topo) that persists the selection across launches
via app_settings, a native MapLibre scale bar whose units track the
existing units preference, per-route colour selection with eight preset
swatches stored as color_hex in the routes table and applied to all
display paths, non-announcing (shaping) route point support with
bell/bell.slash toggle in the route editor and distinct solid-dot map
rendering, route elevation profiles with ascent/descent totals and a
filled area chart in the floating stats overlay, compact name label
popups for all selected map items, custom SF Symbol category icons on
waypoint markers with vector circle+icon two-layer rendering for all map
markers (waypoints and route start/end flags), a full category
management UI with a standalone Categories window, add/edit/delete
controls for user-created categories, and an inline "Add category…"
action in the waypoint sheets, inline folder rename (double-click or
"Rename…" context menu entry triggers an in-place text editor confirmed
with Return and cancelled with Escape), list editing via double-click or
"Edit List…" context menu (pre-populated name and folder picker in a
repurposed creation sheet), Route Profiles moved to the Manage menu
alongside Categories, and a sidebar refactor splitting LibrarySidebarView
into four files (LibrarySidebarView.swift, FolderLabelView.swift,
ListRowView.swift, LibraryBottomPanel.swift) to resolve systemic Swift
type-checker timeout errors, route label anchoring moved to the
geometric midpoint of each route's LineString (Increment 33), fully
draggable route and library waypoint markers with live Valhalla
recalculation, needs_recalculation flag propagation, and base64 PNG
category icons in marker divs (Increment 34), consistent native
maplibregl.Marker instances for all route point markers (start, end,
via, shaping) in both showRoute() and showMultipleItems(), replacing
all previous GeoJSON source/layer pair approaches, plus route label
popups now include a white arrow.triangle.turn.up.right.diamond SF
Symbol icon prepended to the route name (Increment 35), and a fix for
the sidebar drag-and-drop regression introduced during the Increment 32
refactor — both LibraryBottomPanel.swift and ListRowView.swift have been
reverted from .onDrag {} (NSItemProvider-based, blocked by NSTableView
event interception) to .draggable() (Transferable-based, compatible with
NSTableView-backed List), and consistent native MapLibre markers and
icon-enhanced labels — showWaypoint() and the waypoint path in
showMultipleItems() simplified to plain maplibregl.Marker({ color:
colorHex }), showLabel() updated to render an optional white SF Symbol
icon in an HTML flex row alongside the name, category icons passed
through both the single-item and multi-select code paths (Increment 36).

Increment 25 detail: In MapLibreMap.html, a `contextmenu` event
listener on the MapLibre map object suppresses the default browser menu
and renders a small styled HTML overlay at the click position with a
"New waypoint here" option. The overlay dismisses on selection, on
clicking elsewhere on the map, or on Escape. On selection, the bridge
sends an `addWaypointAtCoordinate` message with lat and lng values to
Swift. The WKWebView message handler extracts the coordinates and
invokes a callback that sets a `MapTapPresentation` state value in
ContentView, which triggers NewWaypointSheet to open. NewWaypointSheet
accepts an optional `prefilledCoordinate: MapCoordinate?` parameter —
when non-nil, the location chip appears pre-confirmed at the clicked
coordinates and a Nominatim reverse geocode request fires immediately
to pre-populate the name field. Silent elevation capture and all other
sheet behaviour is unchanged. Existing sheet entry points (toolbar,
context menu, keyboard shortcut) pass `prefilledCoordinate: nil`.

Increment 26 detail: A floating SwiftUI overlay (MapStylePicker) in the
top-left corner of the map provides three style buttons (Streets,
Satellite, Topo) backed by MapTiler's streets-v4, hybrid-v4, and topo-v4
styles respectively. The active style is highlighted. Switching calls
setMapStyle(styleName) in JavaScript via map.setStyle(). A style.load
event listener (guarded by mapFirstLoadComplete) sends mapStyleLoaded to
Swift, which re-dispatches the current display state to restore custom
layers after the style wipe. Map repositioning on style switch is deferred
(a suppressRecentre JS flag partially addresses it but the behaviour is
not fully reliable — deferred alongside other zoom work). The selected
style persists via a map_style key in app_settings (defaulting to
streets-v4) loaded at launch via DatabaseManager.loadMapStyle() /
saveMapStyle(). The style name, API key, and scale unit are all injected
into the HTML at initialisation via a single WKUserScript so the correct
values are available on first render. A MapLibre ScaleControl sits in the
bottom-left corner; its unit ("imperial" / "metric") is driven by the
units preference in app_settings and updated live via setScaleUnits()
whenever the user changes their units preference in Settings.

Increment 27 detail: A color_hex column (TEXT, not null, default
'#1A73E8') was added to the routes table via schema migration v3. The
default mid-blue (#1A73E8) is pre-selected in NewRouteSheet and used as
a fallback wherever color_hex is absent. Both NewRouteSheet and
RoutePropertiesSheet include a colour picker section using the same eight
preset swatches and layout as the waypoint sheets, with no "none" option.
The private ColourSwatch component and Color(hex:) extension were
extracted from the waypoint sheets into a shared Shared/ColourSwatch.swift
file (to be added to the Xcode target), with waypointPresetColours and
routePresetColours constants defined there. showRoute in MapLibreMap.html
accepts lineColour as a fifth parameter (defaulting to '#1A73E8'),
replacing the previously hardcoded value; the via-waypoint stroke colour
is also driven by this parameter. RouteDisplay gained a colorHex field
which is passed through applyRouteDisplay into the JS call. The
mapStyleLoaded re-dispatch path passes colour correctly via the stored
RouteDisplay struct. A bug was also fixed where routes in list-selection
and multi-select display always rendered in the default blue: the
multi-display code path now passes each route's color_hex individually
via a feature property, and showMultipleItems uses a data-driven
["get", "color"] expression instead of the previously hardcoded value.

Increment 29 detail: The announces_arrival column in route_points
(INTEGER NOT NULL DEFAULT 0) is now exposed in the UI. In RouteEditSheet,
every intermediate point row has a bell / bell.slash toggle button; bell
indicates an announcing via point, bell.slash indicates a shaping point.
Start and End rows do not have this control. When a point is toggled to
non-announcing, its row label changes from "Via N" to "Shaping". The
Via N numbering sequence counts only announcing intermediate points, so
shaping points don't affect the numbering of surrounding via points.
announces_arrival is written to the database on Save alongside the
existing route point persistence logic; Start and End are always written
as announcing regardless of any toggle state. On the map, shaping points
render as solid filled dots (radius 7.5) in the route's line colour via
a new route-shaping-circles layer on route-shaping-source; these are
visually distinct from the numbered white circles used for via points.
ViaWaypoint gained an announcesArrival field; applyRouteDisplay splits
the intermediate waypoints into announcing and shaping arrays and passes
them as the fourth and sixth arguments to showRoute respectively.
clearRoute removes both layers and sources. The Garmin GPX export path
already correctly produced a gpxx:RoutePointExtension block with the
standard Garmin Subclass hex string for shaping points; announcing via
points have no extensions block. A confirming comment was added to
GPXExporter.swift.

Increment 30 detail: Two new nullable columns were added to the routes
table directly in createCompleteSchema (drop/recreate expected, no
migration): elevation_profile (TEXT) stores a JSON array of elevation
values in metres, and notes (TEXT) is free-form text with no UI yet.
The Valhalla route request now includes elevation_interval: 30, causing
it to return elevation samples every 30 metres along the route. On a
successful route calculation, the elevation arrays from all legs are
concatenated into a single flat array, serialised as a JSON string, and
stored in elevation_profile alongside the existing geometry and stats.
If Valhalla returns no elevation data, NULL is stored. The floating stats
overlay (RouteStatsOverlay) conditionally shows additional content when
elevation_profile is non-null: total ascent (↑ Xm) and total descent
(↓ Xm) figures appear in the stats row alongside distance and duration,
and a 60pt filled area chart rendered using SwiftUI's Charts framework
with AreaMark appears below. The chart x-axis represents distance in
kilometres distributed evenly across the sample count; the y-axis
represents elevation in metres scaled to the data's actual min/max with
±20m padding. The fill uses the route's color_hex at 0.3 opacity; the
stroke is solid at full opacity. Three y-axis labels (maximum, midpoint,
minimum, each rounded to the nearest 10m) are overlaid on the left edge
of the chart in 9pt secondary colour. The overlay is fixed at 320pt
maximum width, centred at the bottom of the map. Routes with a null
elevation_profile show only the original distance and duration figures.

Increment 31 detail (labels): MapLibreMap.html has three new functions:
showLabel(itemId, lng, lat, name) creates a compact dark tooltip-style
maplibregl.Popup (no close button, no close-on-click) anchored at the
given coordinates and stored in a module-level dictionary keyed by
String(itemId); hideLabel(itemId) removes a single label; hideAllLabels()
clears all labels. Labels are shown for every selected item — waypoints at
their own coordinates, routes anchored at their first route point — and
are styled to be unobtrusive: small white text on a dark semi-transparent
background, rounded corners, no pointer arrow, 15px upward offset from
the anchor. Labels persist through pan and zoom and are dismissed only
when the item is deselected. clearRoute and clearWaypoint both call
hideAllLabels(); clearMultipleItems does the same. The mapStyleLoaded
re-dispatch path re-creates labels automatically because it calls
applyWaypointDisplay, applyRouteDisplay, and applyMultiDisplay, each of
which drives showLabel internally. WaypointDisplay and RouteDisplay gained
itemId (Int64) and name (String) fields; MapViewModel.showWaypoint was
updated to match. MultiItemEntry gained itemId and name fields encoded
into the JSON payload. Bug fix: showMultipleItems previously only rendered
route lines and start/end flag markers, silently omitting via and shaping
point markers. showMultipleItems now renders per-route via circles and
shaping dots using dynamic source/layer IDs keyed by itemId (e.g.
multi-via-source-42) tracked in module-level multiViaLayerIds and
multiViaSources arrays; clearMultipleItems clears these arrays alongside
the fixed-name layers. On the Swift side, buildMultiItemsJson now fetches
route points for each route entry and populates viaWaypoints and
shapingWaypoints fields on MultiItemEntry (using the same announcing/
shaping split as the single-item display path), backed by two new private
Encodable structs MultiViaWaypoint and MultiShapingWaypoint.

Increment 31 detail (custom map markers): All map markers are now
rendered as two MapLibre layers on a shared GeoJSON point source: a vector
circle layer (white fill, coloured stroke, radius 14) and a centred symbol
layer using a pre-registered SF Symbol icon. SF Symbols are rendered in
Swift by categoryIconBase64() at 22pt on an 84×84px canvas at 3× scale,
encoded as base64 PNGs, and registered with MapLibre via
registerCategoryIcons() at map load and again after every map.setStyle()
call (which wipes all registered images). Category icons are registered as
"icon-<category-name>". Route start and end flags (flag.fill and
flag.checkered) are pre-registered as "icon-route-start" and
"icon-route-end" in the same payload, replacing the previous per-call
async raster image approach. showRoute is no longer async. All source and
layer IDs across showWaypoint/clearWaypoint, showRoute/clearRoute, and
showMultipleItems/clearMultipleItems have been audited and made fully
distinct: route marker layers use route-start-/route-end- prefixes keyed
by itemId (e.g. route-start-circle-42), single waypoint layers use
waypoint-, and multi-select waypoint layers use multi-waypoint-{id} per
item. The previous batched multi-markers-source/multi-waypoints-source
approach in showMultipleItems has been replaced with per-item dynamic
sources and layers, all tracked in multiViaLayerIds/multiViaSources for
cleanup. icon-ignore-placement: true and icon-allow-overlap: true are set
on all symbol layers to prevent MapLibre's placement algorithm from
drifting icons away from their backing circles at lower zoom levels.

Increment 31 detail (category management): A new is_default column
(INTEGER NOT NULL DEFAULT 0) was added to the categories table via
migration v4; the twelve seed categories have is_default = 1. A new
"Manage" top-level menu contains a single item "Categories…" that opens
CategoryManagementWindow, a standalone non-modal SwiftUI Window scene.
The window lists all categories alphabetically; default categories are
read-only with a lock badge; user-created categories have edit (pencil)
and delete (trash) controls. The delete button is disabled with a tooltip
when any waypoints are assigned to the category. A CategoryEditSheet
handles both adding and editing, with a name field (inline uniqueness
validation) and a scrollable curated grid of 45 SF Symbols organised into
eight labelled groups. CategoryViewModel manages all category CRUD and
posts routeKeeperCategoriesChanged after any write so the map Coordinator
re-registers icons immediately via NotificationCenter. In NewWaypointSheet
and EditWaypointSheet, the category Picker has been replaced with a Menu
control that includes an "Add category…" option at the bottom; selecting
it presents CategoryEditSheet as a sheet directly on top of the waypoint
sheet; on save the new category is automatically pre-selected and the
dropdown refreshes via an onSave callback.

Increment 32 detail: Folders can be renamed via double-click or a new
"Rename…" right-click context menu entry; both trigger an inline
TextField on the folder name row (FolderLabelView), confirmed with Return
and cancelled with Escape. Empty or unchanged input is treated as a
cancel. Lists can be edited via double-click or a new "Edit List…"
right-click context menu entry; both open NewListSheet repurposed as an
edit sheet, pre-populated with the current name and parent folder,
allowing rename and folder reassignment in a single action. Route
Profiles has been moved from the File menu to the Manage menu, separated
from Categories by a Divider. LibrarySidebarView.swift was refactored
from a single 1000+ line file into four files to resolve systemic Swift
type-checker timeout errors caused by excessive view body complexity:
FolderLabelView.swift (folder DisclosureGroup labels), ListRowView.swift
(list rows within folders), LibraryBottomPanel.swift (the resizable items
panel including its drag-to-resize divider), and a slimmed
LibrarySidebarView.swift with all modal modifiers extracted into a
dedicated LibrarySidebarModals ViewModifier. A UTExportedTypeDeclarations
entry for com.routekeeper.listitem was added to Info.plist. List drag and
drop between folders was attempted but proved unreliable within a
DisclosureGroup label inside a sidebar List on macOS; lists can be moved
between folders via the Edit List sheet instead.

Increment 33 detail: Route label anchoring in MapLibreMap.html was
changed from the route's first coordinate to the geometric midpoint of
its LineString. A new `lineMidpoint(coords)` JavaScript helper takes an
array of [lng, lat] pairs, sums Euclidean distances between consecutive
pairs to find the total length, then walks the segments a second time
until the running total reaches 50% of that length, interpolating
between the two straddling coordinates. Both call sites were updated:
`showRoute` applies `lineMidpoint` to the full coordinate array already
in scope; `showMultipleItems` stores the full `allLineCoords` array as
`allCoords` on each route marker group and applies `lineMidpoint` there.
Waypoint labels are unaffected.

Increment 34 detail: Schema migration v5 added `waypoint_item_id`
(nullable INTEGER, FK to `waypoints.item_id` ON DELETE SET NULL) to
`route_points`, and `needs_recalculation` (INTEGER NOT NULL DEFAULT 0)
to `routes`. Route creation populates `waypoint_item_id` when a route
point originates from a library waypoint (in both
`DatabaseManager.createRoute` for start/end points and
`RouteWaypointSheet` for intermediate picks). All route waypoint markers
(start, end, via, shaping) were converted from GeoJSON source/layer
pairs to `maplibregl.Marker` instances with `draggable: true`;
`showRoute()` was extended with `startSeq` and `endSeq` parameters
(carried through `RouteDisplay` and `ViaWaypoint` structs on the Swift
side) so every marker type carries its `sequence_number`. On `dragend`,
a `waypointDragged` bridge message fires; Swift updates the
`route_points` row (new coordinates, `waypoint_item_id` cleared to NULL,
`name` set to `"lat, lon"` to 4 decimal places via
`updateRoutePointPosition`), recalculates via Valhalla using the route's
stored costing options, saves updated geometry via
`updateRouteGeometryAndStats`, and redraws the route with
`suppressRecentre = true`. Library waypoint markers were converted from
GeoJSON layers to draggable `maplibregl.Marker` instances using custom
HTML div elements. On `dragend`, a `waypointMoved` bridge message fires;
Swift updates the `waypoints` row, queries for routes containing that
waypoint via `waypoint_item_id` (`fetchRoutesContainingWaypoint`), and
if any exist presents a confirmation alert offering to update their
`route_points` coordinates and set `needs_recalculation = 1` via
`updateRoutePointsForWaypoint`. The `needs_recalculation` flag is
honoured in both the single-item display path (`handleSingleItemSelection`
in ContentView) and the multi-item path (`buildMultiItemsJson`) —
affected routes recalculate via Valhalla before drawing and the flag is
cleared by `updateRouteGeometryAndStats`. Waypoint marker icons are
rendered via `categoryIconBase64Compact()` producing 36×36 px base64
PNGs (18 pt at 2× scale), embedded as HTML `<img>` elements (20×20 CSS
px) inside the 33×33 px marker div; this bypasses the MapLibre image
registry entirely for the single-waypoint display path.

Increment 35 detail: All route point markers (start, end, via, shaping)
in showRoute() use native `maplibregl.Marker` instances with
`draggable: true`; start and end use `{ color: lineColour }`, via uses
`{ color: lineColour, scale: 0.7 }`, shaping uses
`{ color: '#888888', scale: 0.5 }`. In showMultipleItems(), start and
end markers were converted from GeoJSON source/layer pairs to native
`maplibregl.Marker` instances (no `draggable`; multi-select is
display-only). Via and shaping markers in showMultipleItems() were
likewise replaced with native Marker instances iterating over the
features arrays from viaGroups and shapingGroups. All multi-item route
markers (start, end, via, shaping) are pushed into `multiRouteMarkers`
and removed by `clearMultipleItems()`. The `multiViaLayerIds` and
`multiViaSources` arrays are retained for waypoint GeoJSON layers, which
remain as circle+symbol source/layer pairs. Route label popups in both
showRoute() and showMultipleItems() now include a white
`arrow.triangle.turn.up.right.diamond` SF Symbol icon (18 pt,
rendered via `categoryIconBase64Compact()` at 2× scale, 36×36 px)
prepended to the route name. The icon is generated in `applyRouteDisplay`
(single-item path) and once per `buildMultiItemsJson` call (multi-item
path), embedded as a base64 PNG passed through `RouteDisplay.routeIconBase64`
and `MultiItemEntry.routeIconBase64` respectively. `showLabel()` in JS
accepts an optional `iconBase64` parameter; when present it uses
`setHTML()` with an inline flex span; waypoint labels used `setText()`
at the time of Increment 35 but were updated in Increment 36 to use
the icon path.

Increment 36 detail: showWaypoint() and the waypoint rendering path in
showMultipleItems() have been simplified to use plain
maplibregl.Marker({ color: colorHex }) instances, replacing the
previous custom HTML element approach (white circle div with coloured
border and embedded SF Symbol img). All markers on the map — route
start/end flags, via points, shaping points, and library waypoints —
now use MapLibre native markers consistently. The showLabel() function
now accepts an optional iconBase64 parameter; when present it renders
the popup content as an HTML flex row with a 20px white SF Symbol icon
(opacity 0.9) to the left of the name, using setHTML(); when absent it
falls back to setText() unchanged. For the single-item waypoint path,
applyWaypointDisplay() generates a white rendering of the category icon
via categoryIconBase64Compact() and passes it to showWaypoint() as
iconBase64, which forwards it to showLabel(). For the multi-select
path, buildMultiItemsJson() generates the white icon per waypoint entry
(using cat.iconName with color: .white) and serialises it as
labelIconBase64 on the JSON object; showMultipleItems() picks this up
via waypointGroups and passes it to showLabel(). Route labels are
unchanged — they continue to use routeIconBase64. Label offset is
[16, -38] to position labels above and slightly right of the marker tip.
The sidebar drag-and-drop regression (introduced in the Increment 32
refactor) was also fixed: LibraryBottomPanel.swift and ListRowView.swift
were reverted from .onDrag {} (NSItemProvider-based, blocked by
NSTableView event interception) to .draggable() (Transferable-based,
compatible with NSTableView-backed List).

Increment 37 detail: A third GPX export format, Beeline, has been added
throughout the export pipeline. `GPXFormat` in `GPXExporter.swift` gains a
`.beeline` case. The `exportGPX(items:format:)` function handles it by emitting
each route point as a top-level `<wpt>` element rather than wrapping them in a
`<rte>` block. Each `<wpt>` includes `lat`/`lon` attributes, an `<ele>` element
where elevation is non-nil, and a `<name>` element using the point's stored name
if present, or the coordinate pair formatted to 4 decimal places as a fallback
(e.g. `"51.5123, -0.1234"`). Waypoints and tracks export identically across all
three formats. `ExportSettingsView` (Export tab in Settings) was updated from a
segmented picker to a menu-style dropdown (`.pickerStyle(.menu)`) with all three
options: Standard GPX 1.1, Garmin GPX 1.1, and Beeline, stored as `"beeline"` in
`app_settings` via `PreferencesManager.defaultExportFormat`.
`ExportFormatSheet` likewise uses a menu-style picker, pre-selects the user's
stored default from `app_settings`, and includes the Beeline option with the
description: "Exports route points as individual waypoints. Use for importing
into the Beeline app."

Increment 38 detail: A native macOS Settings scene (⌘,) has been
extended with an API Keys tab containing fields for MapTiler and
What3Words keys. Each field is masked by default with a show/hide
toggle, and a Save button writes both values to the macOS Keychain via
a new `KeychainManager` (`RouteKeeper/Services/KeychainManager.swift`),
which uses `kSecClassGenericPassword` with `kSecAttrAccessibleWhenUnlocked`.
A new `APIKeysManager` (`RouteKeeper/Services/APIKeysManager.swift`) is
an `@Observable` class injected into the SwiftUI environment at app
startup via `RouteKeeperApp`; it loads both keys from the Keychain on
`init` and exposes them as observable properties. A one-time migration
reads the MapTiler key from `Config.plist` via `ConfigService` on first
launch if the Keychain entry is empty, writes it to the Keychain, and
uses it from there on subsequent launches. The What3Words key is stored
but not yet used. `ConfigService` is retained as a fallback during
transition. `MapView` now accepts `mapTilerAPIKey: String` as a
parameter (passed from `ContentView` via the environment) and uses it
in `makeConfiguration` in place of the direct `ConfigService` call.
The Settings window minimum width was updated to 480pt to accommodate
the key fields. The new UI file is
`RouteKeeper/Features/Settings/APIKeysSettingsView.swift`.

Increment 39 detail: `NewRouteSheet` now uses `WaypointPickerSheet` for both
start and end point selection, replacing the previous flat `Picker` dropdowns.
Each field displays the selected waypoint name or a grey placeholder prompt;
tapping opens the picker sheet, which excludes the opposing selection via the
existing `excludingId` parameter. `WaypointPickerSheet` was improved in four
steps: (1) waypoints are grouped by library list, with the folder name shown as
secondary text in each section header; waypoints belonging to multiple lists
appear in each relevant section; a final "Unclassified" section catches
waypoints with no list membership; grouping data comes from a new
`fetchWaypointsByList()` method in `DatabaseManager` returning
`[WaypointListSection]`; (2) each row now shows a filled colour dot, the
category SF Symbol icon, the waypoint name, and the category name as secondary
grey text beneath — consistent with the sidebar appearance; `WaypointSummary`
was extended with `colorHex`, `categoryName`, `categoryIconName`, and `notes`
fields (all defaulted so existing call sites are unaffected); (3) search is
now case- and diacritic-insensitive using `.folding(options: [.caseInsensitive,
.diacriticInsensitive])` and matches against waypoint name, category name,
notes, and any list name the waypoint belongs to; a two-pass algorithm ensures
that a waypoint matching via list name appears in all its sections; (4) the
search bar is full-width at the top of the sheet below the navigation title,
implemented as a plain `TextField` above the `List` (replacing `.searchable`);
the sheet accepts `title: String = "Add Waypoint"` and `NewRouteSheet` passes
`"Select Start Point"` and `"Select End Point"` at the respective call sites.

**Known issues / deferred:**
- Valhalla uses the public OSM community instance — rate-limited.
  To be replaced before release.
- Route direction arrows (Increment 28) were attempted using a
  canvas-drawn custom image registered via map.addImage. The approach
  proved unreliable and was fully reverted. To be revisited using an
  SDF image approach.
- Custom HTML element approach for route point markers in showRoute()
  was abandoned due to persistent anchor positioning drift at different
  zoom levels with MapLibre custom elements. Native maplibregl.Marker
  instances are used instead for all four marker types in both
  showRoute() and showMultipleItems().
Increment 38 detail: Waypoint address storage and editable address sheet. Schema
migration v6 added fourteen nullable TEXT address columns to the `waypoints` table:
`address_house_number`, `address_road`, `address_suburb`, `address_neighbourhood`,
`address_city`, `address_town`, `address_village`, `address_municipality`,
`address_county`, `address_state_district`, `address_state`, `address_postcode`,
`address_country`, `address_country_code`. Nominatim geocoding results populate all
available fields on waypoint creation and editing; city, town, and village are stored in
separate columns with no collapsing logic; empty fields are stored as NULL. A new
`AddressData` struct in `GeocodingService.swift` carries these fields; `GeocodingResult`
gains an optional `address: AddressData?` property; `Waypoint` in `WaypointRecords.swift`
gains the corresponding optional String properties. `DatabaseManager.createWaypoint` and
`updateWaypoint` accept `address: AddressData? = nil`; a new `updateWaypointAddress`
method updates only the address columns. A non-editable address summary line appears
beneath the Name field in both `NewWaypointSheet` and `EditWaypointSheet`, concatenating
non-nil fields in natural order with `", "` as separator, falling back to
`"No address stored"` in secondary grey text. An `"Edit Address"` button styled with
`.buttonStyle(.borderless)` and accent colour opens `AddressEditSheet`, which shows all
address fields as individually labelled TextFields. Done saves all fields back to the
database (empty fields stored as NULL); in `EditWaypointSheet` the write is immediate via
`updateWaypointAddress`; in `NewWaypointSheet` the address is written as part of the
normal creation flow. Cancel discards changes. `WaypointPickerSheet` search covers all
address columns via the same diacritic-insensitive OR logic used for name, category,
notes, and list membership. New file: `RouteKeeper/Features/Waypoints/AddressEditSheet.swift`.

**Next step: Increment 40 — TBD.**
