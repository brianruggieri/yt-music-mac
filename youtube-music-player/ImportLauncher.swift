import Foundation
import Combine  // ObservableObject / @Published — import explicitly, don't rely on whole-module leakage

// ponytail: singleton trigger — menu command, nav interceptor, and ContentView all share this one publisher
final class ImportLauncher: ObservableObject {
    static let shared = ImportLauncher()
    private init() {}
    @Published var isPresented = false
    /// Set to true to trigger the YTM write diagnostic (debug menu → ContentView → coordinator).
    @Published var isDiagnosticPresented = false
}
