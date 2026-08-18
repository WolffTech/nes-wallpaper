// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import ServiceManagement
import Sparkle
import SwiftUI
import NESWallpaperCore

/// Backing model for the settings form. Edits stay local until `apply()`
/// commits them to UserDefaults and notifies the menu-bar controller.
final class SettingsModel: ObservableObject {
    @Published var romsDir: String?
    @Published var moviesDir: String?
    @Published var columns = 3
    @Published var rows = 2
    @Published var rotationMinutes = 10
    @Published var includeROMsWithoutMovies = true
    @Published var videoFilter = VideoFilter.none
    @Published var showDockIcon = false

    var onApply: (() -> Void)?

    func load() {
        let settings = WallpaperSettings.load()
        romsDir = settings.romsDir
        moviesDir = settings.moviesDir
        columns = settings.columns
        rows = settings.rows
        rotationMinutes = settings.rotationMinutes
        includeROMsWithoutMovies = settings.includeROMsWithoutMovies
        videoFilter = settings.videoFilter
        showDockIcon = settings.showDockIcon
    }

    func apply() {
        var settings = WallpaperSettings.load()
        settings.romsDir = romsDir
        settings.moviesDir = moviesDir
        settings.columns = columns
        settings.rows = rows
        settings.rotationMinutes = max(0, rotationMinutes)
        settings.includeROMsWithoutMovies = includeROMsWithoutMovies
        settings.videoFilter = videoFilter
        settings.showDockIcon = showDockIcon
        settings.save()
        onApply?()
    }
}

/// Login-item state, applied immediately rather than via the Apply button:
/// the system (SMAppService), not UserDefaults, is the source of truth.
final class LoginItemModel: ObservableObject {
    @Published var enabled = false
    @Published var lastError: String?

    /// SMAppService can only register an installed .app bundle, not the
    /// bare SwiftPM executable used during development.
    let available = Bundle.main.bundleURL.pathExtension == "app"

    func load() {
        guard available else { return }
        enabled = SMAppService.mainApp.status == .enabled
        lastError = nil
    }

    func set(_ wantEnabled: Bool) {
        guard available else { return }
        do {
            if wantEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

/// Installs the bundled screensaver into ~/Library/Screen Savers. Like the
/// login item, this needs the installed .app (the bare SwiftPM executable
/// has no Resources to copy from).
final class SaverInstallModel: ObservableObject {
    @Published var installed = false
    @Published var lastError: String?

    private static let bundled = Bundle.main
        .url(forResource: "NES Wallpaper", withExtension: "saver")
    private static let destination = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Screen Savers/NES Wallpaper.saver")

    var available: Bool { Self.bundled != nil }

    func load() {
        installed = FileManager.default.fileExists(atPath: Self.destination.path)
        lastError = nil
    }

    func install() {
        guard let bundled = Self.bundled else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: Self.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // Replace, not merge: stale Contents must never survive.
            if fm.fileExists(atPath: Self.destination.path) {
                try fm.removeItem(at: Self.destination)
            }
            try fm.copyItem(at: bundled, to: Self.destination)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        load()
        // Land the user where the saver is selected. The ScreenSaver pane
        // moved under Wallpaper in macOS 26; the old URL still resolves.
        if lastError == nil, let url = URL(
            string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sparkle update preferences, applied immediately rather than via the Apply
/// button: Sparkle's own user defaults, not WallpaperSettings, are the source
/// of truth. Like the login item, this only functions from the installed
/// .app bundle (see UpdaterController.available).
final class UpdatesModel: ObservableObject {
    @Published var automaticallyChecks = false
    @Published var canCheckNow = false

    let available = UpdaterController.available
    let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()

    private weak var updater: SPUUpdater?
    private var canCheckObservation: NSKeyValueObservation?

    func attach(_ updater: SPUUpdater) {
        self.updater = updater
        canCheckObservation = updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            self?.canCheckNow = updater.canCheckForUpdates
        }
        load()
    }

    /// Reloaded on show(): Sparkle's own permission prompt can flip the
    /// automatic-checks preference behind the window's back.
    func load() {
        automaticallyChecks = updater?.automaticallyChecksForUpdates ?? false
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        load()
    }

    func checkNow() {
        updater?.checkForUpdates()
    }
}

/// Panes of the settings window. Splitting the form across tabs keeps every
/// pane short enough to fit without scrolling at the window's fixed size.
enum SettingsTab: Hashable {
    case library, display, controls, general
}

/// Selected tab. An ObservableObject rather than `@State` so the app still
/// builds with the Command Line Tools toolchain, which has no SwiftUI macro
/// plugin (`@State` is a macro; `@Published`/`@ObservedObject` are not).
final class SettingsTabModel: ObservableObject {
    @Published var tab = SettingsTab.library
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var loginItem: LoginItemModel
    @ObservedObject var saverInstall: SaverInstallModel
    @ObservedObject var controls: ControlsModel
    @ObservedObject var updates: UpdatesModel
    @ObservedObject var tabModel: SettingsTabModel

    // Header strip, pane, footer strip. A TabView would nest its own bordered
    // panel inside the window, leaving three competing background shades; the
    // segmented picker keeps the pane flush so the window reads as one surface.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tabModel.tab) {
                Text("Library").tag(SettingsTab.library)
                Text("Display").tag(SettingsTab.display)
                Text("Controls").tag(SettingsTab.controls)
                Text("General").tag(SettingsTab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            .padding(12)

            Divider()
            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Apply") {
                    NSApp.keyWindow?.makeFirstResponder(nil) // commit an in-progress field edit
                    model.apply()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
    }

    @ViewBuilder private var selectedPane: some View {
        switch tabModel.tab {
        case .library: libraryTab
        case .display: displayTab
        case .controls: ControlsPane(model: controls)
        case .general: generalTab
        }
    }

    private var libraryTab: some View {
        Form {
            Section {
                folderRow(title: "ROM Folder", path: model.romsDir) {
                    model.romsDir = $0
                }
                folderRow(title: "Movies Folder", path: model.moviesDir) {
                    model.moviesDir = $0
                }
                Toggle("Include games without movies",
                       isOn: $model.includeROMsWithoutMovies)
            } footer: {
                note(Text("Movies (.fm2) are matched to ROMs (.nes) by the checksum in their header. Games without a matching movie play their title or attract screen."))
            }
        }
        .formStyle(.grouped)
    }

    private var displayTab: some View {
        Form {
            Section {
                Picker("Columns", selection: $model.columns) {
                    ForEach(1..<9, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Rows", selection: $model.rows) {
                    ForEach(1..<7, id: \.self) { Text("\($0)").tag($0) }
                }
            } footer: {
                note(Text("Tiles are laid out in this grid on every display."))
            }
            Section {
                Picker("Video Filter", selection: $model.videoFilter) {
                    ForEach(VideoFilter.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            } footer: {
                note(Text("CRT and smoothing filters, rendered per tile by the emulator."))
            }
            Section {
                LabeledContent("Rotate Every") {
                    TextField("Minutes", value: $model.rotationMinutes, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .labelsHidden()
                    Stepper("Minutes", value: $model.rotationMinutes, in: 0...1440)
                        .labelsHidden()
                }
            } footer: {
                note(Text("Minutes between tile shuffles. 0 means never rotate."))
            }
            Section {
                Toggle("Enlarge game to full screen",
                       isOn: Binding(
                           get: { controls.fullscreenTakeover },
                           set: { controls.setFullscreenTakeover($0) }))
            } header: {
                Text("While Playing")
            } footer: {
                note(Text("The game you take over fills its display; other displays keep the dimmed grid. When off, the game keeps its tile size. Takes effect immediately; no need to press Apply."))
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Show App Icon in Dock", isOn: $model.showDockIcon)
            } footer: {
                note(Text("When off, NES Wallpaper appears only in the menu bar."))
            }
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItem.enabled },
                    set: { loginItem.set($0) }))
                    .disabled(!loginItem.available)
            } footer: {
                if !loginItem.available {
                    note(Text("Available when running the installed app (see Scripts/make-app.sh)."))
                } else if let error = loginItem.lastError {
                    note(Text(error).foregroundStyle(.red))
                } else {
                    note(Text("Takes effect immediately; no need to press Apply."))
                }
            }
            Section {
                LabeledContent {
                    Button(saverInstall.installed ? "Reinstall" : "Install") {
                        saverInstall.install()
                    }
                    .disabled(!saverInstall.available)
                } label: {
                    Text("Screen Saver")
                    Text(saverInstall.installed ? "Installed" : "Not installed")
                }
            } footer: {
                if !saverInstall.available {
                    note(Text("Available when running the installed app (see Scripts/make-app.sh)."))
                } else if let error = saverInstall.lastError {
                    note(Text(error).foregroundStyle(.red))
                } else {
                    note(Text("Plays the wallpaper as your screen saver, including on the lock screen. After installing, pick \u{201C}NES Wallpaper\u{201D} in System Settings under Wallpaper \u{2192} Screen Saver. Frames only arrive while the app is running, so turn on Launch at Login."))
                }
            }
            Section {
                LabeledContent {
                    Button("Check Now") { updates.checkNow() }
                        .disabled(!updates.available || !updates.canCheckNow)
                } label: {
                    Text("Software Updates")
                    Text(updates.versionText)
                }
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updates.automaticallyChecks },
                    set: { updates.setAutomaticallyChecks($0) }))
                    .disabled(!updates.available)
            } footer: {
                if !updates.available {
                    note(Text("Available when running the installed app (see Scripts/make-app.sh)."))
                } else {
                    note(Text("Takes effect immediately; no need to press Apply. Updates are downloaded from GitHub Releases."))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Section footers default to trailing alignment inside a grouped form's
    /// LabeledContent rows; explanatory text reads better flush left.
    private func note(_ text: Text) -> some View {
        text
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderRow(title: String, path: String?,
                           onChoose: @escaping (String) -> Void) -> some View {
        LabeledContent {
            Button("Choose") {
                if let picked = Self.chooseFolder(title: "Choose \(title)", current: path) {
                    onChoose(picked)
                }
            }
        } label: {
            Text(title)
            Text(path ?? "Not set")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private static func chooseFolder(title: String, current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// Settings window for menu-bar mode. The content is a SwiftUI grouped form;
/// values are committed to UserDefaults by the Apply button, and closing the
/// window just hides it.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model = SettingsModel()
    private let loginItem = LoginItemModel()
    private let saverInstall = SaverInstallModel()
    private let controls = ControlsModel()
    private let updates = UpdatesModel()
    private let tabModel = SettingsTabModel()

    init(menuBar: MenuBarController) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "NES Wallpaper Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.onApply = { [weak menuBar] in menuBar?.settingsApplied() }
        controls.onChanged = { [weak menuBar] in menuBar?.controlsChanged() }
        controls.onShortcutChanged = { [weak menuBar] shortcut in
            menuBar?.changeTakeoverShortcut(shortcut)
                ?? "Global shortcuts aren\u{2019}t available right now."
        }
        controls.onShortcutRecordingChanged = { [weak menuBar] recording in
            menuBar?.shortcutRecordingChanged(recording)
        }
        if let updater = menuBar.updaterController?.updater {
            updates.attach(updater)
        }
        window.contentViewController = NSHostingController(
            rootView: SettingsView(model: model, loginItem: loginItem,
                                   saverInstall: saverInstall, controls: controls,
                                   updates: updates, tabModel: tabModel))
        window.delegate = self
        model.load()
        loginItem.load()
        saverInstall.load()
        controls.load()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.load()
        loginItem.load() // may have changed in System Settings meanwhile
        saverInstall.load() // user may have deleted the installed saver
        controls.load()
        updates.load() // Sparkle's permission prompt may have flipped it
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Hide instead of tearing anything down; the controller is reused.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controls.cancelAllRecording()
        sender.orderOut(nil)
        return false
    }
}
