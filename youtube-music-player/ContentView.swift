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
