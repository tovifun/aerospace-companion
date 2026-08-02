import Cocoa
import Carbon
import Darwin
import QuartzCore

private let runtimeIdentifier = "io.github.tovifun.aerospace-companion.window-switcher"
private let runtimePathPrefix = "/tmp/\(runtimeIdentifier).\(getuid())"
private let cycleNotificationName = Notification.Name("\(runtimeIdentifier).cycle")
private let singletonLockPath = "\(runtimePathPrefix).lock"
private let daemonPIDPath = "\(runtimePathPrefix).pid"

private enum SwitcherStyle {
    static let surfaceCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 10
    static let shadowMargin: CGFloat = 24
    static let contentPadding: CGFloat = 10
    static let groupSpacing: CGFloat = 7
    static let groupHeaderHeight: CGFloat = 24
    static let rowSpacing: CGFloat = 1
    static let rowHeight: CGFloat = 44
    static let iconSize: CGFloat = 32
    static let accentColor = NSColor(
        srgbRed: 0.20,
        green: 0.43,
        blue: 0.96,
        alpha: 1
    )
}

private struct AeroWindow: Decodable {
    let windowID: Int
    let appName: String
    let appBundleID: String
    let workspace: String
    let windowTitle: String

    enum CodingKeys: String, CodingKey {
        case windowID = "window-id"
        case appName = "app-name"
        case appBundleID = "app-bundle-id"
        case workspace
        case windowTitle = "window-title"
    }
}

private struct WorkspaceGroup {
    let workspace: String
    var windows: [AeroWindow]
}

private struct RunningApp {
    let processIdentifier: pid_t
    let appName: String
    let bundleIdentifier: String
}

private enum SwitcherItem {
    case window(AeroWindow)
    case application(RunningApp)

    var key: String {
        switch self {
        case .window(let window):
            return "window:\(window.windowID)"
        case .application(let app):
            return "application:\(app.processIdentifier)"
        }
    }
}

private enum AeroSpaceClient {
    private static let executablePaths = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace",
    ]

    private static var executable: String? {
        executablePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func allWindows() throws -> [AeroWindow] {
        let format = "%{window-id} %{app-name} %{app-bundle-id} %{workspace} %{window-title}"
        let data = try run(["list-windows", "--all", "--json", "--format", format])
        return try JSONDecoder().decode([AeroWindow].self, from: data)
    }

    static func focusedWindowID() -> Int? {
        guard
            let data = try? run(["list-windows", "--focused", "--format", "%{window-id}"]),
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        return Int(value)
    }

    static func focus(windowID: Int, switchingTo workspace: String?) {
        if let workspace {
            DispatchQueue.global(qos: .userInteractive).async {
                // Preserve the ordering off the main thread: reveal the
                // destination workspace before focusing its floating window.
                _ = try? run(["workspace", "--", workspace])
                _ = try? run(["focus", "--window-id", String(windowID)])
            }
            return
        }

        guard let executable else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["focus", "--window-id", String(windowID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func run(_ arguments: [String]) throws -> Data {
        guard let executable else {
            throw NSError(
                domain: "AeroSpaceWindowSwitcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AeroSpace CLI was not found"]
            )
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "AeroSpace command failed"
            throw NSError(
                domain: "AeroSpaceWindowSwitcher",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return data
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = SwitcherStyle.surfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -7)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: SwitcherStyle.surfaceCornerRadius,
            cornerHeight: SwitcherStyle.surfaceCornerRadius,
            transform: nil
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.18)
            ).cgColor
        }
    }
}

private final class GlassBackgroundView: NSVisualEffectView {
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = SwitcherStyle.surfaceCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

private final class GlassTintView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = (isDark
                ? NSColor(srgbRed: 0.035, green: 0.04, blue: 0.055, alpha: 0.50)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.56)
            ).cgColor
        }
    }
}

private final class ActionRow: NSControl {
    var onClick: (() -> Void)?
    var normalColor = NSColor.clear {
        didSet { updateAppearance() }
    }
    var isSelected = false {
        didSet { updateAppearance() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private weak var primaryLabel: NSTextField?
    private weak var secondaryLabel: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = SwitcherStyle.rowCornerRadius
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        setBackgroundColor(SwitcherStyle.accentColor.withAlphaComponent(0.24))
    }

    override func mouseUp(with event: NSEvent) {
        updateAppearance()
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    func registerLabels(primary: NSTextField, secondary: NSTextField? = nil) {
        primaryLabel = primary
        secondaryLabel = secondary
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if isSelected {
                color = SwitcherStyle.accentColor.withAlphaComponent(0.18)
                primaryLabel?.textColor = .labelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            } else if isHovered {
                color = NSColor.labelColor.withAlphaComponent(0.065)
                primaryLabel?.textColor = .labelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            } else {
                color = normalColor
                primaryLabel?.textColor = .labelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            }
            layer?.backgroundColor = color.cgColor
            setAccessibilityValue(isSelected ? "Selected" : nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func setBackgroundColor(_ color: NSColor) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SwitcherPanel?
    private var localEventMonitor: Any?
    private var globalModifierMonitor: Any?
    private var cycleObserver: NSObjectProtocol?
    private var forwardSignalSource: DispatchSourceSignal?
    private var reverseSignalSource: DispatchSourceSignal?
    private var targetScreen: NSScreen?
    private var iconCache: [String: NSImage] = [:]
    private var allWindows: [AeroWindow] = []
    private var windowlessApps: [RunningApp] = []
    private var orderedItems: [SwitcherItem] = []
    private var itemRows: [String: ActionRow] = [:]
    private var selectedIndex: Int?
    private var focusedWindowID: Int?
    private var focusedApplicationPID: pid_t?
    private var pendingCycleDelta = 0
    private var commitWhenLoaded = false
    private var tracksOptionRelease = false
    private var launchDirection = 1
    private var singletonLockFileDescriptor: Int32 = -1
    private var isLoaded = false
    private var isRefreshing = false
    private var loadGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let invokedByShortcut = CommandLine.arguments.contains("--forward")
            || CommandLine.arguments.contains("--reverse")
        launchDirection = CommandLine.arguments.contains("--reverse") ? -1 : 1
        tracksOptionRelease = NSEvent.modifierFlags.contains(.option)
        commitWhenLoaded = invokedByShortcut && !tracksOptionRelease
        focusedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSApp.setActivationPolicy(.accessory)

        if !acquireSingletonLock() {
            DistributedNotificationCenter.default().postNotificationName(
                cycleNotificationName,
                object: nil,
                userInfo: ["direction": launchDirection],
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        startSignalHandling()
        writeDaemonPID()
        cycleObserver = DistributedNotificationCenter.default().addObserver(
            forName: cycleNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let direction = notification.userInfo?["direction"] as? Int ?? 1
            self?.handleCycleRequest(direction: direction)
        }

        if CommandLine.arguments.contains("--daemon") {
            // AeroSpace may not have created its socket yet during login or installation.
            // Keep the daemon responsive so the first shortcut can retry the load.
            loadWindows(presentErrors: false)
            return
        }
        showSwitcher()
        loadWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitoring()
        if let cycleObserver {
            DistributedNotificationCenter.default().removeObserver(cycleObserver)
        }
        forwardSignalSource?.cancel()
        reverseSignalSource?.cancel()
        if singletonLockFileDescriptor >= 0 {
            unlink(daemonPIDPath)
            flock(singletonLockFileDescriptor, LOCK_UN)
            close(singletonLockFileDescriptor)
        }
    }

    private func loadWindows(presentErrors: Bool = true) {
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshing = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                let focusedWindowID = AeroSpaceClient.focusedWindowID()
                let windows = try AeroSpaceClient.allWindows()
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    self.focusedWindowID = focusedWindowID
                    self.allWindows = windows
                    self.windowlessApps = self.runningAppsWithoutWindows(excluding: windows)
                    self.warmIconCache()
                    self.selectedIndex = nil
                    self.orderedItems = self.workspaceGroups()
                        .flatMap(\.windows)
                        .map(SwitcherItem.window)
                        + self.windowlessApps.map(SwitcherItem.application)
                    self.isLoaded = true
                    self.isRefreshing = false
                    guard !self.orderedItems.isEmpty else {
                        if presentErrors {
                            self.showError("No windows or applications are currently available.")
                        }
                        return
                    }
                    self.refreshContent()
                    self.prepareInitialSelection()
                    if self.commitWhenLoaded {
                        self.commitSelectedWindow()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.isRefreshing = false
                    if presentErrors {
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleCycleRequest(direction: Int) {
        if panel?.isVisible == true {
            if isRefreshing {
                pendingCycleDelta += direction
                return
            }
            moveSelection(by: direction)
            return
        }

        launchDirection = direction
        tracksOptionRelease = NSEvent.modifierFlags.contains(.option)
        commitWhenLoaded = !tracksOptionRelease
        focusedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusedWindowID = nil
        let hasCachedItems = !orderedItems.isEmpty
        pendingCycleDelta = 0
        selectedIndex = nil
        isLoaded = hasCachedItems
        showSwitcher()
        loadWindows()
    }

    private func showSwitcher() {
        stopEventMonitoring()
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens[0]
        targetScreen = screen
        let panel = SwitcherPanel(
            contentRect: switcherFrame(for: screen),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = makeContentView(for: screen)
        self.panel = panel

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            if event.type == .flagsChanged {
                self?.handleModifierFlags(event.modifierFlags)
            } else if event.keyCode == 53 {
                self?.tracksOptionRelease = false
                self?.dismiss()
                return nil
            } else if event.keyCode == 36 {
                self?.commitSelectedWindow()
                return nil
            }
            return event
        }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            DispatchQueue.main.async {
                self?.handleModifierFlags(event.modifierFlags)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func refreshContent() {
        guard let panel, let targetScreen else { return }
        panel.setFrame(switcherFrame(for: targetScreen), display: false)
        panel.contentView = makeContentView(for: targetScreen)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeContentView(for screen: NSScreen) -> NSView {
        itemRows.removeAll()
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let surface = SurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        let glass = GlassBackgroundView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.onDismiss = { [weak self] in self?.dismiss() }
        let tint = GlassTintView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            tint.topAnchor.constraint(equalTo: glass.topAnchor),
            tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let groupStack = NSStackView()
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        groupStack.orientation = .vertical
        groupStack.alignment = .width
        groupStack.spacing = SwitcherStyle.groupSpacing
        documentView.addSubview(groupStack)
        scrollView.documentView = documentView

        let groups = workspaceGroups()
        if !isLoaded {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            progress.translatesAutoresizingMaskIntoConstraints = false
            groupStack.addArrangedSubview(progress)
        } else {
            for group in groups {
                let groupView = makeWorkspaceView(group)
                groupStack.addArrangedSubview(groupView)
                groupView.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true
            }
            if !windowlessApps.isEmpty {
                let appGroupView = makeApplicationGroupView()
                groupStack.addArrangedSubview(appGroupView)
                appGroupView.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            groupStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            groupStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            groupStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            groupStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        root.addSubview(surface)
        surface.addSubview(glass)
        surface.addSubview(scrollView)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: SwitcherStyle.shadowMargin
            ),
            surface.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -SwitcherStyle.shadowMargin
            ),
            surface.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: SwitcherStyle.shadowMargin
            ),
            surface.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -SwitcherStyle.shadowMargin
            ),
            glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            glass.topAnchor.constraint(equalTo: surface.topAnchor),
            glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            scrollView.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor,
                constant: SwitcherStyle.contentPadding
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor,
                constant: -SwitcherStyle.contentPadding
            ),
            scrollView.topAnchor.constraint(
                equalTo: surface.topAnchor,
                constant: SwitcherStyle.contentPadding
            ),
            scrollView.bottomAnchor.constraint(
                equalTo: surface.bottomAnchor,
                constant: -SwitcherStyle.contentPadding
            ),
        ])

        return root
    }

    private func switcherFrame(for screen: NSScreen) -> NSRect {
        let groups = workspaceGroups()
        let groupCount = groups.count + (windowlessApps.isEmpty ? 0 : 1)
        let listHeight = CGFloat(groupCount) * SwitcherStyle.groupHeaderHeight
            + CGFloat(orderedItems.count) * SwitcherStyle.rowHeight
            + CGFloat(orderedItems.count) * SwitcherStyle.rowSpacing
            + CGFloat(max(0, groupCount - 1)) * SwitcherStyle.groupSpacing
        let visibleFrame = screen.visibleFrame
        let width = min(588, max(360, visibleFrame.width - 48))
        let maximumHeight = min(700, max(144, visibleFrame.height - 48))
        let surfaceChromeHeight = SwitcherStyle.contentPadding * 2
        let height = min(
            max(
                176,
                listHeight
                    + surfaceChromeHeight
                    + SwitcherStyle.shadowMargin * 2
            ),
            maximumHeight
        )

        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    private func makeWorkspaceView(_ group: WorkspaceGroup) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = SwitcherStyle.rowSpacing
        stack.addArrangedSubview(makeGroupHeader("WORKSPACE \(group.workspace)"))

        for window in group.windows {
            let row = makeWindowRow(window)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeApplicationGroupView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = SwitcherStyle.rowSpacing
        stack.addArrangedSubview(makeGroupHeader("OTHER APPS"))

        for app in windowlessApps {
            let row = makeApplicationRow(app)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeGroupHeader(_ text: String) -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let label = textLabel(
            text,
            size: 10,
            weight: .semibold,
            color: .tertiaryLabelColor
        )
        header.addSubview(label)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: SwitcherStyle.groupHeaderHeight),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
        return header
    }

    private func makeWindowRow(_ window: AeroWindow) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let fallbackTitle = window.windowTitle.isEmpty ? "Untitled Window" : window.windowTitle
        row.setAccessibilityLabel("\(window.appName), \(fallbackTitle)")
        let item = SwitcherItem.window(window)
        row.onClick = { [weak self] in self?.select(item) }

        let icon = NSImageView(image: appIcon(bundleID: window.appBundleID))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let windowTitle = textLabel(
            fallbackTitle,
            size: 15,
            weight: .medium,
            color: .labelColor
        )
        windowTitle.lineBreakMode = .byTruncatingTail
        windowTitle.maximumNumberOfLines = 1

        row.addSubview(icon)
        row.addSubview(windowTitle)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: SwitcherStyle.rowHeight),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            windowTitle.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            windowTitle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            windowTitle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.registerLabels(primary: windowTitle)
        itemRows[item.key] = row
        return row
    }

    private func makeApplicationRow(_ app: RunningApp) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityLabel(app.appName)
        let item = SwitcherItem.application(app)
        row.onClick = { [weak self] in self?.select(item) }

        let icon = NSImageView(image: appIcon(for: app))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let appName = textLabel(
            app.appName,
            size: 15,
            weight: .medium,
            color: .labelColor
        )
        appName.lineBreakMode = .byTruncatingTail
        appName.maximumNumberOfLines = 1

        row.addSubview(icon)
        row.addSubview(appName)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: SwitcherStyle.rowHeight),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            appName.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            appName.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            appName.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.registerLabels(primary: appName)
        itemRows[item.key] = row
        return row
    }

    private func workspaceGroups() -> [WorkspaceGroup] {
        let grouped = Dictionary(grouping: allWindows, by: \.workspace)
        let names = grouped.keys.sorted { left, right in
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                return leftNumber < rightNumber
            }
            if Int(left) != nil {
                return true
            }
            if Int(right) != nil {
                return false
            }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return names.map { WorkspaceGroup(workspace: $0, windows: grouped[$0] ?? []) }
    }

    private func prepareInitialSelection() {
        guard !orderedItems.isEmpty else { return }

        let initialIndex: Int
        if let focusedWindowID,
           let currentIndex = orderedItems.firstIndex(where: {
               guard case .window(let window) = $0 else { return false }
               return window.windowID == focusedWindowID
           }) {
            initialIndex = currentIndex + pendingCycleDelta
        } else if let focusedApplicationPID,
                  let currentIndex = orderedItems.firstIndex(where: {
                      guard case .application(let app) = $0 else { return false }
                      return app.processIdentifier == focusedApplicationPID
                  }) {
            initialIndex = currentIndex + pendingCycleDelta
        } else {
            let firstIndex = launchDirection > 0 ? 0 : orderedItems.count - 1
            initialIndex = firstIndex + pendingCycleDelta
        }
        pendingCycleDelta = 0
        setSelectedIndex(initialIndex)
    }

    private func moveSelection(by direction: Int) {
        guard !orderedItems.isEmpty else {
            pendingCycleDelta += direction
            return
        }

        if let selectedIndex {
            setSelectedIndex(selectedIndex + direction)
        } else {
            setSelectedIndex(direction > 0 ? 0 : orderedItems.count - 1)
        }
    }

    private func setSelectedIndex(_ index: Int) {
        guard !orderedItems.isEmpty else { return }

        if let selectedIndex {
            let previousItem = orderedItems[selectedIndex]
            itemRows[previousItem.key]?.isSelected = false
        }

        let count = orderedItems.count
        let normalizedIndex = ((index % count) + count) % count
        selectedIndex = normalizedIndex
        let selectedItem = orderedItems[normalizedIndex]
        if let row = itemRows[selectedItem.key] {
            row.isSelected = true
            row.scrollToVisible(row.bounds)
        }
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard tracksOptionRelease, !flags.contains(.option) else { return }
        tracksOptionRelease = false

        if isRefreshing || orderedItems.isEmpty {
            commitWhenLoaded = true
        } else {
            commitSelectedWindow()
        }
    }

    private func commitSelectedWindow() {
        guard
            let selectedIndex,
            orderedItems.indices.contains(selectedIndex)
        else {
            commitWhenLoaded = true
            return
        }
        select(orderedItems[selectedIndex])
    }

    private func select(_ item: SwitcherItem) {
        switch item {
        case .window(let window):
            let focusedWorkspace = focusedWindowID.flatMap { focusedID in
                allWindows.first { $0.windowID == focusedID }?.workspace
            }
            hideSwitcher()
            AeroSpaceClient.focus(
                windowID: window.windowID,
                switchingTo: focusedWorkspace == window.workspace
                    ? nil
                    : window.workspace
            )
        case .application(let app):
            hideSwitcher()
            reopenApplication(app)
        }
    }

    private func reopenApplication(_ app: RunningApp) {
        guard let runningApplication = NSRunningApplication(
            processIdentifier: app.processIdentifier
        ) else {
            return
        }

        runningApplication.activate(options: [])
        let target = NSAppleEventDescriptor(
            processIdentifier: app.processIdentifier
        )
        let reopenEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        do {
            _ = try reopenEvent.sendEvent(
                options: [.noReply, .neverInteract],
                timeout: 0
            )
            return
        } catch {
            // Fall back to LaunchServices only when the direct reopen event fails.
        }

        guard let applicationURL = runningApplication.bundleURL else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                runningApplication.activate(options: [])
            }
        }
    }

    private func dismiss() {
        hideSwitcher()
        NSApp.deactivate()
    }

    private func hideSwitcher() {
        tracksOptionRelease = false
        commitWhenLoaded = false
        pendingCycleDelta = 0
        selectedIndex = nil
        isRefreshing = false
        loadGeneration += 1
        panel?.orderOut(nil)
        panel = nil
        targetScreen = nil
        itemRows.removeAll()
        stopEventMonitoring()
    }

    private func stopEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "AeroSpace Window Switcher"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        dismiss()
    }

    private func appIcon(bundleID: String) -> NSImage {
        if let cachedIcon = iconCache[bundleID] {
            return cachedIcon
        }
        if !bundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let image = NSWorkspace.shared.icon(forFile: appURL.path)
            image.size = NSSize(
                width: SwitcherStyle.iconSize,
                height: SwitcherStyle.iconSize
            )
            iconCache[bundleID] = image
            return image
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    private func appIcon(for app: RunningApp) -> NSImage {
        let cacheKey = app.bundleIdentifier.isEmpty
            ? "pid:\(app.processIdentifier)"
            : app.bundleIdentifier
        if let cachedIcon = iconCache[cacheKey] {
            return cachedIcon
        }
        if let icon = NSRunningApplication(processIdentifier: app.processIdentifier)?.icon {
            icon.size = NSSize(
                width: SwitcherStyle.iconSize,
                height: SwitcherStyle.iconSize
            )
            iconCache[cacheKey] = icon
            return icon
        }
        return appIcon(bundleID: app.bundleIdentifier)
    }

    private func warmIconCache() {
        for window in allWindows {
            _ = appIcon(bundleID: window.appBundleID)
        }
        for app in windowlessApps {
            _ = appIcon(for: app)
        }
    }

    private func runningAppsWithoutWindows(excluding windows: [AeroWindow]) -> [RunningApp] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let windowBundleIdentifiers = Set(
            windows.map(\.appBundleID).filter { !$0.isEmpty }
        )
        let windowAppNames = Set(windows.map(\.appName))

        return NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningApp? in
                guard
                    app.processIdentifier != ownProcessIdentifier,
                    !app.isTerminated,
                    app.activationPolicy == .regular,
                    let appName = app.localizedName
                else {
                    return nil
                }

                let bundleIdentifier = app.bundleIdentifier ?? ""
                if !bundleIdentifier.isEmpty {
                    guard !windowBundleIdentifiers.contains(bundleIdentifier) else { return nil }
                } else {
                    guard !windowAppNames.contains(appName) else { return nil }
                }

                return RunningApp(
                    processIdentifier: app.processIdentifier,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                )
            }
            .sorted {
                $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
            }
    }

    private func startSignalHandling() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)

        let forwardSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        forwardSource.setEventHandler { [weak self] in
            self?.handleCycleRequest(direction: 1)
        }
        forwardSource.resume()
        forwardSignalSource = forwardSource

        let reverseSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        reverseSource.setEventHandler { [weak self] in
            self?.handleCycleRequest(direction: -1)
        }
        reverseSource.resume()
        reverseSignalSource = reverseSource
    }

    private func writeDaemonPID() {
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: daemonPIDPath,
            atomically: true,
            encoding: .utf8
        )
    }

    private func acquireSingletonLock() -> Bool {
        singletonLockFileDescriptor = open(
            singletonLockPath,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard singletonLockFileDescriptor >= 0 else { return true }

        if flock(singletonLockFileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }
        close(singletonLockFileDescriptor)
        singletonLockFileDescriptor = -1
        return false
    }

    private func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    private func textLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }
}

private let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
