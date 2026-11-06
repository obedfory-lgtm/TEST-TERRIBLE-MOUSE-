# Mobile Memory Studio

An iOS 16+ SwiftUI diagnostic host backed by an embedded `MemoryEngine` dynamic framework. Inspection is limited to byte buffers explicitly registered by the host. This application does not attach to, inject into, or read another process.

## Project layout

- `Sources/MemoryEngine` — registered-region registry, numeric and byte scanning, snapshots, metadata-only session persistence, and export serialization.
- `Sources/DiagnosticHost` — mobile tab navigation, scanner/results screens, in-app draggable overlay, memory map, and Files document export.
- `Tests/MemoryEngineTests` — engine, scan, snapshot, session, and export tests.
- `Tests/DiagnosticHostUITests` — basic navigation and overlay UI test.
- `project.yml` — XcodeGen project definition for the host, embedded dynamic framework, and test targets.
- `Package.swift` — Swift Package definition for the framework and unit tests.
- `ARCHITECTURE.md` — module boundaries, data flow, and access constraints.

## Build

The repository does not include the referenced `3105_DiagnosticBridge_Source.zip`; the project is implemented from scratch. Generate the native Xcode project on macOS with Xcode 15 or later and XcodeGen:

```sh
xcodegen generate
xcodebuild -project DiagnosticHost.xcodeproj -scheme DiagnosticHost \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project DiagnosticHost.xcodeproj -scheme DiagnosticHost \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The exact simulator destination depends on the Xcode installation. A signed device build requires a configured Apple development team. Swift/Xcode are not installed in the authoring environment, so no iOS build or test run is claimed here.

GitHub Actions runs XcodeGen generation and simulator tests on macOS for branch pushes, pull requests, or a manual `workflow_dispatch`. The workflow uploads the generated project, built simulator app, and XCTest result bundle.

## Registering host-owned buffers

Create a `MemoryRegionRegistry` in the host, pass the same registry into `DiagnosticWorkspaceView`, and register only memory owned by that host:

```swift
let registry = MemoryRegionRegistry()
let workspace = DiagnosticWorkspaceView(registry: registry)
let region = try await registry.register(
    name: "application-diagnostics",
    bytes: ownedBuffer,
    writable: false
)
```

The registry copies the supplied `Data`, enforces its configured size bound, and refuses writes unless a region was explicitly registered as writable. Reads are range-checked. The UI starts empty until a host integration registers its authorized regions.

For a live host-owned buffer, register a `RegisteredBufferAccess` instead of a `Data` copy. Its read closure must read only the supplied range from that buffer and synchronize access with the host's own mutations. The registry checks the returned byte count and enforces a total registered-memory limit.

## Current capabilities and boundaries

- Numeric scans for signed/unsigned integer, floating-point, and Boolean types; exact, range, changed, unchanged, increased, and decreased refinements.
- Wildcard byte-pattern and fixed-length UTF-8/UTF-16/ASCII scanning APIs.
- Provider-backed live buffer reads and a bounded asynchronous observation stream with pause, resume, stop, and disappearance events.
- Bounded result count, cancellation checks, and scan progress callbacks.
- Registered-region listing/reading, SHA-256 snapshots and byte-level comparisons.
- JSON, CSV, TXT, Markdown, XML, BIN, HEX, and ZIP serialization. `BIN` export requires explicit raw-byte inclusion.
- Atomic named export with replace, numbered-copy, or fail conflict policies; the app offers the iOS document picker.
- Session persistence stores filter and result metadata, not raw buffers.

The host registers numeric, text, and binary sample buffers at launch. The UI exposes numeric scanning, selectable and paged results, registered-region browsing with a read-only hex viewer, snapshot capture/list/delete, and document export. The engine exposes byte/string scanning, live observation, and session persistence APIs. Live-monitor controls, session save/restore screens, snapshot rename/compare controls, and integrated string/binary scan workflows are not yet wired into the UI.
