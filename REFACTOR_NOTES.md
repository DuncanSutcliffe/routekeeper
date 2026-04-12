# RouteKeeper — Refactor Notes

**Audit date:** 2026-04-12  
**Auditor:** Claude Code  
**Scope:** Full codebase review — structural cleanliness, Swift best practice, architectural correctness. No functional changes; findings are marked with `// TODO: [REFACTOR]` comments in the source.

---

## How to read this document

Each finding includes:
- **File** — where the issue lives (relative to `RouteKeeper/RouteKeeper/`)
- **Issue** — what the problem is
- **Why it matters** — the practical consequence

Findings are grouped by theme. Within each theme they are roughly ordered by severity (most impactful first).

---

## 1. Architecture & File Placement

### 1.1 `RoutingService` is in the wrong folder
**File:** `Features/Routing/RoutingService.swift`  
**Issue:** `RoutingService` lives under `Features/Routing/` while every other service (`GeocodingService`, `ConfigService`) lives under `Services/`. There is no feature-specific UI or state in this file — it is a pure networking service.  
**Why it matters:** A developer looking for services will find two of the three in `Services/` and miss the third. Inconsistent placement makes the project harder to navigate.

### 1.2 `WaypointSummary` is defined inside `DatabaseManager.swift`
**File:** `Database/DatabaseManager.swift`  
**Issue:** `WaypointSummary` is a lightweight DTO used by `WaypointPickerSheet`. It is not a database management concern and does not belong inside the actor file.  
**Why it matters:** Model types should live in `Models/` so they can be found alongside `WaypointRecords.swift`. The current placement also raises a secondary question: `WaypointSummary` has the same fields as `Waypoint` — the separate type may be unnecessary.

### 1.3 `MapViewModel` is defined inside `MapView.swift`
**File:** `Features/Map/MapView.swift`  
**Issue:** `MapViewModel` (an `@Observable` class) and `MapView` (an `NSViewRepresentable`) are in the same file. Every other ViewModel in the project has its own file (`LibraryViewModel.swift`).  
**Why it matters:** Mixing the view model and the view in one file obscures the separation of concerns. A file named `MapView.swift` should contain only the view; the ViewModel belongs in `Features/Map/MapViewModel.swift`.

### 1.4 `MultiItemEntry` DTO is defined inside `ContentView.swift`
**File:** `ContentView.swift`  
**Issue:** `MultiItemEntry` is a JSON serialisation type used to pass map data to JavaScript. It is a map-layer concern, not a root-view concern.  
**Why it matters:** It should live in `Features/Map/` (alongside the map bridge logic that uses it) or in `Models/`. Its presence in `ContentView.swift` inflates a file that is already doing too much.

### 1.5 `RouteEditSheet.swift` is an empty dead file
**File:** `Features/Routes/RouteEditSheet.swift`  
**Issue:** The file body is a single comment: "Renamed to `RouteWaypointSheet.swift` — remove this file from the Xcode target." The file has never been removed.  
**Why it matters:** Dead files pollute the project navigator, confuse new contributors, and can create build warnings. It should be deleted and removed from the Xcode target.

### 1.6 Export model types are co-located with the exporter logic
**File:** `Features/GPX/GPXExporter.swift`  
**Issue:** `ExportWaypoint`, `ExportRoutePoint`, `ExportRoute`, `ExportTrackPoint`, `ExportTrack`, and `ExportItem` are all defined in the same file as `GPXExporter`. The file is growing long as a result.  
**Why it matters:** Keeping model types separate from transformation logic is a standard layering practice. A companion `ExportModels.swift` would make `GPXExporter.swift` shorter and make the model types independently discoverable.

### 1.7 `DoubleClickHandler` and `cursor()` are buried in `LibrarySidebarView.swift`
**File:** `Features/Library/LibrarySidebarView.swift`  
**Issue:** `DoubleClickHandler` (an `NSViewRepresentable`) and the `cursor(_:)` view extension are defined as private types at the bottom of the sidebar file.  
**Why it matters:** Both are reusable utilities that are not specific to the library sidebar. Placing them in `Shared/` would make them available to future views without copying.

---

## 2. MVVM & Separation of Concerns

The most significant structural pattern in the codebase is Views calling `DatabaseManager.shared` and `RoutingService.shared` directly, bypassing the ViewModel layer entirely. This affects multiple sheets and `ContentView` itself.

### 2.1 `ContentView` performs database reads directly
**File:** `ContentView.swift`  
**Issue:** `handleSingleItemSelection()` and `fetchItemsForList()` call `DatabaseManager.shared` methods. `buildMultiItemsJson()` assembles the JSON payload for the JavaScript bridge.  
**Why it matters:** `ContentView` is already the coordinator between `LibraryViewModel` and `MapViewModel`. Adding database access here means it is acting as a third ViewModel. All three methods should move into the appropriate ViewModel (`LibraryViewModel` or `MapViewModel`).

### 2.2 `NewRouteSheet` calls the database on appear
**File:** `Features/Routes/NewRouteSheet.swift`  
**Issue:** The `.onAppear` block calls `DatabaseManager.shared.fetchRoutingProfiles()` and `DatabaseManager.shared.fetchDefaultRoutingProfile()` directly.  
**Why it matters:** Views should receive data from a ViewModel, not fetch it themselves. This bypasses the `LibraryViewModel` that is already passed into the sheet and makes the sheet untestable without a live database.

### 2.3 `RoutePropertiesSheet` owns its own data loading and saves
**File:** `Features/Routes/RoutePropertiesSheet.swift`  
**Issue:** `loadData()` calls `DatabaseManager.shared.fetchRoutingProfiles()` and `fetchRouteRecord()`. `save()` calls `updateRouteProperties()` and `RoutingService.shared.calculateRoute()`.  
**Why it matters:** A sheet that fetches, mutates, and persists its own data is acting as its own ViewModel. The logic belongs in a `RouteViewModel` (or extended `LibraryViewModel`) and the sheet should just present bindings.

### 2.4 `RouteWaypointSheet` calls the routing service directly
**File:** `Features/Routes/RouteWaypointSheet.swift`  
**Issue:** `save()` fetches route criteria from the database, calls `RoutingService.shared.calculateRoute()`, and writes the result back — all from inside a View.  
**Why it matters:** The same issue as 2.3. The recalculation orchestration is business logic that should be in a ViewModel or service coordinator, not embedded in a sheet.

### 2.5 `WaypointPickerSheet` fetches its own data
**File:** `Features/Routes/WaypointPickerSheet.swift`  
**Issue:** The `.task` modifier calls `DatabaseManager.shared.fetchAllWaypoints()` directly. `LibraryViewModel` already has `loadAvailableWaypoints()` / `availableWaypoints` which covers the same data.  
**Why it matters:** Duplicates data-fetching logic that already exists in the ViewModel and creates an unnecessary direct dependency from a leaf View to the database actor.

### 2.6 `RoutingProfilesSheet` has no ViewModel at all
**File:** `Features/RoutingProfiles/RoutingProfilesSheet.swift`  
**Issue:** All state management, data loading, profile creation/deletion, and database writes are handled inside the View struct itself. It is the only sheet in the project with no ViewModel backing.  
**Why it matters:** The sheet is long and hard to follow. A `RoutingProfilesViewModel` would make the data flow testable and keep the view focused on layout.

### 2.7 `LibrarySidebarView` context menus call the database directly
**File:** `Features/Library/LibrarySidebarView.swift`  
**Issue:** Context menu actions use `try? await DatabaseManager.shared.fetchListItemCount()`, `folderHasItems()`, `fetchItemIdsForList()`, and `fetchItemIdsForFolder()` inline. Errors are silently discarded with `try?`.  
**Why it matters:** Silent error discard means that if a database call fails, the user sees no feedback and the action silently no-ops. These checks should be ViewModel methods that can surface errors properly.

### 2.8 `fetchElevation()` is duplicated across two Views
**File:** `Features/Library/NewWaypointSheet.swift`, `Features/Waypoints/EditWaypointSheet.swift`  
**Issue:** Both sheets contain an identical private `fetchElevation(latitude:longitude:)` method that calls the MapTiler Elevation API, parses the JSON response by hand, and updates local state.  
**Why it matters:** Duplicated network logic means any fix to the elevation fetch (URL format change, response parsing update) must be applied in two places. A shared `ElevationService` in `Services/` is the correct home.

### 2.9 List-assignment UI is triplicated across sheets
**File:** `Features/Library/NewWaypointSheet.swift`, `Features/Waypoints/EditWaypointSheet.swift`, `Features/Routes/NewRouteSheet.swift`  
**Issue:** The `listsSection` computed property — a `VStack` of `Toggle(.checkbox)` rows over an `allLists` array — is copy-pasted almost verbatim into all three sheets.  
**Why it matters:** Three copies of the same layout means three places to update when the design changes. A shared `ListAssignmentView` component in `Shared/` accepting `allLists` and a `Binding<Set<Int64>>` would eliminate the duplication entirely.

### 2.10 Routing criteria UI is duplicated across two sheets
**File:** `Features/Routes/NewRouteSheet.swift`, `Features/Routes/RoutePropertiesSheet.swift`  
**Issue:** `criteriaModified`, `pickerBinding`, `profileSection`, `criteriaToggle()`, and `routeOptimisationRow` are near-identical in both files.  
**Why it matters:** Two copies of routing criteria UI guarantee divergence over time. A shared `RoutingCriteriaView` accepting bindings for the five criteria flags, a profiles array, and a baseline profile would serve both sheets.

### 2.11 `EditWaypointSheet.canSubmit` requires list membership; `NewWaypointSheet` does not
**File:** `Features/Waypoints/EditWaypointSheet.swift`  
**Issue:** `canSubmit` requires `!selectedListIDs.isEmpty`, meaning a waypoint cannot be saved with no list assignment. `NewWaypointSheet` has no such requirement; waypoints can be created unclassified.  
**Why it matters:** Inconsistent validation rules between create and edit for the same object type. Either both sheets should enforce or both should allow empty list assignment.

---

## 3. Native vs Custom UI

### 3.1 `MapStylePicker` reimplements a segmented control from scratch
**File:** `Features/Map/MapStylePicker.swift`  
**Issue:** The three style buttons are styled manually with `Button`, `background`, `cornerRadius`, and colour comparisons to determine which button appears "active". This is a hand-rolled segmented control.  
**Why it matters:** `Picker` with `.pickerStyle(.segmented)` is the native SwiftUI equivalent and would produce the standard macOS segmented appearance with no custom layout code. The custom version will diverge from the system look on future macOS releases.

### 3.2 `DoubleClickHandler` works around a SwiftUI `List` double-tap limitation
**File:** `Features/Library/LibrarySidebarView.swift`  
**Issue:** `DoubleClickHandler` wraps an `NSView` subclass that overrides `mouseDown(with:)` to detect double-clicks, because `.onTapGesture(count: 2)` does not fire reliably on rows inside a SwiftUI `List` on macOS.  
**Why it matters:** This is a legitimate workaround for a known SwiftUI/AppKit integration gap. It should be documented as such (a comment explaining why the native gesture recogniser cannot be used here) so future developers do not replace it with `.onTapGesture(count: 2)` and reintroduce the regression.

### 3.3 `Color(itemHex:)` duplicates the existing `Color(hex:)` initialiser
**File:** `Features/Library/LibrarySidebarView.swift`  
**Issue:** A private `Color(itemHex:)` extension is defined locally in `LibrarySidebarView.swift`. `ColourSwatch.swift` already defines `Color(hex:)` with equivalent behaviour.  
**Why it matters:** Two initialisers doing the same thing means future changes (e.g. adding support for 3-digit shorthand hex) must be applied in two places. The local variant should be removed and the call sites changed to use `Color(hex:)`.

### 3.4 The "selectedItems cycle" uses `Task.sleep` to work around SwiftUI diffing
**File:** `Features/Library/LibrarySidebarView.swift`  
**Issue:** Three context-menu actions (edit waypoint, edit route, add-to-list) clear `selectedItems`, sleep for 50 ms (`Task.sleep(nanoseconds: 50_000_000)`), and then restore the selection. The intent is to force the `.task(id: selectedItems)` modifier in `ContentView` to re-fire after a mutating operation.  
**Why it matters:** Sleeping to let the event loop catch up is a fragile timing workaround. If the sleep duration is too short on a slow machine the re-trigger will be missed; if it is too long the UI stutters. The correct pattern is an explicit, dedicated signal — for example a `mapRefreshToken: UUID` published on the ViewModel — that ContentView's `.task(id:)` observes instead of `selectedItems` directly.

### 3.5 `RoutingProfilesSheet` uses `TextField` for inline rename instead of system list edit
**File:** `Features/RoutingProfiles/RoutingProfilesSheet.swift`  
**Issue:** Profile renaming is implemented by embedding a `TextField(.plain)` into the `List` row and toggling it visible via an `isEditing` flag. This is essentially a custom inline-edit control.  
**Why it matters:** macOS `List` rows support rename via `.renameAction` / `focusedValue` in newer SwiftUI, and table cells support native editing. The custom approach replicates platform behaviour with more code and a different visual result. Adopting the native pattern where available would reduce code and improve consistency with macOS conventions.

### 3.6 `GeneralSettingsView` and `ExportSettingsView` use manual `Binding(get:set:)` instead of `@Bindable`
**File:** `Features/Settings/GeneralSettingsView.swift`, `Features/Settings/ExportSettingsView.swift`  
**Issue:** Both views construct bindings to `PreferencesManager` properties using the verbose `Binding(get: { prefs.units }, set: { prefs.units = $0 })` pattern.  
**Why it matters:** Swift 5.9 introduced `@Bindable` for `@Observable` objects. Wrapping `PreferencesManager` with `@Bindable` and using `$prefs.units` syntax is idiomatic, less verbose, and less error-prone. The manual `Binding` pattern predates `@Observable` and should be updated.

---

## 4. Swift Conventions & Modern APIs

### 4.1 Force-unwrapped `URL(string:)` in `RoutingService`
**File:** `Features/Routing/RoutingService.swift`  
**Issue:** The Valhalla endpoint URL is constructed with `URL(string: valhallaURL)!`. A bad configuration value (e.g. a typo in the URL string) will crash the app at runtime.  
**Why it matters:** The URL is effectively a compile-time constant. It should be declared as a `static let` with a `guard let` or a `precondition` that gives a clear failure message, not a bare force-unwrap whose crash message offers no context.

### 4.2 Force-unwrapped `URLComponents(string:)` in `GeocodingService`
**File:** `Services/GeocodingService.swift`  
**Issue:** `URLComponents(string: nominatimSearchURL)!` and `URLComponents(string: nominatimReverseURL)!` use force-unwraps on static string literals.  
**Why it matters:** Same issue as 4.1. These are constants that never change at runtime. They should fail loudly at startup with a useful message, not silently crash mid-use. Use `static let` with a compile-time-safe URL literal approach or a `precondition`.

### 4.3 `ConfigService.apiKey` performs file I/O on every access
**File:** `Services/ConfigService.swift`  
**Issue:** `ConfigService.apiKey` is a computed `static var` that calls `Bundle.main.url(forResource:)` and `NSDictionary(contentsOf:)` every time it is read. It is accessed for every JS injection, every map style load, and every elevation request.  
**Why it matters:** Repeated file I/O for a value that never changes at runtime is wasteful. It should be a `static let` that reads the plist once. `NSDictionary(contentsOf:)` is also a legacy Objective-C API — `PropertyListDecoder` or `Bundle` property list loading are the modern Swift equivalents.

### 4.4 JavaScript message type strings are untyped
**File:** `Features/Map/MapView.swift`  
**Issue:** Message type identifiers exchanged over the JS bridge (`"mapReady"`, `"routeDrawn"`, `"mapContextMenu"`, `"addWaypointAtCoordinate"`, `"mapStyleLoaded"`) are compared with raw string literals scattered through the `userContentController(_:didReceive:)` switch.  
**Why it matters:** A typo in any string — in Swift or in JavaScript — causes silent message loss with no compile-time warning. An `enum JSMessageType: String` would make the set of legal message types explicit and let the compiler flag exhaustiveness.

### 4.5 JavaScript is constructed via string interpolation without escaping
**File:** `Features/Map/MapView.swift`  
**Issue:** Multiple methods (`applyRouteDisplay`, `applyMultiDisplay`, `executeDrawRoute`) build JavaScript call strings by interpolating Swift values directly — e.g. `"showRoute('\(escaped)')"`. The manual escaping (replacing `\` and `'`) is ad-hoc and does not cover all edge cases (e.g. embedded newlines in GeoJSON).  
**Why it matters:** Malformed GeoJSON or a route name containing a single-quote will produce invalid JavaScript that either silently fails or throws a JS exception. `WKWebView.callAsyncJavaScript(_:arguments:)` (available since macOS 10.15) accepts a typed `[String: Any]` argument dictionary and handles all encoding automatically — this is the correct API for passing data to JS from Swift.

### 4.6 `webView.setValue(false, forKey: "drawsBackground")` uses fragile KVC
**File:** `Features/Map/MapView.swift`  
**Issue:** The WKWebView background is cleared by calling `setValue(false, forKey: "drawsBackground")`, a private KVC key with no public API backing.  
**Why it matters:** Private KVC keys can be removed in any OS update without notice. Since macOS 12, `WKWebView` exposes `underPageBackgroundColor` and `isOpaque` as public properties that achieve the same result without relying on private API.

### 4.7 `PreferencesManager.save()` wraps a synchronous `UserDefaults` write in a detached `Task`
**File:** `Managers/PreferencesManager.swift`  
**Issue:** `save()` is called in a detached `Task { }` from property setters. `UserDefaults.standard.set(_:forKey:)` is synchronous and thread-safe — there is no reason to dispatch it to a background task.  
**Why it matters:** The unnecessary `Task` indirection makes the write asynchronous from the caller's perspective (even though UserDefaults is synchronous internally), adds overhead, and can theoretically cause ordering issues if two rapid writes race. Direct synchronous calls are clearer and correct.

### 4.8 `RouteStatsOverlay` reads `PreferencesManager.shared` directly
**File:** `Features/Map/RouteStatsOverlay.swift`  
**Issue:** The overlay reads `PreferencesManager.shared.units` inline to decide whether to display kilometres or miles.  
**Why it matters:** A view that reaches out to a global singleton for a configuration value is harder to preview and test. Accepting `units: String` as a parameter and letting the caller pass the value from the ViewModel makes the view self-contained and previewable.

### 4.9 Hardcoded window size in `RouteKeeperApp`
**File:** `App/RouteKeeperApp.swift`  
**Issue:** The initial window size is set to `width: 1200, height: 750` as bare integer literals.  
**Why it matters:** Magic geometry constants should be named. A `private extension CGSize` or a `private enum Layout` with named constants documents intent and makes future adjustments to window defaults a one-line change.

### 4.10 Hardcoded colour constants duplicated across multiple files
**File:** `Models/ItemRecords.swift`, `Models/WaypointRecords.swift`, `Database/DatabaseManager.swift`, `ContentView.swift`  
**Issue:** The default route colour `"#1A73E8"` appears in at least four files. The default waypoint colour `"#E8453C"` appears in at least two files plus the database schema `DEFAULT` clause.  
**Why it matters:** Any rebranding or accessibility adjustment requires a grep-and-replace across multiple files. Both constants should be defined once — for example in `ColourSwatch.swift` or a dedicated `AppColours.swift` — and referenced by name everywhere else.

---

## 5. Naming & Consistency

### 5.1 British / American spelling is mixed throughout
**File:** `Shared/ColourSwatch.swift` and many others  
**Issue:** The codebase uses British spelling in some identifiers (`ColourSwatch`, `colour` column in `items`, `colorHex` in `waypoints` and `routes`) and American spelling in others (`colorHex`, `Color(hex:)`). The database schema itself has both: the `items.colour` column vs the `waypoints.color_hex` column.  
**Why it matters:** Inconsistent spelling creates ambiguity — a developer searching for "color" will miss "colour" hits and vice versa. A codebase-wide decision (one or the other) should be made and applied uniformly. Because Swift's own APIs use American spelling, American spelling is the pragmatic choice.

### 5.2 `fetchAllWaypoints` and `fetchWaypointsWithCoordinates` do near-identical work
**File:** `Database/DatabaseManager.swift`  
**Issue:** `fetchAllWaypoints() -> [WaypointSummary]` returns a lightweight DTO (`WaypointSummary`) used by one call site. `fetchWaypointsWithCoordinates() -> [Waypoint]` returns full `Waypoint` records and is used by `LibraryViewModel`. Both query the `waypoints` table with only minor differences.  
**Why it matters:** Two methods with similar names and overlapping purposes are a maintenance trap. If `WaypointSummary` is eliminated (see finding 1.2), `fetchAllWaypoints` can be removed entirely and its caller updated to use `fetchWaypointsWithCoordinates`.

### 5.3 `RouteList` naming conflicts with the standard library `List` view
**File:** `Models/LibraryRecords.swift`  
**Issue:** The model type is named `RouteList`, but it represents any named collection (waypoints, routes, or tracks) — not specifically a list of routes. The name was presumably chosen to avoid clashing with SwiftUI's `List` view.  
**Why it matters:** The name is actively misleading about the model's scope. A name like `ItemList` or `LibraryList` would be both accurate and collision-safe. This is a higher-effort change (affects many call sites) but worth noting.

### 5.4 `MultiItemEntry` is named for its JSON structure, not its domain meaning
**File:** `ContentView.swift`  
**Issue:** `MultiItemEntry` encodes a map display item as JSON. The name describes the technical JSON container (`entry`) rather than what the value represents in the domain.  
**Why it matters:** A name like `MapDisplayItem` or `MapLayerEntry` would communicate intent to a reader unfamiliar with the JSON bridge. This is a minor polish issue but consistent naming aids discoverability.

### 5.5 `RoutingService` is the only `Service` not in the `Services/` folder
**File:** `Features/Routing/RoutingService.swift`  
**Issue:** (Cross-reference with finding 1.1.) The service is named following the `*Service` convention but is not in the `Services/` folder.  
**Why it matters:** Naming convention and folder convention are both violated. The fix is the same move described in 1.1.

### 5.6 `load()` vs `reload()` asymmetry in `LibraryViewModel`
**File:** `Features/Library/LibraryViewModel.swift`  
**Issue:** `reload()` is a public method with a documentation comment. `load(sortColumn:ascending:)` is also public but has no documentation comment and is called directly from several places. The existence of both names without clear guidance on which to use from outside the class creates ambiguity.  
**Why it matters:** Either `load` should be made `private` (and all external callers changed to `reload`), or the two methods should be consolidated. The current state where both are public but only one is documented will confuse future contributors.

---

## 6. Documentation & Dead Code

### 6.1 `RouteEditSheet.swift` is an empty dead file
**File:** `Features/Routes/RouteEditSheet.swift`  
**Issue:** (Cross-reference with finding 1.5.) The file body is a comment saying the file was renamed to `RouteWaypointSheet.swift`. No type, extension, or import is defined.  
**Why it matters:** Dead files that are still part of the Xcode target are compiled on every build (even if they produce no object code). The file should be deleted and removed from the target.

### 6.2 `Route.geojson` is a legacy field that predates `Route.geometry`
**File:** `Models/ItemRecords.swift`  
**Issue:** `Route` has both a `geojson: String?` field and a `geometry: String?` field. The `geometry` column was introduced in schema v5 as the replacement for `geojson`. The `geojson` column no longer appears to be written by any code path and is never read back.  
**Why it matters:** Unused schema columns consume storage and make the data model harder to understand. A new migration should `ALTER TABLE routes DROP COLUMN geojson` and the Swift property should be removed.

### 6.3 `RoutingService.calculateRoute(from:to:)` is dead code
**File:** `Features/Routing/RoutingService.swift`  
**Issue:** The two-argument overload `calculateRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D)` includes a caching layer (`cache` dictionary, `cacheKey` helper, `buildRequest` private method). No call site in the codebase uses this overload; all routing goes through the multi-waypoint `calculateRoute(through:...)` method.  
**Why it matters:** Dead code is compiled, tested against, and read by developers — all for no benefit. The two-argument overload, `cacheKey`, `buildRequest`, and the `cache` dictionary should all be removed.

### 6.4 `MapViewModel.drawRoute(geojson:)` and `routeGeoJSON` appear to be legacy
**File:** `Features/Map/MapView.swift`  
**Issue:** `MapViewModel` has a `routeGeoJSON: String?` property and a `drawRoute(geojson:)` method. No call site in `ContentView.swift` or elsewhere calls `mapViewModel.drawRoute()` — all map display goes through `mapViewModel.showRoute()` via `routeDisplay`.  
**Why it matters:** Same as 6.3. If confirmed unused, `routeGeoJSON`, `drawRoute(geojson:)`, and the corresponding `executeDrawRoute` method in the Coordinator should be removed.

### 6.5 `handleSwiftMessage()` in `MapLibreMap.html` is defined but never called
**File:** `Resources/MapLibreMap.html`  
**Issue:** A JavaScript function `handleSwiftMessage(message)` is defined as scaffolding but is never invoked — all Swift-to-JS calls go directly to named functions (`showRoute`, `showWaypoint`, etc.).  
**Why it matters:** Dead JavaScript has the same cost as dead Swift: it is read by developers and creates confusion about whether it is an intended extension point or leftover scaffolding. It should be removed.

### 6.6 `DatabaseManager.fetchRouteGeometry` may be dead code
**File:** `Database/DatabaseManager.swift`  
**Issue:** `fetchRouteGeometry(for routeItemId: Int64) -> String?` fetches only the `geometry` column for a route. Its sole apparent use is in `RouteWaypointSheet.save()`, which calls it to re-fetch the route after editing. If the sheet is refactored to use a ViewModel (finding 2.4), this method may become dead code.  
**Why it matters:** Worth flagging for review during the MVVM refactor — if no call sites remain, the method should be removed.

### 6.7 Several public methods in `LibraryViewModel` lack documentation comments
**File:** `Features/Library/LibraryViewModel.swift`  
**Issue:** `load(sortColumn:ascending:)`, `copyItem(itemId:toList:)`, `moveItem(itemId:fromListId:toList:)`, `removeItemFromList(itemId:listId:)`, `deleteItem(itemId:)`, `deleteList(_:)`, and `deleteFolder(_:)` are all public but have no `///` documentation comments.  
**Why it matters:** The project standard (per CLAUDE.md) is that all public API must have documentation comments. These methods are the primary interface between Views and the database layer and warrant at minimum a one-line description of side-effects and preconditions.

### 6.8 `ExportFormatSheet` reads `PreferencesManager` in a property initialiser
**File:** `Features/GPX/ExportFormatSheet.swift`  
**Issue:** `@State private var selectedFormat = PreferencesManager.shared.exportFormat` reads the preference at struct initialisation time. If the preference changes between the sheet being allocated and `.onAppear` firing, the state will be stale.  
**Why it matters:** Reading mutable shared state in a property initialiser is a subtle ordering hazard. Setting the initial value in `.onAppear` (or passing it as a parameter from the caller) makes the intent explicit and avoids the race.

---

## 7. Summary

The audit identified **48 findings** across the codebase, distributed as follows:

| Theme | Findings |
|---|---|
| 1. Architecture & File Placement | 7 |
| 2. MVVM & Separation of Concerns | 11 |
| 3. Native vs Custom UI | 6 |
| 4. Swift Conventions & Modern APIs | 10 |
| 5. Naming & Consistency | 6 |
| 6. Documentation & Dead Code | 8 |
| **Total** | **48** |

### Recommended priority order

**High — address before adding new features:**

1. **2.8 / 2.9 / 2.10** — Extract `fetchElevation()`, `listsSection`, and the routing criteria UI into shared types. These duplications already cause maintenance overhead and will diverge.
2. **6.1** — Delete `RouteEditSheet.swift`. It is dead weight on every build.
3. **6.2 / 6.3 / 6.4 / 6.5** — Remove the dead `geojson` column, `calculateRoute(from:to:)` overload, `drawRoute`/`routeGeoJSON`, and the JS `handleSwiftMessage` scaffolding.
4. **4.1 / 4.2** — Replace force-unwrapped `URL!` and `URLComponents!` with safe initialisation.

**Medium — address during planned refactors:**

5. **2.1–2.7** — Move database calls out of Views and into ViewModels. This is the largest single structural improvement available.
6. **1.1 / 1.2 / 1.3 / 1.4** — Relocate `RoutingService`, `WaypointSummary`, `MapViewModel`, and `MultiItemEntry` to their correct homes.
7. **4.5** — Switch JS data passing to `callAsyncJavaScript(_:arguments:)` to eliminate manual escaping.
8. **3.6** — Replace manual `Binding(get:set:)` with `@Bindable`.

**Low — polish and consistency:**

9. **5.1** — Decide on British vs American spelling and apply uniformly.
10. **4.3** — Make `ConfigService.apiKey` a `static let`; replace legacy `NSDictionary(contentsOf:)`.
11. **4.6** — Replace private KVC `drawsBackground` with the public `isOpaque` API.
12. **6.7** — Add missing documentation comments to `LibraryViewModel` public methods.
13. **3.1** — Replace the custom `MapStylePicker` button group with `Picker(.segmented)`.
14. **4.9 / 4.10** — Name the hardcoded window size and colour constants.

Every finding has a corresponding `// TODO: [REFACTOR]` comment inserted at the relevant location in the source.
