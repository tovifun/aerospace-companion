import Cocoa
import Carbon
import Darwin
import QuartzCore

private let runtimeIdentifier = "io.github.tovifun.aerospace-companion.window-switcher"
private let runtimePathPrefix = "/tmp/\(runtimeIdentifier).\(getuid())"
private let cycleNotificationName = Notification.Name("\(runtimeIdentifier).cycle")
private let singletonLockPath = "\(runtimePathPrefix).lock"
private let daemonPIDPath = "\(runtimePathPrefix).pid"

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

    static func focus(windowID: Int) throws {
        guard let executable else {
            throw NSError(
                domain: "AeroSpaceWindowSwitcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AeroSpace CLI was not found"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["focus", "--window-id", String(windowID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
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

private final class OverlayView: NSVisualEffectView {
    var onDismiss: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.5)
                .cgColor
        }
    }
}

private final class ActionRow: NSControl {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var normalColor = NSColor.clear {
        didSet { updateAppearance() }
    }
    var isSelected = false {
        didSet { updateAppearance() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
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
        onHover?()
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        setBackgroundColor(NSColor.controlAccentColor.withAlphaComponent(0.28))
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

    private func updateAppearance() {
        let color: NSColor
        if isSelected {
            color = NSColor.controlAccentColor.withAlphaComponent(0.22)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            color = normalColor
        }
        setBackgroundColor(color)
        setAccessibilityValue(isSelected ? "Selected" : nil)
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
            if isRefreshing && !orderedItems.isEmpty {
                pendingCycleDelta += direction
            }
            moveSelection(by: direction)
            return
        }

        launchDirection = direction
        tracksOptionRelease = NSEvent.modifierFlags.contains(.option)
        commitWhenLoaded = !tracksOptionRelease
        focusedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusedWindowID = nil
        pendingCycleDelta = 0
        selectedIndex = nil
        isLoaded = !orderedItems.isEmpty
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
        panel.hasShadow = true
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
        let root = OverlayView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.borderWidth = 0.5
        root.layer?.masksToBounds = true
        root.onDismiss = { [weak self] in self?.dismiss() }

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
        groupStack.spacing = 10
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

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        return root
    }

    private func switcherFrame(for screen: NSScreen) -> NSRect {
        let groups = workspaceGroups()
        let groupCount = groups.count + (windowlessApps.isEmpty ? 0 : 1)
        let listHeight = CGFloat(groupCount * 24 + orderedItems.count * 32)
            + CGFloat(max(0, groupCount - 1) * 10)
        let visibleFrame = screen.visibleFrame
        let width = min(560, max(280, visibleFrame.width - 48))
        let maximumHeight = min(620, max(80, visibleFrame.height - 96))
        let height = min(max(80, listHeight + 16), maximumHeight)

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
        stack.spacing = 0

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let workspace = textLabel(
            group.workspace,
            size: 12,
            color: .secondaryLabelColor
        )
        header.addSubview(workspace)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24),
            workspace.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            workspace.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        stack.addArrangedSubview(header)

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
        stack.spacing = 0

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = textLabel(
            "Apps",
            size: 12,
            color: .secondaryLabelColor
        )
        header.addSubview(title)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        stack.addArrangedSubview(header)

        for app in windowlessApps {
            let row = makeApplicationRow(app)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeWindowRow(_ window: AeroWindow) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let fallbackTitle = window.windowTitle.isEmpty ? "Untitled Window" : window.windowTitle
        row.setAccessibilityLabel("\(window.appName), \(fallbackTitle)")
        let item = SwitcherItem.window(window)
        row.onClick = { [weak self] in self?.select(item) }
        row.onHover = { [weak self] in self?.selectRow(itemKey: item.key) }

        let icon = NSImageView(image: appIcon(bundleID: window.appBundleID))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = textLabel(fallbackTitle, size: 13, color: .labelColor)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        row.addSubview(icon)
        row.addSubview(title)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        itemRows[item.key] = row
        return row
    }

    private func makeApplicationRow(_ app: RunningApp) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityLabel(app.appName)
        let item = SwitcherItem.application(app)
        row.onClick = { [weak self] in self?.select(item) }
        row.onHover = { [weak self] in self?.selectRow(itemKey: item.key) }

        let icon = NSImageView(image: appIcon(for: app))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = textLabel(app.appName, size: 13, color: .labelColor)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        row.addSubview(icon)
        row.addSubview(title)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
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
            initialIndex = currentIndex + launchDirection + pendingCycleDelta
        } else if let focusedApplicationPID,
                  let currentIndex = orderedItems.firstIndex(where: {
                      guard case .application(let app) = $0 else { return false }
                      return app.processIdentifier == focusedApplicationPID
                  }) {
            initialIndex = currentIndex + launchDirection + pendingCycleDelta
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

    private func selectRow(itemKey: String) {
        guard let index = orderedItems.firstIndex(where: { $0.key == itemKey }) else {
            return
        }
        setSelectedIndex(index)
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard tracksOptionRelease, !flags.contains(.option) else { return }
        tracksOptionRelease = false

        if orderedItems.isEmpty {
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
        hideSwitcher()

        switch item {
        case .window(let window):
            try? AeroSpaceClient.focus(windowID: window.windowID)
        case .application(let app):
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
            image.size = NSSize(width: 18, height: 18)
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
            icon.size = NSSize(width: 18, height: 18)
            iconCache[cacheKey] = icon
            return icon
        }
        return appIcon(bundleID: app.bundleIdentifier)
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
