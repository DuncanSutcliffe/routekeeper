---
name: Don't add debounce to async Swift tasks
description: A Task.sleep debounce in RoutingService caused the Valhalla call to never fire — even on a clean single selection
type: feedback
---

Do not add `Task.sleep` debounces inside actor methods that are called from `.task(id:)` in SwiftUI.

**Why:** `.task(id:)` cancels the previous task when the id changes, but the cancellation also fires on the *first* selection in some cases, causing the sleep to throw `CancellationError` and abort the call before the network request is ever made.

**How to apply:** If rate-limiting is needed for an API, use a cache (already in place in `RoutingService`) rather than a sleep-based debounce. The cache is sufficient to prevent repeated calls for the same coordinates.
