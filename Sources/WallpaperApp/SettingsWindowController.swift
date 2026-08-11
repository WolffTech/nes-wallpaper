import AppKit

/// Settings window for menu-bar mode: folder pickers, grid size, rotation.
/// Values are committed to UserDefaults by the Apply button; closing the
/// window just hides it.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let menuBar: MenuBarController

    private let romsLabel = NSTextField(labelWithString: "")
    private let moviesLabel = NSTextField(labelWithString: "")
    private let columnsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rowsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rotationField = NSTextField(string: "")
    private let rotationStepper = NSStepper()

    private var romsDir: String?
    private var moviesDir: String?

    init(menuBar: MenuBarController) {
        self.menuBar = menuBar
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "NES Wallpaper Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        loadFromDefaults()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        loadFromDefaults()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Hide instead of tearing anything down; the controller is reused.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func buildContent(in window: NSWindow) {
        for label in [romsLabel, moviesLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .secondaryLabelColor
        }
        romsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        moviesLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for column in 1...8 { columnsPopup.addItem(withTitle: "\(column)") }
        for row in 1...6 { rowsPopup.addItem(withTitle: "\(row)") }

        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 1440
        formatter.allowsFloats = false
        rotationField.formatter = formatter
        rotationField.alignment = .right
        rotationField.target = self
        rotationField.action = #selector(rotationFieldChanged)
        rotationStepper.minValue = 0
        rotationStepper.maxValue = 1440
        rotationStepper.increment = 1
        rotationStepper.valueWraps = false
        rotationStepper.target = self
        rotationStepper.action = #selector(rotationStepperChanged)
        let rotationHint = NSTextField(labelWithString: "minutes (0 = never)")
        rotationHint.textColor = .secondaryLabelColor
        rotationHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let chooseRoms = NSButton(title: "Choose…", target: self,
                                  action: #selector(chooseRomsFolder))
        let chooseMovies = NSButton(title: "Choose…", target: self,
                                    action: #selector(chooseMoviesFolder))

        let rotationRow = NSStackView(views: [rotationField, rotationStepper, rotationHint])
        rotationRow.orientation = .horizontal
        rotationRow.spacing = 4

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "ROM Folder:"), romsLabel, chooseRoms],
            [NSTextField(labelWithString: "Movies Folder:"), moviesLabel, chooseMovies],
            [NSTextField(labelWithString: "Columns:"), columnsPopup],
            [NSTextField(labelWithString: "Rows:"), rowsPopup],
            [NSTextField(labelWithString: "Rotate Every:"), rotationRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 240

        let apply = NSButton(title: "Apply", target: self, action: #selector(applySettings))
        apply.keyEquivalent = "\r"

        let content = NSStackView(views: [grid, apply])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rotationField.widthAnchor.constraint(equalToConstant: 50),
        ])
        window.contentView = container
        window.setContentSize(container.fittingSize)
    }

    private func loadFromDefaults() {
        let settings = WallpaperSettings.load()
        romsDir = settings.romsDir
        moviesDir = settings.moviesDir
        romsLabel.stringValue = settings.romsDir ?? "Not set"
        moviesLabel.stringValue = settings.moviesDir ?? "Not set"
        columnsPopup.selectItem(withTitle: "\(settings.columns)")
        rowsPopup.selectItem(withTitle: "\(settings.rows)")
        rotationField.integerValue = settings.rotationMinutes
        rotationStepper.integerValue = settings.rotationMinutes
    }

    @objc private func rotationFieldChanged() {
        rotationStepper.integerValue = rotationField.integerValue
    }

    @objc private func rotationStepperChanged() {
        rotationField.integerValue = rotationStepper.integerValue
    }

    @objc private func chooseRomsFolder() {
        if let path = chooseFolder(title: "Choose ROM Folder", current: romsDir) {
            romsDir = path
            romsLabel.stringValue = path
        }
    }

    @objc private func chooseMoviesFolder() {
        if let path = chooseFolder(title: "Choose Movies Folder", current: moviesDir) {
            moviesDir = path
            moviesLabel.stringValue = path
        }
    }

    private func chooseFolder(title: String, current: String?) -> String? {
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

    @objc private func applySettings() {
        window?.makeFirstResponder(nil) // commit any in-progress field edit
        var settings = WallpaperSettings.load()
        settings.romsDir = romsDir
        settings.moviesDir = moviesDir
        settings.columns = (columnsPopup.selectedItem?.title).flatMap(Int.init) ?? 3
        settings.rows = (rowsPopup.selectedItem?.title).flatMap(Int.init) ?? 2
        settings.rotationMinutes = max(0, rotationField.integerValue)
        settings.save()
        menuBar.settingsApplied()
    }
}
