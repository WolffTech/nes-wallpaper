import AppKit
import ServiceManagement
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

/// Panes of the settings window. Splitting the form across tabs keeps every
/// pane short enough to fit without scrolling at the window's fixed size.
enum SettingsTab: Hashable {
    case library, display, general
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
    @ObservedObject var tabModel: SettingsTabModel

    // Header strip, pane, footer strip. A TabView would nest its own bordered
    // panel inside the window, leaving three competing background shades; the
    // segmented picker keeps the pane flush so the window reads as one surface.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tabModel.tab) {
                Text("Library").tag(SettingsTab.library)
                Text("Display").tag(SettingsTab.display)
                Text("General").tag(SettingsTab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
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
        .frame(width: 520, height: 440)
    }

    @ViewBuilder private var selectedPane: some View {
        switch tabModel.tab {
        case .library: libraryTab
        case .display: displayTab
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
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
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
                    Button(saverInstall.installed
                        ? "Reinstall\u{2026}" : "Install\u{2026}") {
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
            Button("Choose…") {
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
        window.contentViewController = NSHostingController(
            rootView: SettingsView(model: model, loginItem: loginItem,
                                   saverInstall: saverInstall, tabModel: tabModel))
        window.delegate = self
        model.load()
        loginItem.load()
        saverInstall.load()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.load()
        loginItem.load() // may have changed in System Settings meanwhile
        saverInstall.load() // user may have deleted the installed saver
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Hide instead of tearing anything down; the controller is reused.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
