# Loading and Signing

## Supported host loading

The supported deliverable is `MemoryStudio.framework`, embedded through the host target's Xcode dependency configuration. Xcode links the framework, copies it into the app's `Frameworks` directory, and signs it with the host during a signed build. The host imports the framework module and creates `DiagnosticWorkspaceView` with a `MemoryRegionRegistry` that the host owns.

The CI project also builds a separate `library.dynamic` target named `MemoryStudio.dylib` from the same sources. CI verifies its Mach-O `DYLIB` file type and ARM64 architecture. The demo host intentionally embeds the framework target, which is Xcode's supported bundle for linking, module metadata, embedding, and signing. The standalone dylib artifact is not loaded by the host and is not for injection into unrelated apps or processes.

## Signing and compatibility

- Build device binaries with Xcode's iOS SDK on macOS. Linux cannot link an iOS framework.
- The executable architecture must match the device. CI verifies `arm64` with `xcrun lipo -archs`.
- The deployment target is iOS 16.0. The host and embedded framework must use compatible minimum OS versions and architectures.
- A device-installable host requires a valid Apple development/distribution identity, provisioning profile, matching bundle identifier, and any required entitlements.
- CI intentionally produces an unsigned framework because signing credentials are not stored in the repository. The host app must sign the embedded framework as part of its normal Xcode signing process.
- Add any future framework dependencies to the Xcode target and embed/sign them according to their platform requirements.

No runtime injection, arbitrary process attachment, stealth loader, undocumented API, or access-control bypass is implemented.