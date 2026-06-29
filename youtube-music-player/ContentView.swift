//
//  ContentView.swift
//  youtube-music-player
//
//  Created by Jem on 12/1/25.
//

import SwiftUI

struct ContentView: View {
    @State private var webViewModel = YouTubeMusicViewModel()
    @State private var mediaKeyHandler = MediaKeyHandler()
    @State private var discordRPC = DiscordRPC()
    @State private var didRegisterObservers = false

    var body: some View {
        VStack(spacing: 0) {
            // Window header for dragging
            WindowHeader(color: webViewModel.headerColor)
                .frame(height: 32)

            YouTubeMusicWebView(viewModel: webViewModel)
        }
        .ignoresSafeArea()
        .onAppear {
            // onAppear can fire more than once; the observer API appends, so register
            // exactly once to avoid stacking duplicate Now Playing / Discord callbacks.
            guard !didRegisterObservers else { return }
            didRegisterObservers = true
            mediaKeyHandler.setViewModel(webViewModel)
            setupDiscordPresence()
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
