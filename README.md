# RouteKeeper

A macOS application for planning and managing motorcycle routes.
Open-source, free, and built for riders who care about the roads
they ride rather than just the fastest way between two points.

## Why RouteKeeper Exists

Garmin Basecamp has been the only serious desktop route planning
tool for motorcyclists for over a decade. It introduced a genuinely
useful concept: a personal library where routes, waypoints, and
tracks can be organised into folders and lists, with a single item
belonging to multiple lists simultaneously — so a favourite road
can live in "Peak District Rides", "Fuel Stops", and "Group Ride
Routes" without any duplication.

Garmin stopped developing Basecamp years ago. It barely runs on
modern Macs, doesn't support current Apple Silicon hardware
properly, and is no longer a recommended download for some of their
own devices. Nothing else has reproduced what it did well.

RouteKeeper is an attempt to fix that.

## What It Does

- Plan routes on a full-screen map using OpenStreetMap data
- Motorcycle-aware routing that prefers interesting roads over
  fast ones, powered by the Valhalla routing engine
- A proper library management system: folders, lists, and items
  with many-to-many membership — the feature that made Basecamp
  worth using and that no other tool has replicated
- Import and export GPX files, compatible with Garmin devices
  and any other tool that speaks the standard
- Transfer routes directly to connected Garmin Zum