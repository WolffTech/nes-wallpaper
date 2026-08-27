// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Grid information the saver needs before any emulator helpers are running.
public struct SaverConfiguration: Equatable {
    public let columns: Int
    public let rows: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let lowPowerMode: Bool

    public init(columns: Int, rows: Int, tileWidth: Int, tileHeight: Int,
                lowPowerMode: Bool) {
        self.columns = columns
        self.rows = rows
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.lowPowerMode = lowPowerMode
    }
}

/// App-side coordination with the sandboxed screen saver host. The bridge
/// publishes the rendezvous manifest, receives loopback heartbeats, and
/// reports transitions between active and inactive saver playback.
public final class SaverBridge {
    public private(set) var saverActive = false
    public var onActivityChanged: ((Bool) -> Void)?
    public var heartbeatPort: UInt16 { heartbeat?.port ?? 0 }

    private var configuration: SaverConfiguration
    private var tiles: [String] = []
    private var playbackState = SharedFrames.PlaybackState.idle
    private let heartbeat: HeartbeatListener?
    private let manifestURL: URL
    private let activityPollInterval: TimeInterval
    private var activityTimer: Timer?
    private var shutDown = false

    public init(configuration: SaverConfiguration) {
        self.configuration = configuration
        self.heartbeat = HeartbeatListener()
        self.manifestURL = SharedFrames.manifestURL
        self.activityPollInterval = 1
        finishInitialization()
    }

    init(configuration: SaverConfiguration, heartbeat: HeartbeatListener?,
         manifestURL: URL, activityPollInterval: TimeInterval) {
        self.configuration = configuration
        self.heartbeat = heartbeat
        self.manifestURL = manifestURL
        self.activityPollInterval = activityPollInterval
        finishInitialization()
    }

    private func finishInitialization() {
        heartbeat?.onBeat = { [weak self] in self?.receivedBeat() }
        writeManifest()
    }

    public func updateConfiguration(_ configuration: SaverConfiguration) {
        self.configuration = configuration
        if tiles.isEmpty {
            playbackState = saverActive ? .starting : .idle
        }
        writeManifest()
    }

    public func publish(tiles: [String]) {
        self.tiles = tiles
        playbackState = tiles.isEmpty
            ? (saverActive ? .starting : .idle)
            : .active
        writeManifest()
    }

    public func clearTiles() {
        tiles = []
        playbackState = saverActive ? .starting : .idle
        writeManifest()
    }

    public func markPlaybackUnavailable() {
        tiles = []
        playbackState = .unavailable
        writeManifest()
    }

    private func receivedBeat() {
        if tiles.isEmpty, playbackState != .unavailable {
            playbackState = .starting
            writeManifest()
        }
        setSaverActive(true)
        guard activityTimer == nil else { return }
        let timer = Timer(timeInterval: activityPollInterval, repeats: true) {
            [weak self] _ in
            self?.refreshActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    private func refreshActivity() {
        let active = heartbeat?.saverActive ?? false
        setSaverActive(active)
        if !active {
            activityTimer?.invalidate()
            activityTimer = nil
        }
    }

    private func setSaverActive(_ active: Bool) {
        guard active != saverActive else { return }
        saverActive = active
        onActivityChanged?(active)
    }

    private func writeManifest() {
        guard !shutDown else { return }
        let manifest = SharedFrames.Manifest(
            pid: getpid(),
            columns: configuration.columns,
            rows: configuration.rows,
            tileWidth: configuration.tileWidth,
            tileHeight: configuration.tileHeight,
            heartbeatPort: Int(heartbeatPort),
            lowPowerMode: configuration.lowPowerMode,
            playbackState: playbackState,
            tiles: tiles)
        do {
            try SharedFrames.write(manifest, to: manifestURL)
        } catch {
            Self.log("failed to write saver manifest: \(error)")
        }
    }

    public func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        activityTimer?.invalidate()
        activityTimer = nil
        heartbeat?.onBeat = nil
        guard SharedFrames.readManifest(from: manifestURL)?.pid == getpid() else {
            return
        }
        try? FileManager.default.removeItem(at: manifestURL)
    }

    deinit { shutdown() }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("nes-wallpaper: \(message)\n".utf8))
    }
}
