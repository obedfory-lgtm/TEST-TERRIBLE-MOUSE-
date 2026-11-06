# Architecture

## Targets

`MemoryEngine` is a dynamic Swift framework target and a Swift package library. It has no dependency on SwiftUI. The engine owns authorized region registration, range-checked provider reads, scanning, snapshots, observation, session metadata, and export serialization.

`DiagnosticHost` is the SwiftUI iOS application. Its startup registers host-owned numeric, text, and binary sample buffers with the engine. A caller with a real application-owned buffer can supply a `RegisteredBufferAccess` provider; reads are constrained to the registered logical range. No process attachment or arbitrary address dereference is used.

`MemoryEngineTests` exercises the portable engine APIs. `DiagnosticHostUITests` verifies the main tab flow and confirms sample registration is visible on launch.

## Data flow

1. The host registers an owned `Data` buffer or a bounded read/write provider.
2. The registry returns metadata and snapshots bytes only by invoking that region's registered provider.
3. `MemoryScanner` runs in an actor, refines its candidate set on next scans, checks cancellation, reports progress, and enforces a result cap.
4. `SnapshotStore` persists bounded snapshots atomically with a SHA-256 digest and checks that digest on restore.
5. `LiveValueMonitor` samples registered providers asynchronously and exposes a bounded `AsyncThrowingStream`.
6. `ExportManager` serializes named formats and uses atomic writes for app-managed directory exports. The UI uses SwiftUI's document exporter for Files destinations.

## Build and CI

`project.yml` is the source of truth for XcodeGen. GitHub Actions on macOS generates `DiagnosticHost.xcodeproj`, builds the app and embedded framework, runs both test targets on an iOS Simulator, and uploads the generated project, simulator app, and test-result bundle.

The local `Package.swift` provides a framework-only test route on a machine with Swift and the required Apple SDKs. iOS UI tests require Xcode and an iOS Simulator.

## Boundaries

The engine never accepts a process identifier or arbitrary memory address as a read request. Optional base addresses are descriptive metadata only. Buffer providers are supplied by the owning host and must enforce their own synchronization with concurrent host mutations.

Sessions persist result and filter metadata, not raw memory. Snapshot capture is explicit and bounded. A snapshot is diagnostic evidence, not a buffer restore operation.
