# RouteKeeper — Refactor Notes

Audit date: 2026-04-24  
Scope: All Swift source files, MapLibreMap.html, and the complete database schema.  
Purpose: Identify structural, architectural, and hygiene issues. No functional changes proposed here.

Every finding has a corresponding `// TODO: [REFACTOR]` comment inserted at the relevant location in the source file. This document groups them thematically and explains why each matters.

Total findings: **30**

---

## 1. Architecture & File Placement

### 1a. `RoutingService` lives in `Features/Routing/` — should be in `Services/`
`RoutingService.swift` is a pure network service with no view or feature-specific logic. It belongs alongside `GeocodingService`, `What3WordsService`, and `ConfigService` in `Services/`. The `Features/Routing/` directory currently contains only this one file.

### 1b. `MapViewModel` and its display types are defined inside `MapView.swift`
`MapViewModel`, `UndoRecord`, `WaypointDisplay`, `MapCoordinate`, `LabelData`, `LabelCommand`, `ViaWaypoint`, `RouteDisplay`, and `TrackDisplay` are all declared in `MapView.swift`. The ViewModel class should have its own file. The display/transfer structs belong in `Models/` or a dedicated `MapModels.swift`.

**File:** `Features/Map/MapView.swift`

### 1c. `WaypointSummary` and `WaypointListSection` are defined in `DatabaseManager.swift`
These are presentation/projection types used by UI sheets. They belong in `Models/` or alongside `WaypointRecords.swift`, not inside the database access layer.

**File:** `Database/DatabaseManager.swift`

### 1d. `Notification.Name` extensions defined in `MapView.swift`
The four `routeKeeper*` notification names are used by `LibrarySidebarView`, `ContentView`, `LibraryBottomPanel`, and `RouteKeeperApp` — they are app-level infrastructure, not map-specific. Moving them to `RouteKeeperApp.swift` or a standalone `Notifications.swift` would make them discoverable.

**File:** `Features/Map/MapView.swift`

### 1e. `AddressData` is defined in `GeocodingService.swift` but used by the database layer
`AddressData` is accepted by `DatabaseManager.createWaypoint()`, `DatabaseManager.updateWaypoint()`, and `DatabaseManager.updateWaypointAddress()`. It is a model type that predates any geocoding call and belongs in `Models/`.

**File:** `Services/GeocodingService.swift`

### 1f. `PreferencesManager` is the only occupant of `Managers/`
There is no architectural distinction between `Services/` and `Managers/`. `PreferencesManager` is a singleton service; placing it in a uniquely named folder adds friction without adding clarity. Consolidate into `Services/`.

---

## 2. MVVM & Separation of Concerns

### 2a. `ContentView` contains heavy async business logic
`handleSingleItemSelection`, `buildMultiItemsJson`, `handleMultiItemDisplay`, and `fetchItemsForList` all live directly in `ContentView`. These functions fetch from the database, call Valhalla, build JSON payloads, and manage route state. A View should not be responsible for these operations. They belong in a ViewModel — either an expanded `MapViewModel` or a dedicated `ContentViewModel`.

**File:** `ContentView.swift`

### 2b. Route recalculation logic is duplicated in at least five places
Nearly identical "fetch points → call Valhalla → apply snapped coordinates → persist geometry → rebuild RouteDisplay" blocks appear in:
- `ContentView.handleSingleItemSelection` (route case)
- `ContentView.buildMultiItemsJson` (route case)
- `MapView.Coordinator` (`waypointDragged` handler)
- `MapView.Coordinator` (`insertShapingPoint` handler)
- `MapView.Coordinator.recalculateAndRedraw`
- `RoutePropertiesSheet.save()`

This should be a single `recalculateRoute(itemId:)` method on a ViewModel or service.

**Files:** `ContentView.swift`, `Features/Map/MapView.swift`, `Features/Routes/RoutePropertiesSheet.swift`

### 2c. `MapView.Coordinator` makes direct database and service calls, and shows `NSAlert`
The Coordinator is UI infrastructure (an `NSViewRepresentable` coordinator). It directly calls `DatabaseManager.shared`, `RoutingService.shared`, and presents an `NSAlert` for the "Update Route Waypoints?" prompt. These operations belong in the ViewModel layer. The `NSAlert` in particular is an AppKit modal shown from inside a WKWebView message handler — it should be mediated through a SwiftUI `confirmationDialog` on the ViewModel.

**File:** `Features/Map/MapView.swift`

### 2d. `RoutePropertiesSheet.save()` contains DB writes and Valhalla recalculation
The `save()` method in `RoutePropertiesSheet` fetches route points, calls Valhalla, writes the result, and reports errors — all directly from the View. This logic belongs in a ViewModel.

**File:** `Features/Routes/RoutePropertiesSheet.swift`

### 2e. `LibrarySidebarView.performExport()` makes direct database calls
The `performExport` method calls `DatabaseManager.shared.fetchItemsForExport()` directly from the View. Export logic should flow through `LibraryViewModel`.

**File:** `Features/Library/LibrarySidebarView.swift`

### 2f. `GeneralSettingsView` accesses `PreferencesManager.shared` directly
`GeneralSettingsView` uses the global singleton rather than receiving the manager as an `@Environment` dependency — inconsistent with the pattern used by `APIKeysSettingsView`, which correctly uses `@Environment(APIKeysManager.self)`.

**File:** `Features/Settings/GeneralSettingsView.swift`

---

## 3. Native vs Custom UI

### 3a. `Color(itemHex:)` duplicates `Color(hex:)` in `ColourSwatch.swift`
Two `Color` initialisers with identical implementations exist side by side: `Color(hex:)` in `ColourSwatch.swift` and `Color(itemHex:)` in `LibrarySidebarView.swift`. One should be removed and all call sites updated to use the surviving one.

**Files:** `Shared/ColourSwatch.swift`, `Features/Library/LibrarySidebarView.swift`

### 3b. `NSAlert` inside `MapView.Coordinator` bypasses SwiftUI's dialog system
The "Update Route Waypoints?" alert is presented via `NSAlert.runModal()` directly inside a `WKScriptMessageHandler`. This is an AppKit modal called from a background-style handler and cannot be driven by SwiftUI state. Replacing it with a confirmation dialog mediated through `MapViewModel` would keep the UI layer consistent and testable.

**File:** `Features/Map/MapView.swift`

### 3c. `DoubleClickHandler` — custom `NSViewRepresentable` for double-click
A custom `NSView` subclass is used to intercept double-click events because SwiftUI's `onTapGesture(count: 2)` interfered with list row selection at the time it was written. This should be revisited as SwiftUI's gesture handling on macOS improves with each OS release.

**File:** `Features/Library/LibrarySidebarView.swift`

---

## 4. Swift Conventions & Modern APIs

### 4a. `KeychainManager` uses `UserDefaults`, not the system Keychain
Despite its name, `KeychainManager` is a `UserDefaults` wrapper. API keys stored in `UserDefaults` are readable in plaintext by anyone with container access. The type should be renamed to avoid the false security implication, and eventually replaced with a real `Security.framework` Keychain implementation.

**File:** `Services/KeychainManager.swift`

### 4b. `RoutingService.calculateRoute(from:to:)` appears to be dead code
The two-argument form of `calculateRoute` has its own in-memory cache and is fully implemented, but no current call site uses it — all production paths call `calculateRoute(through:)`. If it is truly unused, it should be removed. Its presence also makes the cache asymmetry (present for 2-point, absent for multi-point) invisible.

**File:** `Features/Routing/RoutingService.swift`

### 4c. Hardcoded `"motorcycle"` costing model string appears in multiple files
The string literal `"motorcycle"` is used in `RoutingService`, `DatabaseManager.createRoute()`, `DatabaseManager.importGPXResult()`, and the `routes` schema's `routing_profile` default. Extract as a constant to avoid silent divergence.

**File:** `Features/Routing/RoutingService.swift`, `Database/DatabaseManager.swift`

### 4d. `app_settings` key strings are raw literals scattered across multiple files
The keys `"map_style"`, `"units"`, `"defaultExportFormat"`, `"selected_list_id"`, and `"selected_item_ids"` appear as string literals in `DatabaseManager`. A typo in any one call site produces a silent miss at runtime. Define them as a `private enum` of constants adjacent to the methods that use them.

**File:** `Database/DatabaseManager.swift`

### 4e. `print()` used for logging throughout instead of `os.log` / `Logger`
`ConfigService` uses `Logger` correctly. Every other file uses `print()` for both debug tracing and error reporting. Production code should use structured logging with a subsystem and category so logs are filterable in Console.app. Key callouts: `print("JS → Swift: \(body)")` logs every bridge message in production, and `print("Routing: calling Valhalla API …")` logs every network request.

**Files:** `Features/Map/MapView.swift`, `Features/Routing/RoutingService.swift`, `Features/Library/LibraryViewModel.swift`, and others.

### 4f. `Task.sleep` in `LibrarySidebarView.cycleSelection()` is fragile
A 50 ms sleep forces a brief deselection to make SwiftUI re-evaluate the map display after an edit sheet saves. This is a timing-dependent workaround. A proper ViewModel signal or a dedicated `refreshToken` observable property would be reliable without a sleep.

**File:** `Features/Library/LibrarySidebarView.swift`

---

## 5. Naming & Consistency

### 5a. British/American spelling mix for "colour"
The codebase uses both spellings inconsistently:

- **British:** `waypointPresetColours`, `Track.presetColours`, `ColourSwatch.swift`, `LibraryBottomPanel.iconColor(for:)` (mixed), `items.colour` column
- **American:** `colorHex`, `selectedColorHex`, `Route.colorHex`, `routePresetColours`, `color_hex` (all DB column names)

Pick one convention and apply it throughout. American spelling (`color`) already dominates in the DB schema and model properties.

**Files:** `Shared/ColourSwatch.swift`, `Models/ItemRecords.swift`, `Features/Library/LibraryBottomPanel.swift`

### 5b. `waypointPresetColours` and `routePresetColours` are identical arrays
Both arrays in `ColourSwatch.swift` contain exactly the same eight hex values. There is no differentiation between waypoint and route colour palettes. Merge into a single constant or make one reference the other.

**File:** `Shared/ColourSwatch.swift`

### 5c. `ShowLabelsButton.swift` filename does not match the type it contains
The file is named `ShowLabelsButton.swift` but contains the `ShowLabelsPanel` struct. The filename should match the primary type.

**File:** `Features/Map/ShowLabelsButton.swift`

### 5d. SF Symbol → base64 rendering has three overlapping implementations
`sfSymbolBase64()`, `categoryIconBase64()`, and `categoryIconBase64Compact()` are all defined in `MapView.swift` and render essentially the same concept (SF Symbol as a PNG). `sfSymbolBase64` appears unused in production paths. The two `categoryIcon*` functions differ only in their default parameter values. Consolidate into one parameterised function.

**File:** `Features/Map/MapView.swift`

### 5e. `lineStringMidpoint` / `trackMidpoint` / `lineMidpoint` — three copies of the same algorithm
The geometric midpoint algorithm is implemented three times: as `lineStringMidpoint()` in `ContentView.swift`, `trackMidpoint()` in `MapView.swift`, and `lineMidpoint()` in `MapLibreMap.html`. The Swift versions should be one function; the JS version is necessarily separate but should be noted as a parity dependency.

**Files:** `ContentView.swift`, `Features/Map/MapView.swift`, `Resources/MapLibreMap.html`

---

## 6. Documentation & Dead Code

### 6a. Dead database columns — schema carries significant dead weight
Several schema columns are defined, have corresponding model properties, but are never written to by any current code path:

| Column | Table | Status |
|--------|-------|--------|
| `geojson` | `routes` | Superseded by `geometry`; never written |
| `colour` | `items` | Never written; actual colour is in `waypoints.color_hex` / `routes.color_hex` |
| `description` | `items` | Never written or displayed |
| `geojson` | `tracks` | Never written |
| `distance_metres` | `tracks` | Never written |
| `duration_seconds` | `tracks` | Never written |
| `recorded_at` | `tracks` | Never written (import writes `timestamp` instead) |
| `is_smart` / `smart_rule` | `lists` | Unimplemented feature; never read or written |
| `parent_folder_id` | `list_folders` | Unimplemented feature; folder nesting never used |

These can be removed in a future schema migration. Until then they add noise to every `SELECT *` query and inflate the model structs.

**File:** `Database/DatabaseManager.swift`, `Models/ItemRecords.swift`, `Models/LibraryRecords.swift`

### 6b. Dangling doc comment / duplicate MARK in `DatabaseManager.swift`
Around line 1335, there is an orphaned doc comment ("- Returns: A tuple of (routeCount, waypointCount, listName)…") that refers to `importGPXResult`, immediately followed by `// MARK: - Track operations`. The actual `importGPXResult` implementation is a further 60 lines below under a second `// MARK: - GPX Import`. The first MARK and the orphaned comment should be removed or relocated.

**File:** `Database/DatabaseManager.swift`

### 6c. Debug `print` statements left in production-path code
Two categories of debug logging should be removed or gated before release:
1. `print("JS → Swift: \(body)")` in `MapView.Coordinator.userContentController` logs the raw payload of every bridge message to the console.
2. `print("Routing: calling Valhalla API …")` and `print("Routing: received … points")` in `RoutingService` log every network request and response.

**Files:** `Features/Map/MapView.swift`, `Features/Routing/RoutingService.swift`

### 6d. `Route.routingProfile` is always `"motorcycle"` and never varies
The `routing_profile` column in the `routes` table is set to `"motorcycle"` on every insert and never read back for any routing decision. If multi-costing-model support is not planned, the column and model field are dead weight. If it is planned, the field name and usage need to be revised (`"motorcycle"` is a Valhalla costing model name, not a profile category).

**File:** `Models/ItemRecords.swift`, `Database/DatabaseManager.swift`

---

## Summary

**Total findings: 23** across 6 themes.

| # | Theme | Findings | Priority |
|---|-------|----------|----------|
| 1 | Architecture & File Placement | 6 | Medium — no bugs, but hinders navigation |
| 2 | MVVM & Separation of Concerns | 6 | High — views doing DB/network work is fragile as the app grows |
| 3 | Native vs Custom UI | 3 | Low — mostly fine, flagged for periodic re-evaluation |
| 4 | Swift Conventions & Modern APIs | 6 | Medium — security concern in 4a (`KeychainManager`), hygiene elsewhere |
| 5 | Naming & Consistency | 5 | Low — friction only, no bugs |
| 6 | Documentation & Dead Code | 4 | Medium — dead schema columns add schema noise and inflate model types |

### Recommended priorities

**Do first:**
- **2b** (duplicate recalculation logic) — the highest duplication risk; a bug fix in one copy may not be applied to the others.
- **4a** (`KeychainManager` misnaming / UserDefaults) — the security implication of the name is misleading and the storage choice is a real concern for API keys.
- **6a** (dead database columns) — clean up in a single `v8` migration before the schema grows further.

**Do when refactoring nearby code:**
- **2a / 2c / 2d** (business logic in views) — address incrementally as features are revisited.
- **1b** (split `MapView.swift`) — high-value separation that makes `MapViewModel` easier to test.
- **5a** (spelling consistency) — low risk, high readability payoff.

**Defer:**
- **3a–3c** (custom UI components) — all functional; revisit when targeting newer OS versions.
- **1a, 1c, 1d, 1e, 1f** (file placement) — purely organisational; no runtime impact.
