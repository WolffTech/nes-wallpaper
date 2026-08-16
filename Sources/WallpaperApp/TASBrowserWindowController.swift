// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI
import NESWallpaperCore

/// Backing model for the TASVideos browser. Catalog and install state are
/// mutated on the main thread; network and file work runs in tasks that hop
/// back via `MainActor.run`.
final class TASBrowserModel: ObservableObject {
    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded(fetchedAt: Date)
        case failed(String)
    }

    enum RowState: Equatable {
        case notInstalled
        case downloading
        /// FM2 is in the movies folder; `hasROM` is whether a ROM in the ROM
        /// folder matches its checksum.
        case installed(hasROM: Bool)
        case failed(String)
    }

    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var publications: [TASPublication] = []
    @Published private(set) var rowStates: [Int: RowState] = [:]
    @Published private(set) var moviesDirSet = false
    @Published var searchText = ""

    private let client = TASVideosClient()
    private let installer = MovieInstaller()
    private let store = TASCatalogStore(directory: TASCatalogStore.defaultDirectory())

    var filtered: [TASPublication] {
        publications.filter { TASPublication.matches($0, search: searchText) }
    }

    func rowState(for publication: TASPublication) -> RowState {
        rowStates[publication.id] ?? .notInstalled
    }

    /// Called each time the window is shown: cached catalog appears
    /// instantly; a fetch runs only when there is no cache or it went stale.
    func onAppear() {
        if publications.isEmpty, let cached = store.load() {
            publications = cached.publications
            catalogState = .loaded(fetchedAt: cached.fetchedAt)
            if store.isStale(cached) { fetch() }
        } else if publications.isEmpty, catalogState != .loading {
            fetch()
        }
        refreshInstalledStates()
    }

    func refresh() {
        fetch()
    }

    private func fetch() {
        guard catalogState != .loading else { return }
        catalogState = .loading
        Task { [client, store] in
            do {
                let all = try await client.fetchAllNESPublications()
                let catalog = TASCatalog(fetchedAt: Date(),
                                         publications: TASPublication.playable(all))
                try? store.save(catalog)
                await MainActor.run {
                    self.publications = catalog.publications
                    self.catalogState = .loaded(fetchedAt: catalog.fetchedAt)
                    self.refreshInstalledStates()
                }
            } catch {
                await MainActor.run {
                    // A previously shown catalog keeps showing; the view
                    // renders the failure inline instead of replacing it.
                    self.catalogState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func download(_ publication: TASPublication) {
        guard let dirs = directories() else { return }
        rowStates[publication.id] = .downloading
        Task { [installer] in
            do {
                let outcome = try await installer.install(
                    publication: publication, moviesDir: dirs.movies, romsDir: dirs.roms)
                await MainActor.run {
                    switch outcome {
                    case .ready:
                        self.rowStates[publication.id] = .installed(hasROM: true)
                    case .missingROM:
                        self.rowStates[publication.id] = .installed(hasROM: false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.rowStates[publication.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Recomputes installed/matched state from disk using the same matching
    /// logic the wallpaper uses (ContentLibrary).
    private func refreshInstalledStates() {
        moviesDirSet = directories() != nil
        guard let dirs = directories() else { return }
        let pubs = publications
        let current = rowStates
        Task.detached {
            let installed = MovieInstaller.installedFileNames(in: dirs.movies)
            let library = ContentLibrary(romsDir: dirs.roms, moviesDir: dirs.movies)
            let matchedNames = Set(library.matches.map { $0.movieURL.lastPathComponent })
            var next: [Int: RowState] = [:]
            for pub in pubs {
                if installed.contains(pub.movieFileName) {
                    next[pub.id] = .installed(hasROM: matchedNames.contains(pub.movieFileName))
                } else if case .failed = current[pub.id] {
                    next[pub.id] = current[pub.id]!
                }
            }
            await MainActor.run { [next] in
                // Keep in-flight downloads and anything that finished while
                // this scan was running.
                var merged = next
                for (id, state) in self.rowStates {
                    switch state {
                    case .downloading, .installed:
                        if merged[id] == nil { merged[id] = state }
                    case .notInstalled, .failed:
                        break
                    }
                }
                self.rowStates = merged
            }
        }
    }

    private func directories() -> (movies: URL, roms: URL)? {
        let settings = WallpaperSettings.load()
        guard let movies = settings.moviesDir, !movies.isEmpty else { return nil }
        // With no ROM folder configured, match against the movies folder:
        // it contains no .nes files, so everything reports "no matching ROM".
        let roms = (settings.romsDir?.isEmpty == false) ? settings.romsDir! : movies
        return (URL(fileURLWithPath: movies, isDirectory: true),
                URL(fileURLWithPath: roms, isDirectory: true))
    }
}

/// TASVideos browser window for menu-bar mode; closing just hides it and the
/// controller (with its loaded catalog) is reused.
final class TASBrowserWindowController: NSWindowController, NSWindowDelegate {
    private let model = TASBrowserModel()

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TASVideos — Tool-Assisted Speedruns"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: TASBrowserView(model: model))
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.onAppear()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Hide instead of tearing anything down; the controller is reused.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
