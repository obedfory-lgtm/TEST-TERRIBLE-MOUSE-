# Architecture

## Ownership

`MemoryStudio` is the embedded Swift dynamic framework used by the host. `MemoryStudioDylib` is a separate `library.dynamic` target compiled from the same engine and SwiftUI sources for direct `.dylib` distribution. `MemoryRegionRegistry` is the only engine entrance to bytes. The API accepts `Data` supplied by the owning host, validates size and range, and defaults each region to read-only. Logical offsets are relative to the registered buffer; they are not process addresses.

`DiagnosticHost` owns the registry lifetime and registers sample data at launch. It embeds the framework through the Xcode target dependency. `DiagnosticWorkspaceView` receives the registry and never creates sample regions or accesses process memory itself.

## Data flow

1. The host registers a bounded buffer and receives a region identifier.
2. The scanner receives snapshots returned by that registry and stores candidate offsets and decoded values.
3. Refinement reads those candidate offsets from fresh registered-region snapshots; it never begins a hidden new scan.
4. The monitor polls the registry asynchronously and retains a bounded event history.
5. Snapshots are explicitly captured, SHA-256 checked on restore, and atomically persisted.
6. Exports serialize result and snapshot data to a selected format and the UI presents the native Files exporter.
7. Session files store result metadata and snapshot identifiers only.

## Build and signing

`project.yml` is the XcodeGen source of truth. The framework is embedded in the host app; a second target builds `MemoryStudio.dylib` as a dynamic library. A device binary must be built by Xcode with the iOS SDK on macOS. The GitHub workflow separately runs simulator tests and an ARM64 device build, checks the dylib's Mach-O file type with `otool` and architecture with `lipo`, and publishes artifacts with actual build/test logs.

The CI device artifact is unsigned because no developer identity or provisioning profile is supplied. Xcode must sign the host app and embedded framework together before device installation. The app's team, bundle identifiers, provisioning profile, entitlements, deployment target, and framework dependencies must match the deployment environment.

## Diagnostics boundaries

The app reports its own scanner, registry, persistence, and export errors. It cannot inspect iOS crash logs due to sandbox restrictions. Device crash reports are generated and made available by iOS/Xcode or the distribution service. CI attaches the XCTest `.xcresult` bundle and copies matching simulator `.crash`/`.ips` files when present; it records absence explicitly rather than fabricating a report.