import Cocoa
import ApplicationServices
import Carbon
import CoreAudio
import Darwin
import QuartzCore

private let runtimeIdentifier = "io.github.tovifun.aerospace-companion.window-switcher"
// Runtime state must not live in /tmp: macOS purges /private/tmp files after a
// few days, which orphaned the daemon's pid file and silently broke the ⌥Tab
// trigger (the script could no longer find the daemon to signal). Keep
// pid/lock/status under the install root so they survive cleanup.
private let runtimeRootPath = "\(NSHomeDirectory())/.local/share/aerospace-companion/runtime"
private let runtimePathPrefix = "\(runtimeRootPath)/\(runtimeIdentifier).\(getuid())"
private let cycleNotificationName = Notification.Name("\(runtimeIdentifier).cycle")
private let singletonLockPath = "\(runtimePathPrefix).lock"
private let daemonPIDPath = "\(runtimePathPrefix).pid"
private let commandTabStatusPath = "\(runtimePathPrefix).command-tab-status"

private enum SwitcherConfiguration {
    static let hoveredItemActionPriorityKey = "hoveredItemActionPriority"

    static var hoveredItemActionPriority: Bool {
        UserDefaults.standard.bool(forKey: hoveredItemActionPriorityKey)
    }
}

private func localized(_ english: String, _ chinese: String) -> String {
    let preferredLanguage = Locale.preferredLanguages.first ?? "en"
    return preferredLanguage.hasPrefix("zh") ? chinese : english
}

private enum SwitcherStyle {
    static let maximumPanelHeight: CGFloat = 960
    static let panelScreenInset: CGFloat = 16
    static let surfaceCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 8
    static let shadowMargin: CGFloat = 24
    static let contentPadding: CGFloat = 8
    static let groupSpacing: CGFloat = 4
    static let groupHeaderHeight: CGFloat = 21
    static let rowSpacing: CGFloat = 0
    static let rowHeight: CGFloat = 38
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
    let appPID: pid_t
    let workspace: String
    let windowTitle: String
    let isFullscreen: Bool
    let windowLayout: String
    let workspaceIsFocused: Bool
    let workspaceIsVisible: Bool
    let monitorID: Int
    let monitorName: String

    enum CodingKeys: String, CodingKey {
        case windowID = "window-id"
        case appName = "app-name"
        case appBundleID = "app-bundle-id"
        case appPID = "app-pid"
        case workspace
        case windowTitle = "window-title"
        case isFullscreen = "window-is-fullscreen"
        case windowLayout = "window-layout"
        case workspaceIsFocused = "workspace-is-focused"
        case workspaceIsVisible = "workspace-is-visible"
        case monitorID = "monitor-id"
        case monitorName = "monitor-name"
    }
}

private struct WorkspaceGroup {
    let workspace: String
    let isFocused: Bool
    let isVisible: Bool
    let monitorID: Int
    let monitorName: String
    var windows: [AeroWindow]
}

private struct RunningApp {
    let processIdentifier: pid_t
    let appName: String
    let bundleIdentifier: String
}

private struct DockBadgeStatus {
    let rawLabel: String

    var displayCount: String? {
        let digits = rawLabel.compactMap(\.wholeNumberValue).map(String.init).joined()
        guard let count = Int(digits), count > 0 else { return nil }
        if rawLabel.contains("+") {
            return "\(count)+"
        }
        return count > 999 ? "999+" : String(count)
    }
}

private struct DockBadgeSnapshot {
    static let empty = DockBadgeSnapshot(bundleIdentifiers: [:], appNames: [:])

    let bundleIdentifiers: [String: DockBadgeStatus]
    let appNames: [String: DockBadgeStatus]

    func status(bundleIdentifier: String, appName: String) -> DockBadgeStatus? {
        if !bundleIdentifier.isEmpty,
           let status = bundleIdentifiers[bundleIdentifier] {
            return status
        }
        return appNames[appName.lowercased()]
    }
}

private enum DockBadgeClient {
    static func currentSnapshot() -> DockBadgeSnapshot {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first
        else {
            return .empty
        }

        var bundleIdentifiers: [String: DockBadgeStatus] = [:]
        var appNames: [String: DockBadgeStatus] = [:]
        collectBadges(
            from: AXUIElementCreateApplication(dock.processIdentifier),
            depth: 0,
            bundleIdentifiers: &bundleIdentifiers,
            appNames: &appNames
        )
        return DockBadgeSnapshot(
            bundleIdentifiers: bundleIdentifiers,
            appNames: appNames
        )
    }

    private static func collectBadges(
        from element: AXUIElement,
        depth: Int,
        bundleIdentifiers: inout [String: DockBadgeStatus],
        appNames: inout [String: DockBadgeStatus]
    ) {
        guard depth <= 4 else { return }

        let subrole = attribute("AXSubrole", from: element) as? String
        if subrole == "AXApplicationDockItem",
           let rawStatus = attribute("AXStatusLabel", from: element) as? String {
            let statusLabel = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statusLabel.isEmpty {
                let status = DockBadgeStatus(rawLabel: statusLabel)
                if let title = attribute("AXTitle", from: element) as? String,
                   !title.isEmpty {
                    appNames[title.lowercased()] = status
                }
                if let appURL = applicationURL(for: element),
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier {
                    bundleIdentifiers[bundleIdentifier] = status
                }
            }
        }

        guard let children = attribute("AXChildren", from: element) as? [AXUIElement]
        else {
            return
        }
        for child in children {
            collectBadges(
                from: child,
                depth: depth + 1,
                bundleIdentifiers: &bundleIdentifiers,
                appNames: &appNames
            )
        }
    }

    private static func applicationURL(for element: AXUIElement) -> URL? {
        let value = attribute("AXURL", from: element)
        if let url = value as? URL {
            return url
        }
        if let urlString = value as? String {
            return URL(string: urlString)
        }
        return nil
    }

    private static func attribute(
        _ name: String,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }
}

private struct AudioActivitySnapshot {
    static let empty = AudioActivitySnapshot(
        inputProcessIdentifiers: [],
        inputBundleIdentifiers: [],
        outputProcessIdentifiers: [],
        outputBundleIdentifiers: []
    )

    let inputProcessIdentifiers: Set<pid_t>
    let inputBundleIdentifiers: Set<String>
    let outputProcessIdentifiers: Set<pid_t>
    let outputBundleIdentifiers: Set<String>

    func isInputActive(processIdentifier: pid_t, bundleIdentifier: String) -> Bool {
        return contains(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            processIdentifiers: inputProcessIdentifiers,
            bundleIdentifiers: inputBundleIdentifiers
        )
    }

    func isOutputActive(processIdentifier: pid_t, bundleIdentifier: String) -> Bool {
        return contains(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            processIdentifiers: outputProcessIdentifiers,
            bundleIdentifiers: outputBundleIdentifiers
        )
    }

    private func contains(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        processIdentifiers: Set<pid_t>,
        bundleIdentifiers: Set<String>
    ) -> Bool {
        if processIdentifiers.contains(processIdentifier) {
            return true
        }

        let normalizedBundleIdentifier = bundleIdentifier.lowercased()
        guard !normalizedBundleIdentifier.isEmpty else { return false }
        return bundleIdentifiers.contains { audioBundleIdentifier in
            audioBundleIdentifier == normalizedBundleIdentifier
                || audioBundleIdentifier.hasPrefix(normalizedBundleIdentifier + ".")
        }
    }
}

private enum AudioActivityClient {
    static func currentSnapshot() -> AudioActivitySnapshot {
        let processObjects = audioProcessObjects()
        guard !processObjects.isEmpty else { return .empty }

        var inputProcessIdentifiers: Set<pid_t> = []
        var inputBundleIdentifiers: Set<String> = []
        var outputProcessIdentifiers: Set<pid_t> = []
        var outputBundleIdentifiers: Set<String> = []
        for processObject in processObjects {
            let isInputActive = isRunning(
                processObject,
                selector: kAudioProcessPropertyIsRunningInput
            )
            let isOutputActive = isRunning(
                processObject,
                selector: kAudioProcessPropertyIsRunningOutput
            )
            guard isInputActive || isOutputActive else { continue }
            guard let processIdentifier = processIdentifier(processObject) else { continue }
            let bundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier
            )?.bundleIdentifier?.lowercased()

            if isInputActive {
                inputProcessIdentifiers.insert(processIdentifier)
                if let bundleIdentifier {
                    inputBundleIdentifiers.insert(bundleIdentifier)
                }
            }
            if isOutputActive {
                outputProcessIdentifiers.insert(processIdentifier)
                if let bundleIdentifier {
                    outputBundleIdentifiers.insert(bundleIdentifier)
                }
            }
        }
        return AudioActivitySnapshot(
            inputProcessIdentifiers: inputProcessIdentifiers,
            inputBundleIdentifiers: inputBundleIdentifiers,
            outputProcessIdentifiers: outputProcessIdentifiers,
            outputBundleIdentifiers: outputBundleIdentifiers
        )
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var processObjects = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: count
        )
        let status = processObjects.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        return status == noErr ? processObjects : []
    }

    private static func processIdentifier(_ processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr, value > 0 else {
            return nil
        }
        return value
    }

    private static func isRunning(
        _ processObject: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr && value != 0
    }
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

private enum WindowControlAction {
    case moveWindowToWorkspace(String)
    case moveApplicationToWorkspace(String)
    case toggleFloating
    case toggleFullscreen
    case toggleTilesAccordion
    case toggleOrientation
    case balanceWorkspace
    case resetWorkspace
    case moveToMonitor(String)
    case swap(String)
    case join(String)
    case resize(dimension: String, delta: Int)
}

private struct WindowControlRequest {
    let action: WindowControlAction
    let targetWindowID: Int
    let targetWorkspace: String
    let applicationWindowIDs: [Int]
    let keepsPanelOpen: Bool
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
        let format = [
            "%{window-id}",
            "%{app-name}",
            "%{app-bundle-id}",
            "%{app-pid}",
            "%{workspace}",
            "%{window-title}",
            "%{window-is-fullscreen}",
            "%{window-layout}",
            "%{workspace-is-focused}",
            "%{workspace-is-visible}",
            "%{monitor-id}",
            "%{monitor-name}",
        ].joined(separator: " ")
        let data = try run(["list-windows", "--all", "--json", "--format", format])
        let windows = try JSONDecoder().decode([AeroWindow].self, from: data)
        return excludingStaleUntitledWindows(windows)
    }

    private static func excludingStaleUntitledWindows(
        _ windows: [AeroWindow]
    ) -> [AeroWindow] {
        let hasUntitledWindows = windows.contains {
            $0.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasUntitledWindows else { return windows }

        guard let windowDescriptions = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // Keep AeroSpace's result if WindowServer cannot be queried. It is
            // safer to show an extra item than hide a real untitled window.
            return windows
        }

        var liveWindowOwners: [Int: pid_t] = [:]
        for description in windowDescriptions {
            guard
                let windowID = description[kCGWindowNumber as String] as? NSNumber,
                let ownerPID = description[kCGWindowOwnerPID as String] as? NSNumber
            else {
                continue
            }
            liveWindowOwners[windowID.intValue] = pid_t(ownerPID.int32Value)
        }

        return windows.filter { window in
            let isUntitled = window.windowTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return !isUntitled || liveWindowOwners[window.windowID] == window.appPID
        }
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

    static func close(windowID: Int, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try run(["close", "--window-id", String(windowID)])
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    static func perform(_ request: WindowControlRequest) throws {
        let windowID = String(request.targetWindowID)
        switch request.action {
        case .moveWindowToWorkspace(let workspace):
            _ = try run([
                "move-node-to-workspace", "--focus-follows-window",
                "--window-id", windowID, workspace,
            ])
        case .moveApplicationToWorkspace(let workspace):
            let windowIDs = request.applicationWindowIDs.isEmpty
                ? [request.targetWindowID]
                : request.applicationWindowIDs
            for applicationWindowID in windowIDs where applicationWindowID != request.targetWindowID {
                _ = try run([
                    "move-node-to-workspace", "--window-id",
                    String(applicationWindowID), workspace,
                ])
            }
            _ = try run([
                "move-node-to-workspace", "--focus-follows-window",
                "--window-id", windowID, workspace,
            ])
        case .toggleFloating:
            _ = try run(["layout", "--window-id", windowID, "floating", "tiling"])
        case .toggleFullscreen:
            _ = try run(["fullscreen", "--window-id", windowID])
        case .toggleTilesAccordion:
            _ = try run(["layout", "--window-id", windowID, "tiles", "accordion"])
        case .toggleOrientation:
            _ = try run(["layout", "--window-id", windowID, "horizontal", "vertical"])
        case .balanceWorkspace:
            _ = try run(["balance-sizes", "--workspace", request.targetWorkspace])
        case .resetWorkspace:
            _ = try run(["flatten-workspace-tree", "--workspace", request.targetWorkspace])
            _ = try run(["balance-sizes", "--workspace", request.targetWorkspace])
        case .moveToMonitor(let direction):
            _ = try run([
                "move-node-to-monitor", "--focus-follows-window",
                "--window-id", windowID, "--wrap-around", direction,
            ])
        case .swap(let direction):
            _ = try run(["swap", "--window-id", windowID, direction])
        case .join(let direction):
            _ = try run(["join-with", "--window-id", windowID, direction])
        case .resize(let dimension, let delta):
            _ = try run([
                "resize", "--window-id", windowID,
                dimension, delta >= 0 ? "+\(delta)" : String(delta),
            ])
        }
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

private final class OverflowFadingScrollView: NSScrollView {
    private let overflowMask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overflowMask.startPoint = CGPoint(x: 0.5, y: 0)
        overflowMask.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateOverflowMask()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateOverflowMask()
    }

    private func updateOverflowMask() {
        guard
            let layer,
            let documentView,
            bounds.height > 0
        else {
            return
        }

        let viewportHeight = contentView.bounds.height
        let maximumOffset = max(0, documentView.bounds.height - viewportHeight)
        guard maximumOffset > 1 else {
            layer.mask = nil
            return
        }

        let currentOffset = contentView.bounds.origin.y
        let canScrollAbove = currentOffset > 1
        let canScrollBelow = currentOffset < maximumOffset - 1
        let opaque = NSColor.white.cgColor
        let transparent = NSColor.white.withAlphaComponent(0).cgColor
        let fadeFraction = min(0.08, 12 / bounds.height)

        // NSScrollView's backing layer starts at the visual bottom. Only fade an
        // edge while more rows exist in that direction, preserving the clean
        // no-scrollbar appearance without hiding that the list continues.
        overflowMask.colors = [
            canScrollBelow ? transparent : opaque,
            opaque,
            opaque,
            canScrollAbove ? transparent : opaque,
        ]
        overflowMask.locations = [
            0,
            NSNumber(value: fadeFraction),
            NSNumber(value: 1 - fadeFraction),
            1,
        ]
        overflowMask.frame = bounds
        layer.mask = overflowMask
    }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class WindowControlTile: NSControl {
    var onPress: ((NSEvent.ModifierFlags) -> Void)?
    var isHighlightedState = false {
        didSet { updateAppearance() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(title: String, detail: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        stack.addArrangedSubview(titleLabel)

        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.46)
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(detailLabel)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 50),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
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

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onPress?(event.modifierFlags)
        }
        updateAppearance()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?([])
        return true
    }

    private func updateAppearance() {
        let background: NSColor
        if isHighlightedState {
            background = SwitcherStyle.accentColor.withAlphaComponent(0.24)
        } else if isHovered {
            background = NSColor.white.withAlphaComponent(0.12)
        } else {
            background = NSColor.white.withAlphaComponent(0.065)
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = isHighlightedState ? 1 : 0.5
        layer?.borderColor = (isHighlightedState
            ? SwitcherStyle.accentColor.withAlphaComponent(0.68)
            : NSColor.white.withAlphaComponent(0.10)
        ).cgColor
    }
}

private final class WindowControlSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WindowControlPanelController {
    private enum Mode {
        case main
        case arrange
        case resize
    }

    var onCommand: ((WindowControlRequest) -> Void)?

    var isVisible: Bool { panel.isVisible }

    private let panel: SwitcherPanel
    private var localKeyMonitor: Any?
    private var windows: [AeroWindow] = []
    private var targetWindowID: Int?
    private var mode: Mode = .main
    private weak var targetScreen: NSScreen?

    init() {
        panel = SwitcherPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = true
        rebuildContent()
    }

    func update(windows: [AeroWindow], focusedWindowID: Int?) {
        self.windows = windows
        if !isVisible || targetWindowID == nil || targetWindow == nil {
            targetWindowID = focusedWindowID
        }
        rebuildContent()
        if isVisible, let targetScreen {
            positionPanel(on: targetScreen)
        }
    }

    func show(on screen: NSScreen) {
        targetScreen = screen
        mode = .main
        rebuildContent()
        positionPanel(on: screen)
        startKeyMonitoring()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hide(deactivateApplication: Bool = true) {
        stopKeyMonitoring()
        panel.orderOut(nil)
        mode = .main
        if deactivateApplication {
            NSApp.deactivate()
        }
    }

    private var targetWindow: AeroWindow? {
        targetWindowID.flatMap { targetID in
            windows.first { $0.windowID == targetID }
        }
    }

    private var panelSize: NSSize {
        switch mode {
        case .main:
            return NSSize(width: 820, height: 490)
        case .arrange, .resize:
            return NSSize(width: 720, height: 260)
        }
    }

    private func positionPanel(on screen: NSScreen) {
        let size = panelSize
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
    }

    private func rebuildContent() {
        let container = NSView()
        let surface = WindowControlSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)

        addFullWidth(makeHeader(), to: content)
        switch mode {
        case .main:
            buildMainContent(in: content)
        case .arrange:
            buildArrangeContent(in: content)
        case .resize:
            buildResizeContent(in: content)
        }

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: surface.bottomAnchor, constant: -18),
        ])
        panel.contentView = container
    }

    private func makeHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let titleText: String
        if let window = targetWindow {
            let windowTitle = window.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            titleText = windowTitle.isEmpty || windowTitle == window.appName
                ? window.appName
                : "\(window.appName)  —  \(windowTitle)"
        } else {
            titleText = localized("No focused window", "没有当前窗口")
        }
        let title = makeLabel(titleText, size: 16, weight: .semibold, alpha: 0.94)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        stack.addArrangedSubview(title)

        let metadata: String
        if let window = targetWindow {
            let layout = localizedLayout(window.windowLayout)
            let appWindowCount = applicationWindows(for: window).count
            metadata = [
                workspaceDisplayName(window.workspace),
                window.monitorName,
                layout,
                localized("\(appWindowCount) app windows", "当前 App \(appWindowCount) 个窗口"),
            ].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        } else {
            metadata = localized(
                "Focus an AeroSpace window, then reopen this panel.",
                "请先聚焦一个 AeroSpace 窗口，再重新打开面板。"
            )
        }
        stack.addArrangedSubview(makeLabel(metadata, size: 11, weight: .regular, alpha: 0.48))
        return stack
    }

    private func buildMainContent(in content: NSStackView) {
        addFullWidth(makeSectionTitle(localized("MOVE TO WORKSPACE", "移动到 WORKSPACE")), to: content)

        let workspaceGrid = verticalGrid()
        for rowRange in [1...5, 6...10] {
            let row = horizontalGrid()
            for index in rowRange {
                let workspace = String(index)
                let key = index == 10 ? "0" : workspace
                let count = windows.filter { $0.workspace == workspace }.count
                let current = targetWindow?.workspace == workspace
                let detail = [
                    localized("\(count) windows", "\(count) 个窗口"),
                    current ? localized("CURRENT", "当前") : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                let tile = WindowControlTile(
                    title: "\(key)  \(workspaceShortName(workspace))",
                    detail: detail
                )
                tile.isHighlightedState = current
                tile.onPress = { [weak self] modifiers in
                    self?.moveToWorkspace(workspace, entireApplication: modifiers.contains(.shift))
                }
                row.addArrangedSubview(tile)
            }
            workspaceGrid.addArrangedSubview(row)
        }
        addFullWidth(workspaceGrid, to: content)

        addFullWidth(makeSectionTitle(localized("LAYOUT", "布局")), to: content)
        let layoutGrid = verticalGrid()
        let firstLayoutRow = horizontalGrid()
        let isFloating = targetWindow?.windowLayout == "floating"
        let isFullscreen = targetWindow?.isFullscreen == true
        firstLayoutRow.addArrangedSubview(actionTile(
            title: localized("F  FLOAT / TILE", "F  浮动 / 平铺"),
            detail: isFloating ? localized("CURRENT: FLOATING", "当前：浮动") : localized("CURRENT: TILING", "当前：平铺"),
            highlighted: isFloating,
            action: .toggleFloating
        ))
        firstLayoutRow.addArrangedSubview(actionTile(
            title: localized("M  FULLSCREEN", "M  全屏"),
            detail: isFullscreen ? localized("CURRENT: ON", "当前：开启") : localized("AEROSPACE FULLSCREEN", "AeroSpace 全屏"),
            highlighted: isFullscreen,
            action: .toggleFullscreen
        ))
        firstLayoutRow.addArrangedSubview(actionTile(
            title: localized("T  TILES / ACCORDION", "T  TILES / ACCORDION"),
            detail: localizedLayout(targetWindow?.windowLayout ?? ""),
            action: .toggleTilesAccordion,
            keepsPanelOpen: true
        ))
        layoutGrid.addArrangedSubview(firstLayoutRow)

        let secondLayoutRow = horizontalGrid()
        secondLayoutRow.addArrangedSubview(actionTile(
            title: localized("O  ORIENTATION", "O  横向 / 纵向"),
            detail: localizedOrientation(targetWindow?.windowLayout ?? ""),
            action: .toggleOrientation,
            keepsPanelOpen: true
        ))
        secondLayoutRow.addArrangedSubview(actionTile(
            title: localized("B  BALANCE", "B  均分窗口"),
            detail: localized("Equalize current workspace", "均分当前 workspace"),
            action: .balanceWorkspace
        ))
        secondLayoutRow.addArrangedSubview(actionTile(
            title: localized("R  RESET", "R  重置布局"),
            detail: localized("Flatten and balance", "扁平化并均分"),
            action: .resetWorkspace
        ))
        layoutGrid.addArrangedSubview(secondLayoutRow)
        addFullWidth(layoutGrid, to: content)

        addFullWidth(makeSectionTitle(localized("POSITION & ARRANGE", "位置与整理")), to: content)
        let positionRow = horizontalGrid()
        positionRow.addArrangedSubview(actionTile(
            title: localized("←  PREVIOUS DISPLAY", "←  上一个显示器"),
            detail: localized("Move window and follow", "移动窗口并跟随"),
            action: .moveToMonitor("prev")
        ))
        positionRow.addArrangedSubview(actionTile(
            title: localized("→  NEXT DISPLAY", "→  下一个显示器"),
            detail: localized("Move window and follow", "移动窗口并跟随"),
            action: .moveToMonitor("next")
        ))
        positionRow.addArrangedSubview(modeTile(
            title: localized("A  ARRANGE", "A  排列模式"),
            detail: localized("Swap or group windows", "交换或编组窗口"),
            mode: .arrange
        ))
        positionRow.addArrangedSubview(modeTile(
            title: localized("Z  RESIZE", "Z  缩放模式"),
            detail: localized("Coarse and fine sizing", "粗调与精调尺寸"),
            mode: .resize
        ))
        addFullWidth(positionRow, to: content)

        addFullWidth(makeFooter(localized(
            "1–0 current window   ⇧1–0 entire app   click actions   esc close",
            "1–0 当前窗口   ⇧1–0 当前 App 全部窗口   点击也可操作   esc 关闭"
        )), to: content)
    }

    private func buildArrangeContent(in content: NSStackView) {
        addFullWidth(makeSectionTitle(localized(
            "ARRANGE · H/J/K/L SWAP · SHIFT GROUP",
            "排列 · H/J/K/L 交换 · SHIFT 编组"
        )), to: content)
        let swapRow = horizontalGrid()
        for (key, direction, chinese) in [
            ("H", "left", "左"), ("J", "down", "下"),
            ("K", "up", "上"), ("L", "right", "右"),
        ] {
            swapRow.addArrangedSubview(actionTile(
                title: localized("\(key)  SWAP \(direction.uppercased())", "\(key)  向\(chinese)交换"),
                detail: localized("Shift: group", "Shift：编组"),
                action: .swap(direction),
                keepsPanelOpen: true,
                shiftedAction: .join(direction)
            ))
        }
        addFullWidth(swapRow, to: content)

        let utilityRow = horizontalGrid()
        utilityRow.addArrangedSubview(actionTile(
            title: localized("R  RESET WORKSPACE", "R  重置 WORKSPACE"),
            detail: localized("Flatten and balance", "扁平化并均分"),
            action: .resetWorkspace
        ))
        utilityRow.addArrangedSubview(modeTile(
            title: localized("↩  MAIN PANEL", "↩  返回主面板"),
            detail: localized("Press Return", "按 Return"),
            mode: .main
        ))
        addFullWidth(utilityRow, to: content)
        addFullWidth(makeFooter(localized(
            "Repeat H/J/K/L to arrange   return main panel   esc close",
            "可连续按 H/J/K/L 整理   Return 返回主面板   esc 关闭"
        )), to: content)
    }

    private func buildResizeContent(in content: NSStackView) {
        addFullWidth(makeSectionTitle(localized(
            "RESIZE · 50 PT · HOLD SHIFT FOR 10 PT",
            "缩放 · 每次 50 PT · 按住 SHIFT 微调 10 PT"
        )), to: content)
        let resizeRow = horizontalGrid()
        for (key, dimension, delta, label) in [
            ("H", "width", -50, localized("NARROWER", "减小宽度")),
            ("L", "width", 50, localized("WIDER", "增加宽度")),
            ("K", "height", -50, localized("SHORTER", "减小高度")),
            ("J", "height", 50, localized("TALLER", "增加高度")),
        ] {
            resizeRow.addArrangedSubview(actionTile(
                title: "\(key)  \(label)",
                detail: localized("50 pt · Shift 10 pt", "50 pt · Shift 10 pt"),
                action: .resize(dimension: dimension, delta: delta),
                keepsPanelOpen: true
            ))
        }
        addFullWidth(resizeRow, to: content)

        let mainRow = horizontalGrid()
        mainRow.addArrangedSubview(actionTile(
            title: localized("B  BALANCE", "B  均分窗口"),
            detail: localized("Reset window proportions", "恢复均匀比例"),
            action: .balanceWorkspace
        ))
        mainRow.addArrangedSubview(modeTile(
            title: localized("↩  MAIN PANEL", "↩  返回主面板"),
            detail: localized("Press Return", "按 Return"),
            mode: .main
        ))
        addFullWidth(mainRow, to: content)
        addFullWidth(makeFooter(localized(
            "Keys repeat while held   return main panel   esc close",
            "按住按键可连续调整   Return 返回主面板   esc 关闭"
        )), to: content)
    }

    private func actionTile(
        title: String,
        detail: String,
        highlighted: Bool = false,
        action: WindowControlAction,
        keepsPanelOpen: Bool = false,
        shiftedAction: WindowControlAction? = nil
    ) -> WindowControlTile {
        let tile = WindowControlTile(title: title, detail: detail)
        tile.isHighlightedState = highlighted
        tile.onPress = { [weak self] modifiers in
            let selectedAction = modifiers.contains(.shift)
                ? (shiftedAction ?? action)
                : action
            self?.perform(selectedAction, keepsPanelOpen: keepsPanelOpen)
        }
        return tile
    }

    private func modeTile(title: String, detail: String, mode: Mode) -> WindowControlTile {
        let tile = WindowControlTile(title: title, detail: detail)
        tile.onPress = { [weak self] _ in
            self?.mode = mode
            self?.rebuildContent()
            if let screen = self?.targetScreen {
                self?.positionPanel(on: screen)
            }
        }
        return tile
    }

    private func moveToWorkspace(_ workspace: String, entireApplication: Bool) {
        perform(
            entireApplication
                ? .moveApplicationToWorkspace(workspace)
                : .moveWindowToWorkspace(workspace),
            keepsPanelOpen: false
        )
    }

    private func perform(_ action: WindowControlAction, keepsPanelOpen: Bool) {
        guard let window = targetWindow else {
            NSSound.beep()
            return
        }
        let request = WindowControlRequest(
            action: action,
            targetWindowID: window.windowID,
            targetWorkspace: window.workspace,
            applicationWindowIDs: applicationWindows(for: window).map(\.windowID),
            keepsPanelOpen: keepsPanelOpen
        )
        if !keepsPanelOpen {
            hide()
        }
        onCommand?(request)
    }

    private func applicationWindows(for window: AeroWindow) -> [AeroWindow] {
        windows.filter {
            !window.appBundleID.isEmpty
                ? $0.appBundleID == window.appBundleID
                : $0.appPID == window.appPID
        }
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func horizontalGrid() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func verticalGrid() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        makeLabel(text, size: 9.5, weight: .semibold, alpha: 0.34)
    }

    private func makeFooter(_ text: String) -> NSTextField {
        let label = makeLabel(text, size: 10.5, weight: .regular, alpha: 0.38)
        label.alignment = .center
        return label
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        alpha: CGFloat
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        return label
    }

    private func workspaceShortName(_ workspace: String) -> String {
        switch workspace {
        case "1": return localized("Media", "媒体会议")
        case "2": return localized("Browse", "浏览资料")
        case "3": return localized("Temp", "临时预览")
        case "4": return localized("Code", "Codex 编辑器")
        case "5": return localized("Terminal", "终端 Agent")
        case "6": return localized("Dev Tools", "开发辅助")
        case "7": return localized("Content", "设计内容")
        case "8": return localized("Comms", "沟通")
        case "9": return localized("AI", "AI 研究")
        case "10": return localized("Ambient", "氛围空屏")
        default: return workspace
        }
    }

    private func workspaceDisplayName(_ workspace: String) -> String {
        localized("Workspace \(workspace)", "Workspace \(workspace)")
            + " · " + workspaceShortName(workspace)
    }

    private func localizedLayout(_ layout: String) -> String {
        if layout == "floating" {
            return localized("FLOATING", "浮动")
        }
        if layout.contains("accordion") {
            return localized("ACCORDION", "手风琴")
        }
        if layout.contains("tiles") {
            return localized("TILES", "平铺")
        }
        return layout.uppercased()
    }

    private func localizedOrientation(_ layout: String) -> String {
        if layout.hasPrefix("h_") {
            return localized("CURRENT: HORIZONTAL", "当前：横向")
        }
        if layout.hasPrefix("v_") {
            return localized("CURRENT: VERTICAL", "当前：纵向")
        }
        return localized("Horizontal / vertical", "横向 / 纵向")
    }

    private func startKeyMonitoring() {
        stopKeyMonitoring()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.hide()
                return nil
            }
            if self.mode != .main && (event.keyCode == 36 || event.keyCode == 51) {
                self.mode = .main
                self.rebuildContent()
                if let screen = self.targetScreen {
                    self.positionPanel(on: screen)
                }
                return nil
            }
            if self.mode != .resize && event.isARepeat {
                return nil
            }
            self.handleKey(event)
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) {
        let character = event.charactersIgnoringModifiers?.lowercased().first
        let shift = event.modifierFlags.contains(.shift)

        switch mode {
        case .main:
            if let character, "1234567890".contains(character) {
                moveToWorkspace(
                    character == "0" ? "10" : String(character),
                    entireApplication: shift
                )
                return
            }
            if event.keyCode == 123 {
                perform(.moveToMonitor("prev"), keepsPanelOpen: false)
                return
            }
            if event.keyCode == 124 {
                perform(.moveToMonitor("next"), keepsPanelOpen: false)
                return
            }
            switch character {
            case "f": perform(.toggleFloating, keepsPanelOpen: false)
            case "m": perform(.toggleFullscreen, keepsPanelOpen: false)
            case "t": perform(.toggleTilesAccordion, keepsPanelOpen: true)
            case "o": perform(.toggleOrientation, keepsPanelOpen: true)
            case "b": perform(.balanceWorkspace, keepsPanelOpen: false)
            case "r": perform(.resetWorkspace, keepsPanelOpen: false)
            case "a":
                mode = .arrange
                rebuildContent()
                if let targetScreen { positionPanel(on: targetScreen) }
            case "z":
                mode = .resize
                rebuildContent()
                if let targetScreen { positionPanel(on: targetScreen) }
            default: NSSound.beep()
            }
        case .arrange:
            guard let direction = direction(for: character) else {
                if character == "r" {
                    perform(.resetWorkspace, keepsPanelOpen: false)
                } else {
                    NSSound.beep()
                }
                return
            }
            perform(shift ? .join(direction) : .swap(direction), keepsPanelOpen: true)
        case .resize:
            let fineAmount = shift ? 10 : 50
            switch character {
            case "h": perform(.resize(dimension: "width", delta: -fineAmount), keepsPanelOpen: true)
            case "l": perform(.resize(dimension: "width", delta: fineAmount), keepsPanelOpen: true)
            case "k": perform(.resize(dimension: "height", delta: -fineAmount), keepsPanelOpen: true)
            case "j": perform(.resize(dimension: "height", delta: fineAmount), keepsPanelOpen: true)
            case "b": perform(.balanceWorkspace, keepsPanelOpen: false)
            default: NSSound.beep()
            }
        }
    }

    private func direction(for character: Character?) -> String? {
        switch character {
        case "h": return "left"
        case "j": return "down"
        case "k": return "up"
        case "l": return "right"
        default: return nil
        }
    }

    private func stopKeyMonitoring() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
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
    var onHoverChanged: ((Bool) -> Void)?
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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
        onHoverChanged?(false)
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

private final class PermissionGuideWindowController: NSWindowController {
    var onRequestAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onRevealApplication: (() -> Void)?
    var onRestartApplication: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(
        title: localized("Open Settings", "打开设置"),
        target: nil,
        action: nil
    )
    private let inputMonitoringButton = NSButton(
        title: localized("Open Settings", "打开设置"),
        target: nil,
        action: nil
    )
    private let restartButton = NSButton(
        title: localized("Restart Switcher", "重新启动切换器"),
        target: nil,
        action: nil
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("Set Up Command + Tab", "设置 Command + Tab")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        accessibilityTrusted: Bool,
        listenAccess: Bool,
        eventTapCreated: Bool
    ) {
        updateStatusLabel(accessibilityStatusLabel, isAllowed: accessibilityTrusted)
        updateStatusLabel(inputMonitoringStatusLabel, isAllowed: listenAccess)
        accessibilityButton.isEnabled = !accessibilityTrusted
        inputMonitoringButton.isEnabled = !listenAccess

        if eventTapCreated {
            summaryLabel.stringValue = localized(
                "Setup is complete. AeroSpace Window Switcher now handles Command + Tab.",
                "设置完成，Command + Tab 已由 AeroSpace Window Switcher 接管。"
            )
            summaryLabel.textColor = .systemGreen
            restartButton.isHidden = true
        } else if accessibilityTrusted && listenAccess {
            summaryLabel.stringValue = localized(
                "Permissions are enabled. Restart the switcher to apply them.",
                "权限已经开启，需要重新启动切换器后生效。"
            )
            summaryLabel.textColor = .systemOrange
            restartButton.isHidden = false
        } else {
            summaryLabel.stringValue = localized(
                "Complete both settings to enable it automatically. AeroSpace does not need to restart.",
                "完成下面两项设置后会自动启用，不需要重启 AeroSpace。"
            )
            summaryLabel.textColor = .secondaryLabelColor
            restartButton.isHidden = true
        }
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: localized(
            "Use Command + Tab to Switch Windows",
            "让 Command + Tab 切换窗口"
        ))
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let description = NSTextField(wrappingLabelWithString: localized(
            "Two one-time macOS permissions are required to replace the system app switcher.",
            "为了隐藏 macOS 自带的 App 切换器并监听快捷键，需要一次性授予两项系统权限。"
        ))
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 13)

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byWordWrapping

        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        accessibilityButton.bezelStyle = .rounded
        let accessibilityRow = makePermissionRow(
            title: localized("Accessibility", "辅助功能"),
            detail: localized(
                "Replaces the system Command + Tab switcher.",
                "允许切换器拦截并替换系统 Command + Tab。"
            ),
            statusLabel: accessibilityStatusLabel,
            button: accessibilityButton
        )

        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(requestInputMonitoring)
        inputMonitoringButton.bezelStyle = .rounded
        let inputMonitoringRow = makePermissionRow(
            title: localized("Input Monitoring", "输入监控"),
            detail: localized(
                "Reads Command, Shift, and Tab key presses.",
                "允许切换器读取 Command、Shift 和 Tab 按键。"
            ),
            statusLabel: inputMonitoringStatusLabel,
            button: inputMonitoringButton
        )

        let help = NSTextField(wrappingLabelWithString: localized(
            "If the app is missing from Input Monitoring, reveal it and add it with the + button. Choose Quit & Reopen when macOS asks.",
            "如果“输入监控”列表里没有本应用，请点“显示应用”，再用列表下方的 + 添加。系统询问时请选择“退出并重新打开”。"
        ))
        help.textColor = .tertiaryLabelColor
        help.font = .systemFont(ofSize: 11)

        let revealButton = NSButton(
            title: localized("Reveal App", "显示应用"),
            target: self,
            action: #selector(revealApplication)
        )
        revealButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartApplication)
        restartButton.bezelStyle = .rounded
        restartButton.keyEquivalent = "\r"
        restartButton.isHidden = true

        let laterButton = NSButton(
            title: localized("Later", "稍后"),
            target: self,
            action: #selector(closeGuide)
        )
        laterButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [revealButton, restartButton, laterButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let content = NSStackView(views: [
            title,
            description,
            summaryLabel,
            accessibilityRow,
            inputMonitoringRow,
            help,
            buttons,
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(5, after: title)
        content.setCustomSpacing(8, after: description)
        content.setCustomSpacing(7, after: accessibilityRow)
        content.setCustomSpacing(10, after: inputMonitoringRow)
        contentView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            accessibilityRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            inputMonitoringRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            description.widthAnchor.constraint(equalTo: content.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            help.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    private func makePermissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        button: NSButton
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labels)
        container.addSubview(statusLabel)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 58),
            labels.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 84),
        ])
        return container
    }

    private func updateStatusLabel(_ label: NSTextField, isAllowed: Bool) {
        label.stringValue = isAllowed
            ? localized("✓ Allowed", "✓ 已允许")
            : localized("Not Set", "待设置")
        label.textColor = isAllowed ? .systemGreen : .systemOrange
    }

    @objc private func requestAccessibility() {
        onRequestAccessibility?()
    }

    @objc private func requestInputMonitoring() {
        onRequestInputMonitoring?()
    }

    @objc private func revealApplication() {
        onRevealApplication?()
    }

    @objc private func restartApplication() {
        onRestartApplication?()
    }

    @objc private func closeGuide() {
        close()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let commandTabEventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let delegate = Unmanaged<AppDelegate>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return delegate.handleCommandTabEvent(type: type, event: event)
    }

    private var panel: SwitcherPanel?
    private var localEventMonitor: Any?
    private var globalModifierMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var localMagnifyMonitor: Any?
    private var globalMagnifyMonitor: Any?
    private weak var switcherScrollView: NSScrollView?
    private var cycleObserver: NSObjectProtocol?
    private var forwardSignalSource: DispatchSourceSignal?
    private var reverseSignalSource: DispatchSourceSignal?
    private var windowControlSignalSource: DispatchSourceSignal?
    private var commandTabEventTap: CFMachPort?
    private var commandTabRunLoopSource: CFRunLoopSource?
    private var commandTabRetryTimer: Timer?
    private var permissionGuide: PermissionGuideWindowController?
    private var didPresentPermissionGuide = false
    private var permissionGuideCompletion: DispatchWorkItem?
    private var targetScreen: NSScreen?
    private var iconCache: [String: NSImage] = [:]
    private var dockBadgeSnapshot = DockBadgeSnapshot.empty
    private var audioActivitySnapshot = AudioActivitySnapshot.empty
    private var allWindows: [AeroWindow] = []
    private var windowlessApps: [RunningApp] = []
    private var orderedItems: [SwitcherItem] = []
    private var itemRows: [String: ActionRow] = [:]
    private var selectedIndex: Int?
    private var hoveredItemKey: String?
    private var focusedWindowID: Int?
    private var focusedApplicationPID: pid_t?
    private var pendingCycleDelta = 0
    private var pendingDirectSelectionIndex: Int?
    private var commitWhenLoaded = false
    private var trackedReleaseModifier: NSEvent.ModifierFlags?
    private var launchDirection = 1
    private var singletonLockFileDescriptor: Int32 = -1
    private var isLoaded = false
    private var isRefreshing = false
    private var loadGeneration = 0
    private var windowControlPanelController: WindowControlPanelController?
    private let windowControlQueue = DispatchQueue(
        label: "io.github.tovifun.aerospace-companion.window-control",
        qos: .userInteractive
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let invokedByShortcut = CommandLine.arguments.contains("--forward")
            || CommandLine.arguments.contains("--reverse")
        launchDirection = CommandLine.arguments.contains("--reverse") ? -1 : 1
        trackedReleaseModifier = NSEvent.modifierFlags.contains(.option) ? .option : nil
        commitWhenLoaded = invokedByShortcut && trackedReleaseModifier == nil
        focusedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSApp.setActivationPolicy(.accessory)

        ensureRuntimeDirectory()
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
        startCommandTabInterception()
        prepareWindowControlPanel()
        writeDaemonPID()
        cycleObserver = DistributedNotificationCenter.default().addObserver(
            forName: cycleNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let direction = notification.userInfo?["direction"] as? Int ?? 1
            self?.handleCycleRequest(direction: direction)
        }

        let presentedPermissionGuide = presentPermissionGuideIfNeeded()
        if CommandLine.arguments.contains("--daemon") {
            // AeroSpace may not have created its socket yet during login or installation.
            // Keep the daemon responsive so the first shortcut can retry the load.
            loadWindows(presentErrors: false)
            return
        }
        if presentedPermissionGuide && !invokedByShortcut {
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
        stopCommandTabInterception()
        permissionGuideCompletion?.cancel()
        if let cycleObserver {
            DistributedNotificationCenter.default().removeObserver(cycleObserver)
        }
        forwardSignalSource?.cancel()
        reverseSignalSource?.cancel()
        windowControlSignalSource?.cancel()
        windowControlPanelController?.hide(deactivateApplication: false)
        if singletonLockFileDescriptor >= 0 {
            unlink(daemonPIDPath)
            flock(singletonLockFileDescriptor, LOCK_UN)
            close(singletonLockFileDescriptor)
        }
    }

    private func loadWindows(
        presentErrors: Bool = true,
        preserveSelection: Bool = false,
        fallbackSelectionIndex: Int? = nil
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshing = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                let focusedWindowID = AeroSpaceClient.focusedWindowID()
                let windows = try AeroSpaceClient.allWindows()
                let dockBadgeSnapshot = DockBadgeClient.currentSnapshot()
                let audioActivitySnapshot = AudioActivityClient.currentSnapshot()
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    let previousSelectionKey = preserveSelection
                        ? self.selectedItem?.key
                        : nil
                    self.focusedWindowID = focusedWindowID
                    self.dockBadgeSnapshot = dockBadgeSnapshot
                    self.audioActivitySnapshot = audioActivitySnapshot
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
                    self.updateWindowControlPanelIfVisible()
                    guard !self.orderedItems.isEmpty else {
                        if presentErrors {
                            self.showError("No windows or applications are currently available.")
                        }
                        return
                    }
                    self.refreshContent()
                    let pendingDirectSelectionIndex = self.pendingDirectSelectionIndex
                    self.pendingDirectSelectionIndex = nil
                    if let pendingDirectSelectionIndex,
                       self.orderedItems.indices.contains(pendingDirectSelectionIndex) {
                        self.pendingCycleDelta = 0
                        self.setSelectedIndex(pendingDirectSelectionIndex)
                    } else if preserveSelection {
                        let preservedIndex = previousSelectionKey.flatMap { key in
                            self.orderedItems.firstIndex { $0.key == key }
                        } ?? fallbackSelectionIndex ?? 0
                        let pendingDelta = self.pendingCycleDelta
                        self.pendingCycleDelta = 0
                        self.setSelectedIndex(preservedIndex + pendingDelta)
                    } else {
                        self.prepareInitialSelection()
                    }
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

    private func handleCycleRequest(
        direction: Int,
        tracking modifier: NSEvent.ModifierFlags = .option,
        modifierIsPressed: Bool? = nil
    ) {
        let isPressed = modifierIsPressed ?? NSEvent.modifierFlags.contains(modifier)
        trackedReleaseModifier = isPressed ? modifier : nil
        if isPressed {
            commitWhenLoaded = false
        }

        if panel?.isVisible == true {
            if isRefreshing {
                pendingCycleDelta += direction
                return
            }
            moveSelection(by: direction)
            return
        }

        launchDirection = direction
        commitWhenLoaded = !isPressed
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
            } else if self?.handleCommandSelectionShortcut(event) == true {
                return nil
            } else if event.keyCode == 53 {
                self?.trackedReleaseModifier = nil
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
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) {
            [weak self] event in
            guard
                let self,
                let panel = self.panel,
                event.window === panel,
                let contentView = panel.contentView
            else {
                return event
            }

            let contentFrame = contentView.bounds.insetBy(
                dx: SwitcherStyle.shadowMargin,
                dy: SwitcherStyle.shadowMargin
            )
            guard !contentFrame.contains(event.locationInWindow) else {
                return event
            }

            self.dismiss()
            return nil
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) {
            [weak self] _ in
            DispatchQueue.main.async {
                guard
                    let self,
                    let panel = self.panel,
                    panel.isVisible,
                    !panel.frame.contains(NSEvent.mouseLocation)
                else {
                    return
                }
                self.dismiss()
            }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard
                let self,
                let panel = self.panel,
                panel.isVisible,
                event.window === panel,
                let scrollView = self.switcherScrollView
            else {
                return event
            }

            // Deliver the wheel event directly. The borderless switcher panel can
            // otherwise leave it on a child row instead of reaching NSScrollView.
            scrollView.scrollWheel(with: event)
            return nil
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard
                    let self,
                    let panel = self.panel,
                    panel.isVisible,
                    panel.frame.contains(mouseLocation),
                    let scrollView = self.switcherScrollView
                else {
                    return
                }

                // Command-Tab is intercepted before the system app switcher runs.
                // While Command remains held, macOS can still route wheel events to
                // the previously active app, so the local monitor above never sees
                // them. Forward those global events only while the pointer is over
                // our panel.
                scrollView.scrollWheel(with: event)
            }
        }
        localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            guard
                let self,
                self.trackedReleaseModifier == .command,
                let panel = self.panel,
                panel.isVisible,
                event.window === panel
            else {
                return event
            }

            // Mac Mouse Fix maps Command + physical mouse-wheel input to
            // magnification gestures instead of scroll-wheel events. Convert its
            // gesture back to scrolling while our Command-Tab panel is active.
            self.scrollSwitcher(byMagnification: event.magnification)
            return nil
        }
        globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard
                    let self,
                    self.trackedReleaseModifier == .command,
                    let panel = self.panel,
                    panel.isVisible,
                    panel.frame.contains(mouseLocation)
                else {
                    return
                }

                self.scrollSwitcher(byMagnification: event.magnification)
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

    private func scrollSwitcher(byMagnification magnification: CGFloat) {
        guard
            magnification != 0,
            let scrollView = switcherScrollView,
            let documentView = scrollView.documentView
        else {
            return
        }

        let clipView = scrollView.contentView
        let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
        let currentOrigin = clipView.bounds.origin
        let targetY = min(
            maximumY,
            max(0, currentOrigin.y - magnification * 800)
        )
        guard targetY != currentOrigin.y else { return }

        clipView.scroll(to: NSPoint(x: currentOrigin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func makeContentView(for screen: NSScreen) -> NSView {
        hoveredItemKey = nil
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

        let scrollView = OverflowFadingScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .automatic
        switcherScrollView = scrollView

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
        let maximumHeight = min(
            SwitcherStyle.maximumPanelHeight,
            max(176, visibleFrame.height - SwitcherStyle.panelScreenInset * 2)
        )
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
        stack.addArrangedSubview(makeGroupHeader(
            title: workspaceHeaderTitle(group.workspace),
            metadata: workspaceHeaderMetadata(group)
        ))

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
        let appCount = windowlessApps.count
        stack.addArrangedSubview(makeGroupHeader(
            title: localized("OTHER APPS", "其他 APP"),
            metadata: localized(
                appCount == 1 ? "1 APP" : "\(appCount) APPS",
                "\(appCount) 个"
            )
        ))

        for app in windowlessApps {
            let row = makeApplicationRow(app)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeGroupHeader(title: String, metadata: String?) -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = textLabel(
            title,
            size: 10,
            weight: .semibold,
            color: .tertiaryLabelColor
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(titleLabel)

        var constraints = [
            header.heightAnchor.constraint(equalToConstant: SwitcherStyle.groupHeaderHeight),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ]
        if let metadata, !metadata.isEmpty {
            let metadataLabel = textLabel(
                metadata,
                size: 9,
                weight: .medium,
                color: .tertiaryLabelColor
            )
            metadataLabel.lineBreakMode = .byTruncatingMiddle
            metadataLabel.maximumNumberOfLines = 1
            metadataLabel.alignment = .right
            metadataLabel.toolTip = metadata
            header.addSubview(metadataLabel)
            constraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: metadataLabel.leadingAnchor,
                    constant: -10
                ),
                metadataLabel.trailingAnchor.constraint(
                    equalTo: header.trailingAnchor,
                    constant: -10
                ),
                metadataLabel.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            ])
        } else {
            constraints.append(
                titleLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: header.trailingAnchor,
                    constant: -10
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
        return header
    }

    private func workspaceHeaderTitle(_ workspace: String) -> String {
        let role: String?
        switch workspace {
        case "1": role = localized("MEDIA & CALLS", "媒体会议")
        case "2": role = localized("BROWSING & REFERENCE", "浏览资料")
        case "3": role = localized("TEMPORARY & PREVIEW", "临时预览")
        case "4": role = localized("CODE & EDITORS", "Codex 与编辑器")
        case "5": role = localized("TERMINALS & AGENTS", "终端与 Agent")
        case "6": role = localized("GIT, DATA & API", "Git、数据库与 API")
        case "7": role = localized("DESIGN & CONTENT", "设计与内容")
        case "8": role = localized("COMMUNICATION", "沟通")
        case "9": role = localized("AI & RESEARCH", "AI 研究")
        case "10": role = localized("AMBIENT", "氛围空屏")
        default: role = nil
        }
        return role.map { "\(workspace) · \($0)" }
            ?? localized("WORKSPACE \(workspace)", "WORKSPACE \(workspace)")
    }

    private func workspaceHeaderMetadata(_ group: WorkspaceGroup) -> String {
        let monitorName = group.monitorName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [
            monitorName.isEmpty
                ? localized("DISPLAY \(group.monitorID)", "显示器 \(group.monitorID)")
                : monitorName,
        ]
        if group.isFocused {
            parts.append(localized("CURRENT", "当前"))
        } else if group.isVisible {
            parts.append(localized("VISIBLE", "可见"))
        }
        let count = group.windows.count
        parts.append(localized(
            count == 1 ? "1 WINDOW" : "\(count) WINDOWS",
            "\(count) 个"
        ))
        return parts.joined(separator: " · ")
    }

    private func makeWindowRow(_ window: AeroWindow) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let fallbackTitle = window.windowTitle.isEmpty ? "Untitled Window" : window.windowTitle
        let item = SwitcherItem.window(window)
        let shortcutNumber = commandSelectionShortcutNumber(for: item)
        let isCurrentWindow = window.windowID == focusedWindowID
        row.setAccessibilityLabel(rowAccessibilityLabel(
            appName: window.appName,
            title: fallbackTitle,
            bundleIdentifier: window.appBundleID,
            processIdentifier: window.appPID,
            window: window,
            isCurrent: isCurrentWindow,
            shortcutNumber: shortcutNumber
        ))
        row.onClick = { [weak self] in self?.select(item) }
        row.onHoverChanged = { [weak self] isHovered in
            self?.updateHoveredItem(item.key, isHovered: isHovered)
        }

        let icon = appIconView(image: appIcon(bundleID: window.appBundleID))
        let status = rowStatusView(
            bundleIdentifier: window.appBundleID,
            appName: window.appName,
            processIdentifier: window.appPID,
            window: window,
            isCurrent: isCurrentWindow,
            commandShortcutNumber: shortcutNumber
        )

        let windowTitle = textLabel(
            fallbackTitle,
            size: 15,
            weight: .medium,
            color: .labelColor
        )
        windowTitle.lineBreakMode = .byTruncatingTail
        windowTitle.maximumNumberOfLines = 1
        windowTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layoutRowContent(row: row, icon: icon, title: windowTitle, status: status)
        row.registerLabels(primary: windowTitle)
        itemRows[item.key] = row
        return row
    }

    private func makeApplicationRow(_ app: RunningApp) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let item = SwitcherItem.application(app)
        let shortcutNumber = commandSelectionShortcutNumber(for: item)
        let isCurrentApplication = app.processIdentifier == focusedApplicationPID
        row.setAccessibilityLabel(rowAccessibilityLabel(
            appName: app.appName,
            title: nil,
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            window: nil,
            isCurrent: isCurrentApplication,
            shortcutNumber: shortcutNumber
        ))
        row.onClick = { [weak self] in self?.select(item) }
        row.onHoverChanged = { [weak self] isHovered in
            self?.updateHoveredItem(item.key, isHovered: isHovered)
        }

        let icon = appIconView(image: appIcon(for: app))
        let status = rowStatusView(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            processIdentifier: app.processIdentifier,
            window: nil,
            isCurrent: isCurrentApplication,
            commandShortcutNumber: shortcutNumber
        )

        let appName = textLabel(
            app.appName,
            size: 15,
            weight: .medium,
            color: .labelColor
        )
        appName.lineBreakMode = .byTruncatingTail
        appName.maximumNumberOfLines = 1
        appName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layoutRowContent(row: row, icon: icon, title: appName, status: status)
        row.registerLabels(primary: appName)
        itemRows[item.key] = row
        return row
    }

    private func commandSelectionShortcutNumber(for item: SwitcherItem) -> Int? {
        guard
            trackedReleaseModifier == .command,
            let index = orderedItems.firstIndex(where: { $0.key == item.key }),
            index < 9
        else {
            return nil
        }
        return index + 1
    }

    private func rowAccessibilityLabel(
        appName: String,
        title: String?,
        bundleIdentifier: String,
        processIdentifier: pid_t,
        window: AeroWindow?,
        isCurrent: Bool,
        shortcutNumber: Int?
    ) -> String {
        var parts = [appName]
        if let title, !title.isEmpty {
            parts.append(title)
        }
        if isCurrent {
            parts.append(localized("Currently focused", "当前正在使用"))
        }
        if window?.isFullscreen == true {
            parts.append(localized("Fullscreen", "全屏"))
        } else if window?.windowLayout == "floating" {
            parts.append(localized("Floating", "浮动"))
        }
        if NSRunningApplication(processIdentifier: processIdentifier)?.isHidden == true {
            parts.append(localized("Hidden", "已隐藏"))
        }
        if audioActivitySnapshot.isInputActive(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        ) {
            parts.append(localized("Using microphone", "正在使用麦克风"))
        }
        if audioActivitySnapshot.isOutputActive(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        ) {
            parts.append(localized("Playing audio", "正在播放声音"))
        }
        if let badgeStatus = dockBadgeSnapshot.status(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        ) {
            parts.append(localized(
                "Notification badge \(badgeStatus.rawLabel)",
                "通知 \(badgeStatus.rawLabel)"
            ))
        }
        if let shortcutNumber {
            parts.append(localized(
                "Command-\(shortcutNumber) selects this item",
                "Command-\(shortcutNumber) 选择此项"
            ))
        }
        return parts.joined(separator: ", ")
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
        return names.compactMap { workspace in
            guard
                let windows = grouped[workspace],
                let firstWindow = windows.first
            else {
                return nil
            }
            return WorkspaceGroup(
                workspace: workspace,
                isFocused: windows.contains(where: \.workspaceIsFocused),
                isVisible: windows.contains(where: \.workspaceIsVisible),
                monitorID: firstWindow.monitorID,
                monitorName: firstWindow.monitorName,
                windows: windows
            )
        }
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
        guard
            let trackedReleaseModifier,
            !flags.contains(trackedReleaseModifier)
        else {
            return
        }
        self.trackedReleaseModifier = nil

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

    private var selectedItem: SwitcherItem? {
        guard
            let selectedIndex,
            orderedItems.indices.contains(selectedIndex)
        else {
            return nil
        }
        return orderedItems[selectedIndex]
    }

    private func updateHoveredItem(_ key: String, isHovered: Bool) {
        if isHovered {
            hoveredItemKey = key
        } else if hoveredItemKey == key {
            hoveredItemKey = nil
        }
    }

    private var commandActionTarget: (index: Int, item: SwitcherItem)? {
        if
            SwitcherConfiguration.hoveredItemActionPriority,
            let hoveredItemKey,
            let hoveredIndex = orderedItems.firstIndex(where: { $0.key == hoveredItemKey })
        {
            return (hoveredIndex, orderedItems[hoveredIndex])
        }

        guard
            let selectedIndex,
            orderedItems.indices.contains(selectedIndex)
        else {
            return nil
        }
        return (selectedIndex, orderedItems[selectedIndex])
    }

    private func handleCommandSelectionShortcut(_ event: NSEvent) -> Bool {
        guard
            event.type == .keyDown,
            trackedReleaseModifier == .command,
            event.modifierFlags.contains(.command),
            event.modifierFlags.intersection([.option, .control, .shift]).isEmpty
        else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_W:
            if !event.isARepeat {
                closeSelectedWindow()
            }
            return true
        case kVK_ANSI_Q:
            if !event.isARepeat {
                quitSelectedApplication()
            }
            return true
        case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
             kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
             kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9:
            guard !event.isARepeat,
                  let index = commandSelectionIndex(for: Int(event.keyCode))
            else {
                return true
            }
            if isRefreshing {
                pendingDirectSelectionIndex = index
            } else if orderedItems.indices.contains(index) {
                setSelectedIndex(index)
            } else {
                NSSound.beep()
            }
            return true
        default:
            return false
        }
    }

    private func commandSelectionIndex(for keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default: return nil
        }
    }

    private func closeSelectedWindow() {
        guard
            let target = commandActionTarget,
            case .window(let window) = target.item
        else {
            NSSound.beep()
            return
        }
        let preferredSelectionKey = selectedItem?.key
        let fallbackSelectionIndex = selectedIndex ?? target.index

        allWindows.removeAll { $0.windowID == window.windowID }
        rebuildItemsAfterSelectionAction(
            removingApplicationPID: nil,
            preferredSelectionKey: preferredSelectionKey,
            fallbackSelectionIndex: fallbackSelectionIndex
        )
        AeroSpaceClient.close(windowID: window.windowID) { [weak self] error in
            guard let self else { return }
            if let error {
                self.showTransientActionError(error.localizedDescription)
            }
            self.loadWindows(
                presentErrors: false,
                preserveSelection: true,
                fallbackSelectionIndex: fallbackSelectionIndex
            )
        }
    }

    private func quitSelectedApplication() {
        guard let target = commandActionTarget else {
            return
        }
        let preferredSelectionKey = selectedItem?.key
        let fallbackSelectionIndex = selectedIndex ?? target.index

        let processIdentifier: pid_t
        switch target.item {
        case .window(let window):
            processIdentifier = window.appPID
        case .application(let app):
            processIdentifier = app.processIdentifier
        }
        guard
            processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let runningApplication = NSRunningApplication(
                processIdentifier: processIdentifier
            )
        else {
            NSSound.beep()
            return
        }

        guard runningApplication.terminate() else {
            NSSound.beep()
            return
        }
        allWindows.removeAll { $0.appPID == processIdentifier }
        rebuildItemsAfterSelectionAction(
            removingApplicationPID: processIdentifier,
            preferredSelectionKey: preferredSelectionKey,
            fallbackSelectionIndex: fallbackSelectionIndex
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.loadWindows(
                presentErrors: false,
                preserveSelection: true,
                fallbackSelectionIndex: fallbackSelectionIndex
            )
        }
    }

    private func rebuildItemsAfterSelectionAction(
        removingApplicationPID: pid_t?,
        preferredSelectionKey: String?,
        fallbackSelectionIndex: Int
    ) {
        windowlessApps = runningAppsWithoutWindows(excluding: allWindows).filter {
            $0.processIdentifier != removingApplicationPID
        }
        orderedItems = workspaceGroups()
            .flatMap(\.windows)
            .map(SwitcherItem.window)
            + windowlessApps.map(SwitcherItem.application)

        guard !orderedItems.isEmpty else {
            dismiss()
            return
        }
        refreshContent()
        let nextSelectionIndex = preferredSelectionKey.flatMap { key in
            orderedItems.firstIndex { $0.key == key }
        } ?? min(fallbackSelectionIndex, orderedItems.count - 1)
        setSelectedIndex(nextSelectionIndex)
    }

    private func showTransientActionError(_ message: String) {
        NSSound.beep()
        NSLog("AeroSpace Window Switcher action failed: %@", message)
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
        trackedReleaseModifier = nil
        commitWhenLoaded = false
        pendingCycleDelta = 0
        pendingDirectSelectionIndex = nil
        selectedIndex = nil
        hoveredItemKey = nil
        isRefreshing = false
        loadGeneration += 1
        panel?.orderOut(nil)
        panel = nil
        targetScreen = nil
        switcherScrollView = nil
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
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        if let localMagnifyMonitor {
            NSEvent.removeMonitor(localMagnifyMonitor)
            self.localMagnifyMonitor = nil
        }
        if let globalMagnifyMonitor {
            NSEvent.removeMonitor(globalMagnifyMonitor)
            self.globalMagnifyMonitor = nil
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

    private func layoutRowContent(
        row: ActionRow,
        icon: NSView,
        title: NSTextField,
        status: NSView?
    ) {
        row.addSubview(icon)
        row.addSubview(title)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: SwitcherStyle.rowHeight),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ]
        if let status {
            row.addSubview(status)
            constraints.append(contentsOf: [
                title.trailingAnchor.constraint(
                    lessThanOrEqualTo: status.leadingAnchor,
                    constant: -10
                ),
                status.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -11),
                status.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        } else {
            constraints.append(
                title.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12)
            )
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func appIconView(image: NSImage) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: image)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor),
            icon.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func rowStatusView(
        bundleIdentifier: String,
        appName: String,
        processIdentifier: pid_t,
        window: AeroWindow?,
        isCurrent: Bool,
        commandShortcutNumber: Int?
    ) -> NSView? {
        let badgeStatus = dockBadgeSnapshot.status(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
        let isUsingMicrophone = audioActivitySnapshot.isInputActive(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let isPlayingAudio = audioActivitySnapshot.isOutputActive(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let isHidden = NSRunningApplication(
            processIdentifier: processIdentifier
        )?.isHidden == true
        let windowState: String?
        if window?.isFullscreen == true {
            windowState = localized("FULLSCREEN", "全屏")
        } else if window?.windowLayout == "floating" {
            windowState = localized("FLOATING", "浮动")
        } else {
            windowState = nil
        }
        guard
            badgeStatus != nil
                || isUsingMicrophone
                || isPlayingAudio
                || isCurrent
                || isHidden
                || windowState != nil
                || commandShortcutNumber != nil
        else {
            return nil
        }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)

        if isCurrent {
            stack.addArrangedSubview(makeStatePill(
                localized("CURRENT", "当前"),
                toolTip: localized("Currently focused", "当前正在使用")
            ))
        }

        if let windowState {
            stack.addArrangedSubview(makeStatePill(windowState, toolTip: windowState))
        }

        if isHidden {
            let hidden = localized("HIDDEN", "隐藏")
            stack.addArrangedSubview(makeStatePill(
                hidden,
                toolTip: localized("Application is hidden", "App 当前已隐藏")
            ))
        }

        if isUsingMicrophone {
            stack.addArrangedSubview(makeStatusIcon(
                systemSymbolName: "mic.fill",
                description: localized("Using microphone", "正在使用麦克风"),
                color: .systemOrange
            ))
        }

        if isPlayingAudio {
            stack.addArrangedSubview(makeStatusIcon(
                systemSymbolName: "speaker.wave.2.fill",
                description: localized("Playing audio", "正在播放声音"),
                color: .secondaryLabelColor
            ))
        }

        if let badgeStatus {
            stack.addArrangedSubview(makeBadgeView(badgeStatus))
        }

        if let commandShortcutNumber {
            stack.addArrangedSubview(makeShortcutKeycap(commandShortcutNumber))
        }

        return stack
    }

    private func makeStatusIcon(
        systemSymbolName: String,
        description: String,
        color: NSColor
    ) -> NSView {
        let symbol = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: description
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        let icon = NSImageView(image: symbol ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = color
        icon.imageScaling = .scaleProportionallyDown
        icon.toolTip = description
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        return icon
    }

    private func makeStatePill(_ text: String, toolTip: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        pill.layer?.cornerRadius = 7.5
        pill.toolTip = toolTip

        let label = textLabel(
            text,
            size: 9,
            weight: .semibold,
            color: .tertiaryLabelColor
        )
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor, constant: -0.25),
        ])
        return pill
    }

    private func makeShortcutKeycap(_ number: Int) -> NSView {
        let keycap = NSView()
        keycap.translatesAutoresizingMaskIntoConstraints = false
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 4
        keycap.layer?.borderWidth = 0.5
        keycap.layer?.borderColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.38).cgColor
        keycap.toolTip = localized(
            "Press Command-\(number) to select",
            "按 Command-\(number) 直接选择"
        )

        let label = textLabel(
            "⌘\(number)",
            size: 9,
            weight: .medium,
            color: .tertiaryLabelColor
        )
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        keycap.addSubview(label)
        NSLayoutConstraint.activate([
            keycap.heightAnchor.constraint(equalToConstant: 17),
            keycap.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            label.leadingAnchor.constraint(equalTo: keycap.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: keycap.centerYAnchor, constant: -0.25),
        ])
        return keycap
    }

    private func makeBadgeView(_ status: DockBadgeStatus) -> NSView {
        guard let displayCount = status.displayCount else {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = 4
            dot.toolTip = status.rawLabel
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            return dot
        }

        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 8.5
        badge.toolTip = status.rawLabel

        let countLabel = textLabel(
            displayCount,
            size: 10,
            weight: .semibold,
            color: .white
        )
        countLabel.alignment = .center
        badge.addSubview(countLabel)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 17),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17),
            countLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            countLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: -0.25),
        ])
        return badge
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
        signal(SIGURG, SIG_IGN)

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

        let promptSource = DispatchSource.makeSignalSource(signal: SIGURG, queue: .main)
        promptSource.setEventHandler { [weak self] in
            self?.showWindowControlPanel()
        }
        promptSource.resume()
        windowControlSignalSource = promptSource
    }

    private func prepareWindowControlPanel() {
        let controller = WindowControlPanelController()
        controller.onCommand = { [weak self] request in
            self?.performWindowControl(request)
        }
        windowControlPanelController = controller
    }

    private func showWindowControlPanel() {
        if panel?.isVisible == true {
            dismiss()
        }
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens[0]
        windowControlPanelController?.update(
            windows: allWindows,
            focusedWindowID: focusedWindowID
        )
        windowControlPanelController?.show(on: screen)
        loadWindows(presentErrors: false)
    }

    private func updateWindowControlPanelIfVisible() {
        guard windowControlPanelController?.isVisible == true else { return }
        windowControlPanelController?.update(
            windows: allWindows,
            focusedWindowID: focusedWindowID
        )
    }

    private func performWindowControl(_ request: WindowControlRequest) {
        windowControlQueue.async { [weak self] in
            do {
                try AeroSpaceClient.perform(request)
                DispatchQueue.main.async {
                    self?.loadWindows(presentErrors: false)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showTransientActionError(error.localizedDescription)
                }
            }
        }
    }

    private func startCommandTabInterception() {
        guard commandTabEventTap == nil else { return }

        let isTrusted = AXIsProcessTrusted()
        let hasListenAccess = CGPreflightListenEventAccess()

        guard isTrusted, hasListenAccess else {
            writeCommandTabStatus(
                accessibilityTrusted: isTrusted,
                listenAccess: hasListenAccess,
                eventTapCreated: false
            )
            updatePermissionGuide(
                accessibilityTrusted: isTrusted,
                listenAccess: hasListenAccess,
                eventTapCreated: false
            )
            scheduleCommandTabInterceptionRetry()
            return
        }

        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.commandTabEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            writeCommandTabStatus(
                accessibilityTrusted: true,
                listenAccess: hasListenAccess,
                eventTapCreated: false
            )
            updatePermissionGuide(
                accessibilityTrusted: true,
                listenAccess: hasListenAccess,
                eventTapCreated: false
            )
            scheduleCommandTabInterceptionRetry()
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )
        commandTabEventTap = eventTap
        commandTabRunLoopSource = runLoopSource
        commandTabRetryTimer?.invalidate()
        commandTabRetryTimer = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        writeCommandTabStatus(
            accessibilityTrusted: true,
            listenAccess: hasListenAccess,
            eventTapCreated: true
        )
        updatePermissionGuide(
            accessibilityTrusted: true,
            listenAccess: hasListenAccess,
            eventTapCreated: true
        )
    }

    private func scheduleCommandTabInterceptionRetry() {
        guard commandTabRetryTimer == nil else { return }
        commandTabRetryTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            self?.startCommandTabInterception()
        }
    }

    @discardableResult
    private func presentPermissionGuideIfNeeded() -> Bool {
        let accessibilityTrusted = AXIsProcessTrusted()
        let listenAccess = CGPreflightListenEventAccess()
        guard !accessibilityTrusted || !listenAccess else { return false }
        guard !didPresentPermissionGuide else { return true }
        didPresentPermissionGuide = true

        let guide = PermissionGuideWindowController()
        guide.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }
        guide.onRequestInputMonitoring = { [weak self] in
            self?.requestInputMonitoringPermission()
        }
        guide.onRevealApplication = {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        guide.onRestartApplication = { [weak self] in
            self?.restartAsDaemon()
        }
        permissionGuide = guide
        guide.update(
            accessibilityTrusted: accessibilityTrusted,
            listenAccess: listenAccess,
            eventTapCreated: commandTabEventTap != nil
        )
        guide.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func updatePermissionGuide(
        accessibilityTrusted: Bool,
        listenAccess: Bool,
        eventTapCreated: Bool
    ) {
        guard let permissionGuide else { return }
        permissionGuide.update(
            accessibilityTrusted: accessibilityTrusted,
            listenAccess: listenAccess,
            eventTapCreated: eventTapCreated
        )
        guard eventTapCreated else {
            permissionGuideCompletion?.cancel()
            permissionGuideCompletion = nil
            return
        }

        let completion = DispatchWorkItem { [weak self, weak permissionGuide] in
            permissionGuide?.close()
            self?.permissionGuideCompletion = nil
        }
        permissionGuideCompletion?.cancel()
        permissionGuideCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: completion)
    }

    private func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openPrivacySettings(pane: "Privacy_Accessibility")
    }

    private func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openPrivacySettings(pane: "Privacy_ListenEvent")
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func restartAsDaemon() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "sleep 0.6; exec /usr/bin/open -gj \"$1\" --args --daemon",
            "aerospace-companion-relaunch",
            Bundle.main.bundlePath,
        ]
        relaunch.standardOutput = FileHandle.nullDevice
        relaunch.standardError = FileHandle.nullDevice
        do {
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            showError(localized(
                "Unable to restart the switcher: \(error.localizedDescription)",
                "无法重新启动切换器：\(error.localizedDescription)"
            ))
        }
    }

    private func stopCommandTabInterception() {
        commandTabRetryTimer?.invalidate()
        commandTabRetryTimer = nil
        if let commandTabRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                commandTabRunLoopSource,
                .commonModes
            )
            self.commandTabRunLoopSource = nil
        }
        if let commandTabEventTap {
            CFMachPortInvalidate(commandTabEventTap)
            self.commandTabEventTap = nil
        }
    }

    private func handleCommandTabEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let commandTabEventTap {
                CGEvent.tapEnable(tap: commandTabEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            guard
                let panel,
                panel.isVisible,
                panel.frame.contains(NSEvent.mouseLocation),
                let scrollView = switcherScrollView,
                let scrollEventCopy = event.copy()
            else {
                return Unmanaged.passUnretained(event)
            }

            // A physical mouse can emit discrete wheel events that never reach
            // NSEvent monitors while Command is held. Handle them at the same
            // session event tap that owns Command-Tab, before that routing occurs.
            // Remove Command from the forwarded copy so NSScrollView treats a
            // discrete mouse-wheel tick as scrolling instead of a modified gesture.
            scrollEventCopy.flags = scrollEventCopy.flags.subtracting(.maskCommand)
            guard let scrollEvent = NSEvent(cgEvent: scrollEventCopy) else {
                return Unmanaged.passUnretained(event)
            }
            scrollView.scrollWheel(with: scrollEvent)
            return nil
        }

        guard
            isAeroSpaceRunning(),
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab)
        else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        guard
            flags.contains(.maskCommand),
            !flags.contains(.maskAlternate),
            !flags.contains(.maskControl)
        else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let direction = flags.contains(.maskShift) ? -1 : 1
            DispatchQueue.main.async { [weak self] in
                self?.handleCycleRequest(
                    direction: direction,
                    tracking: .command,
                    modifierIsPressed: true
                )
            }
        }
        return nil
    }

    private func isAeroSpaceRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == "bobko.aerospace"
                || application.localizedName == "AeroSpace"
                || application.bundleURL?.lastPathComponent == "AeroSpace.app"
        }
    }

    private func writeCommandTabStatus(
        accessibilityTrusted: Bool,
        listenAccess: Bool,
        eventTapCreated: Bool
    ) {
        ensureRuntimeDirectory()
        let status = "accessibility_trusted=\(accessibilityTrusted)\n"
            + "listen_access=\(listenAccess)\n"
            + "event_tap_created=\(eventTapCreated)\n"
        try? status.write(
            toFile: commandTabStatusPath,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeDaemonPID() {
        ensureRuntimeDirectory()
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: daemonPIDPath,
            atomically: true,
            encoding: .utf8
        )
    }

    private func ensureRuntimeDirectory() {
        try? FileManager.default.createDirectory(
            atPath: runtimeRootPath,
            withIntermediateDirectories: true,
            attributes: nil
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
