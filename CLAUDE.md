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

**Increments 1–4 complete.** The application has a working shell,
database layer, live map, and motorcycle routing.

### Increment 1 — Application shell
- Two-column `NavigationSplitView` with library sidebar and detail area
- Window opens at 1200×750 via `.defaultSize`

### Increment 2 — Database layer
- GRDB.swift added via Swift Package Manager
- Full SQLite schema at `schema_version = 1`
- `DatabaseManager` actor: opens DB in Application Support, runs 
  migrations on launch, seeds placeholder data on first run
- GRDB record structs for all nine tables
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

### Files in place

```
RouteKeeper/
├── Database/
│   └── DatabaseManager.swift
├── Models/
│   ├── ItemRecords.swift
│   ├── LibraryRecords.swift
│   └── LibraryModels.swift  (stub)
├── Features/
│   ├── Library/
│   │   ├── LibrarySidebarView.swift
│   │   └── LibraryViewModel.swift
│   ├── Map/
│   │   └── MapView.swift          (includes MapViewModel)
│   └── Routing/
│       └── RoutingService.swift
├── Resources/
│   └── MapLibreMap.html
├── ContentView.swift
└── RouteKeeperApp.swift
```

### Bridge notes

- JS → Swift: `window.webkit.messageHandlers.routekeeper.postMessage({ type: "...", ... })`
- Swift → JS: `webView.evaluateJavaScript("drawRoute(\"...\");")`
- Message types in use: `mapReady`, `routeDrawn`

## Known Limitations

- **Map tile source** — `demotiles.maplibre.org` is MapLibre's demo 
  server and is not suitable for production use. To be replaced with a 
  proper tile provider before release.
- **Valhalla routing** — uses the public OpenStreetMap community 
  instance (`valhalla1.openstreetmap.de`). This is rate-limited and 
  occasionally unavailable. To be replaced with a self-hosted or 
  commercial instance before release.

Next step: Increment 5 — to be decided.

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
