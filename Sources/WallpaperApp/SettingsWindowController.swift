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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var loginItem: LoginItemModel

    var body: some View {
        VStack(spacing: 0) {
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
                    Text("Movies (.fm2) are matched to ROMs (.nes) by the checksum in their header. Games without a matching movie play their title or attract screen.")
                }
                Section {
                    Picker("Columns", selection: $model.columns) {
                        ForEach(1..<9, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Rows", selection: $model.rows) {
                        ForEach(1..<7, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                Section {
                    Picker("Video Filter", selection: $model.videoFilter) {
                        ForEach(VideoFilter.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                } footer: {
                    Text("CRT and smoothing filters, rendered per tile by the emulator.")
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
                    Text("Minutes between tile shuffles. 0 means never rotate.")
                }
                Section {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { loginItem.enabled },
                        set: { loginItem.set($0) }))
                        .disabled(!loginItem.available)
                } footer: {
                    if !loginItem.available {
                        Text("Available when running the installed app (see Scripts/make-app.sh).")
                    } else if let error = loginItem.lastError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Takes effect immediately; no need to press Apply.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true) // everything fits; never show a scroll bar

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
        .frame(width: 480, height: 600)
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
            rootView: SettingsView(model: model, loginItem: loginItem))
        window.delegate = self
        model.load()
        loginItem.load()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.load()
        loginItem.load() // may have changed in System Settings meanwhile
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Hide instead of tearing anything down; the controller is reused.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
