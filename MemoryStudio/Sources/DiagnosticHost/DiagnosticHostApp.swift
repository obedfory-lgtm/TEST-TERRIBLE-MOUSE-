import MemoryStudio
import Foundation
import SwiftUI

@main
struct DiagnosticHostApp: App {
    @State private var registry = MemoryRegionRegistry()
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            DiagnosticWorkspaceView(registry: registry)
                .task {
                    do {
                        if await registry.regions().isEmpty {
                            try await DiagnosticHostSamples.register(in: registry)
                        }
                    } catch {
                        startupError = error.localizedDescription
                    }
                }
                .alert("Host registration failed", isPresented: Binding(
                    get: { startupError != nil },
                    set: { if !$0 { startupError = nil } }
                )) {
                    Button("Dismiss", role: .cancel) { startupError = nil }
                } message: { Text(startupError ?? "") }
        }
    }
}

private enum DiagnosticHostSamples {
    static func register(in registry: MemoryRegionRegistry) async throws {
        var numeric = Data()
        for value in [18, 42, 75, 120, 255, 512] {
            numeric.append(try MemoryDataType.int32.encode(String(value)))
        }
        _ = try await registry.register(name: "host-owned-values", bytes: numeric, writable: true, dataType: .int32)
        _ = try await registry.register(name: "host-owned-label", bytes: Data("recovery-validation".utf8), dataType: .utf8)
        _ = try await registry.register(name: "host-owned-packet", bytes: Data([0xA1, 0x03, 0x7F, 0xD2, 0x08, 0x10, 0x44, 0xBE]))
    }
}