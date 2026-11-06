import DiagnosticHost
import SwiftUI

@main
struct DiagnosticHostApp: App {
    var body: some Scene {
        WindowGroup {
            DiagnosticWorkspaceView()
                .preferredColorScheme(.dark)
        }
    }
}
