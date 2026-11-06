# MemoryStudio iOS

MemoryStudio is a native iOS 16+ diagnostic workspace backed by an embedded dynamic framework. The engine can inspect only byte buffers that the owning host explicitly registers. The included host registers its own sample buffers; the framework does not attach to or inspect another process.

## Project layout

- `Sources/MemoryStudio` contains the typed memory engine, region registry, scanner, monitor, snapshots, sessions, exports, and SwiftUI workspace.
- `Sources/DiagnosticHost` contains the authorized demonstration host and its sample-buffer registration.
- `Tests/MemoryStudioTests` contains engine tests.
- `Tests/DiagnosticHostUITests` contains host navigation and overlay tests.
- `project.yml` generates an Xcode project with an embedded dynamic framework and a standalone dynamic-library build product from the same source.
- `../.github/workflows/memory-studio.yml` builds on a GitHub-hosted macOS runner and uploads the device framework, Mach-O library binary, symbols, tests, logs, and source archive.
- `docs/Loading-and-Signing.md` describes host integration and signing.
- `docs/Crash-Reports.md` explains what the app and CI can actually collect.

## Build and test

Requirements: macOS, Xcode 15 or later, and XcodeGen.

```sh
cd MemoryStudio
xcodegen generate --spec project.yml
xcodebuild -project MemoryStudio.xcodeproj -scheme DiagnosticHost \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
xcodebuild -project MemoryStudio.xcodeproj -scheme DiagnosticHost \
  -destination 'generic/platform=iOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO build
```

The device build creates both `MemoryStudio.framework` for supported host embedding and a separately compiled `MemoryStudio.dylib` product. CI verifies the dylib's Mach-O file type and ARM64 architecture before publishing it. The host app embeds and signs the framework; the bare dylib is a binary deliverable, not an instruction to load it into another app or process.

This authoring environment is Linux and does not include Swift, Xcode, iOS SDKs, or XcodeGen. No local iOS compilation, simulator execution, signed app, or test result is claimed. The macOS workflow performs those checks and publishes their real logs and results as downloadable Actions artifacts.

## Host integration

Import `MemoryStudio`, create a registry, and pass that same registry to `DiagnosticWorkspaceView`. Register owned memory from the host, preferably as a `Data` copy. Writes are rejected unless the host explicitly registers a writable region.

```swift
import MemoryStudio

let registry = MemoryRegionRegistry()
let info = try await registry.register(
    name: "owned-diagnostic-state",
    bytes: Data([0x10, 0x20, 0x30, 0x40]),
    writable: false
)
let workspace = DiagnosticWorkspaceView(registry: registry)
```

For live host state, the host may periodically refresh its registered `Data` using the registry's authorized write API, or extend the provider boundary in its own integration. Never pass arbitrary pointers or another process's address space.

## Implemented behavior

- Signed and unsigned integer widths, Float32/64, Boolean, UTF-8/16, ASCII, and bytes with explicit endianness.
- Exact, range, threshold, unknown, changed, unchanged, increased/decreased, and initial-value scans; natural or every-byte alignment; wildcard byte patterns; fixed-window text matching.
- Bounded actor-based scans, cancellation, progress reporting, result limits, and asynchronous live monitoring.
- Registered-region map and paged, read-only hexadecimal/ASCII inspection.
- Bounded SHA-256 snapshots, comparison, deletion, and rename APIs.
- Metadata-only session persistence.
- Custom filename and native Files export in TXT, JSON, CSV, XML, BIN, HEX, Markdown, and ZIP.
- In-app draggable overlay and compact five-section navigation.

## Deliberate limits

The framework stores copied `Data`; it does not dereference raw addresses. A host that needs live memory must implement an explicit, synchronized provider boundary. Saved sessions contain candidate metadata and references, not scanner actor state or raw memory. iOS applications cannot read the operating system's crash-report database from their sandbox. See the crash-report documentation; CI retains XCTest result bundles and any matching simulator crash files produced by the run.