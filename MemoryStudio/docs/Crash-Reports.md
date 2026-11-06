# Crash and Build Reports

The host surfaces diagnostic errors from registration, scanning, snapshots, sessions, and export. Those are application-level errors, not crash records.

iOS does not grant an ordinary app access to the operating system's crash-report database. MemoryStudio does not install signal handlers, suppress crashes, claim to recover after termination, or fabricate stack traces. For a device crash, collect the OS-generated report from Xcode Organizer, Analytics Data, or the applicable distribution service, then symbolicate it with the matching build's dSYM.

The GitHub Actions workflow produces these records on macOS:

- `simulator-tests.log` and `device-build.log`, streamed from the actual `xcodebuild` commands.
- `TestResults.xcresult`, containing XCTest and simulator diagnostics.
- `TestSummary.json`, generated from the result bundle when `xcresulttool` can read it.
- Any matching simulator `DiagnosticHost` or `MemoryStudio` `.crash`/`.ips` report created during that workflow run.
- `BuildReport.md`, recording step outcomes and architecture evidence. If no crash file exists, it states that directly.

The workflow never claims a crash report exists when the operating system produced none. CI artifacts are downloadable from the completed GitHub Actions run; a device crash report must be captured on the device or through Apple's tooling.