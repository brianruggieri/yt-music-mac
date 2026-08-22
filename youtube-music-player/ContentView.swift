//
//  ContentView.swift
//  youtube-music-player
//
//  Created by Jem on 12/1/25.
//

import SwiftUI
import WebKit

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

    // Shares the "themeMode" key with the menu Picker in youtube_music_playerApp.
    @AppStorage("themeMode") private var themeModeRaw = ThemeMode.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            // Window header for dragging, with back/forward overlaid past the traffic lights.
            WindowHeader(color: webViewModel.headerColor)
                .frame(height: 32)
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        navButton("chevron.left", enabled: webViewModel.canGoBack,
                                  shortcut: "[", help: "Back") { webViewModel.goBack() }
                        navButton("chevron.right", enabled: webViewModel.canGoForward,
                                  shortcut: "]", help: "Forward") { webViewModel.goForward() }
                    }
                    .padding(.leading, 80)   // clear the traffic lights
                }

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
        .onChange(of: themeModeRaw) { _, raw in
            webViewModel.applyTheme(ThemeMode(rawValue: raw) ?? .system)
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

    // Header nav button: icon color follows the header's luma (the header mirrors YT
    // Music's nav-bar color, which can be light or dark independent of system appearance).
    private func navButton(_ symbol: String, enabled: Bool, shortcut: KeyEquivalent,
                           help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(headerIsDark ? Color.white : Color.black)
        .opacity(enabled ? 0.85 : 0.3)
        .disabled(!enabled)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help(help)
    }

    private var headerIsDark: Bool {
        let c = webViewModel.headerColor.usingColorSpace(.sRGB) ?? .black
        return (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) < 0.5
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
    // Tracks YT Music's nav-bar color so the header matches its current theme.
    var color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = DraggableHeaderView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = color.cgColor
    }
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
