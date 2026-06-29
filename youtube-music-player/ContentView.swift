//
//  ContentView.swift
//  youtube-music-player
//
//  Created by Jem on 12/1/25.
//

import SwiftUI

struct ContentView: View {
    @State private var webViewModel = YouTubeMusicViewModel()
    @State private var discordRPC = DiscordRPC()
    @State private var didRegisterObservers = false

    // Import sheet — coordinator is built lazily in onAppear once the WKWebView exists.
    // ImportSheet owns @ObservedObject on the coordinator so its @Published changes drive
    // its own body; ContentView only needs the reference and the shared isPresented flag.
    @ObservedObject private var importLauncher = ImportLauncher.shared
    @State private var importCoordinator: ImportCoordinator?
    @State private var diagnosticResult: String?

    var body: some View {
        VStack(spacing: 0) {
            // Window header for dragging
            WindowHeader()
                .frame(height: 32)

            YouTubeMusicWebView(viewModel: webViewModel)
        }
        .ignoresSafeArea()
        .onAppear {
            // onAppear can fire more than once; the observer API appends, so register
            // exactly once to avoid stacking duplicate Discord callbacks.
            guard !didRegisterObservers else { return }
            didRegisterObservers = true
            setupDiscordPresence()

            // makeNSView runs before onAppear, so webViewModel.webView is set by now.
            if let wv = webViewModel.webView {
                importCoordinator = ImportCoordinator(webView: wv)
            }
        }
        .sheet(isPresented: $importLauncher.isPresented) {
            if let coordinator = importCoordinator {
                // onFinishImport reloads YT Music so the imported playlist appears in its
                // sidebar (YTM doesn't re-fetch its guide after our external InnerTube write).
                // Bound to the Done button on the import-complete panel, not the generic close.
                ImportSheet(coordinator: coordinator, onFinishImport: {
                    webViewModel.webView?.reload()
                })
            }
        }
        .onChange(of: importLauncher.isPresented) { _, presented in
            guard let coordinator = importCoordinator else { return }
            if presented {
                coordinator.resetForPresentation()
            } else {
                coordinator.cancel()  // stop any in-flight matching/import when sheet closes
            }
        }
        .onChange(of: importLauncher.isDiagnosticPresented) { _, presented in
            guard presented, let coordinator = importCoordinator else { return }
            importLauncher.isDiagnosticPresented = false
            Task {
                let result = await coordinator.runWriteDiagnostic()
                diagnosticResult = result
            }
        }
        .alert("YTM Write Diagnostic", isPresented: Binding(
            get: { diagnosticResult != nil },
            set: { if !$0 { diagnosticResult = nil } }
        )) {
            Button("OK") { diagnosticResult = nil }
        } message: {
            Text(diagnosticResult ?? "")
        }
    }

    private func setupDiscordPresence() {
        webViewModel.addTrackChangeObserver { title, artist, artworkUrl, isPlaying in
            // Update Discord presence
            if let title = title, let artist = artist, isPlaying {
                discordRPC.updatePresence(
                    title: title,
                    artist: artist,
                    artworkUrl: artworkUrl?.absoluteString
                )
            } else if !isPlaying {
                discordRPC.clearPresence()
            }
        }
    }
}

struct WindowHeader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DraggableHeaderView()
        view.wantsLayer = true
        // Match YouTube Music's dark header (#212121)
        view.layer?.backgroundColor = NSColor(red: 0.129, green: 0.129, blue: 0.129, alpha: 1.0).cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DraggableHeaderView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

#Preview {
    ContentView()
}
