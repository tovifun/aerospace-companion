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
private let settingsNotificationName = Notification.Name("\(runtimeIdentifier).settings")
private let searchNotificationName = Notification.Name("\(runtimeIdentifier).search")
private let singletonLockPath = "\(runtimePathPrefix).lock"
private let daemonPIDPath = "\(runtimePathPrefix).pid"
private let commandTabStatusPath = "\(runtimePathPrefix).command-tab-status"

private enum SwitcherConfiguration {
    static let hoveredItemActionPriorityKey = "hoveredItemActionPriority"

    static func workspaceLabel(_ workspace: String) -> String? {
        let labels = UserDefaults.standard.dictionary(forKey: "workspaceLabels")
        guard let label = labels?[workspace] as? String else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var hoveredItemActionPriority: Bool {
        UserDefaults.standard.bool(forKey: hoveredItemActionPriorityKey)
    }
}

private enum SwitcherStyle {
    static var metrics: SwitcherLayoutMetrics { SwitcherPreferences.shared.layoutMode.metrics }
    static let maximumPanelHeight: CGFloat = 960
    static let panelScreenInset: CGFloat = 16
    static let surfaceCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 8
    static let shadowMargin: CGFloat = 24
    static let contentPadding: CGFloat = 8
    static var groupSpacing: CGFloat { metrics.groupSpacing }
    static var groupHeaderHeight: CGFloat { metrics.groupHeaderHeight }
    static var rowSpacing: CGFloat { metrics.rowSpacing }
    static var rowHeight: CGFloat { metrics.rowHeight }
    static var emptyWorkspaceRowHeight: CGFloat { metrics.emptyWorkspaceRowHeight }
    static var iconSize: CGFloat { metrics.iconSize }
    static let accentColor = NSColor(
        srgbRed: 0.20,
        green: 0.43,
        blue: 0.96,
        alpha: 1
    )
}

private struct AeroWindow: Decodable, Equatable {
    let windowID: Int
    let appName: String
    let appBundleID: String
    let appPID: pid_t
    let workspace: String
    let windowTitle: String
    let isFullscreen: Bool
    let windowLayout: String
    let workspaceLayout: String?
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
        case workspaceLayout = "workspace-root-container-layout"
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
    let layout: String?
    var windows: [AeroWindow]
}

private struct RunningApp: Equatable {
    let processIdentifier: pid_t
    let appName: String
    let bundleIdentifier: String
}

private struct DockBadgeStatus: Equatable {
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

private struct DockBadgeSnapshot: Equatable {
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

private struct AudioActivitySnapshot: Equatable {
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
    case workspace(WorkspaceGroup)

    var key: String {
        switch self {
        case .window(let window):
            return "window:\(window.windowID)"
        case .application(let app):
            return "application:\(app.processIdentifier)"
        case .workspace(let group):
            return "workspace:\(group.workspace)"
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

    static func allWindows(validatingReopenedPIDs: Set<pid_t> = []) throws -> [AeroWindow] {
        let format = [
            "%{window-id}",
            "%{app-name}",
            "%{app-bundle-id}",
            "%{app-pid}",
            "%{workspace}",
            "%{window-title}",
            "%{window-is-fullscreen}",
            "%{window-layout}",
            "%{workspace-root-container-layout}",
            "%{workspace-is-focused}",
            "%{workspace-is-visible}",
            "%{monitor-id}",
            "%{monitor-name}",
        ].joined(separator: " ")
        let data = try run(["list-windows", "--all", "--json", "--format", format])
        let windows = try JSONDecoder().decode([AeroWindow].self, from: data)
        return excludingStaleUntitledWindows(windows, additionallyValidating: validatingReopenedPIDs)
    }

    static func allWorkspaces() throws -> [AeroWorkspace] {
        let format = [
            "%{workspace}", "%{workspace-is-focused}", "%{workspace-is-visible}",
            "%{monitor-id}", "%{monitor-name}", "%{workspace-root-container-layout}",
        ].joined(separator: " ")
        return try JSONDecoder().decode(
            [AeroWorkspace].self,
            from: run(["list-workspaces", "--all", "--json", "--format", format])
        )
    }

    static func activateWorkspace(_ workspace: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                _ = try run(["workspace", "--", workspace])
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    static func activateSearchWindow(_ windowID: Int, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                // Resolve the workspace again: a result can move or close while
                // the user types. Never activate an unrelated stale workspace.
                guard let window = try allWindows().first(where: { $0.windowID == windowID }) else {
                    throw NSError(domain: runtimeIdentifier, code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Window is no longer available"])
                }
                _ = try run(["workspace", "--", window.workspace])
                _ = try run(["focus", "--window-id", String(windowID)])
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private static func excludingStaleUntitledWindows(
        _ windows: [AeroWindow], additionallyValidating processIdentifiers: Set<pid_t>
    ) -> [AeroWindow] {
        let hasUntitledWindows = windows.contains {
            $0.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasUntitledWindows || windows.contains(where: { processIdentifiers.contains($0.appPID) }) else { return windows }

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

        return matchingLiveWindows(windows, validating: processIdentifiers, liveWindowOwners: liveWindowOwners)
    }

    private static func matchingLiveWindows(
        _ windows: [AeroWindow], validating processIdentifiers: Set<pid_t>, liveWindowOwners: [Int: pid_t]
    ) -> [AeroWindow] {
        windows.filter { window in
            let isUntitled = window.windowTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let needsValidation = isUntitled || processIdentifiers.contains(window.appPID)
            return !needsValidation || liveWindowOwners[window.windowID] == window.appPID
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
        SwitcherConfiguration.workspaceLabel(workspace)
            ?? localized("Workspace", "工作区")
    }

    private func workspaceDisplayName(_ workspace: String) -> String {
        let title = localized("Workspace \(workspace)", "工作区 \(workspace)")
        return SwitcherConfiguration.workspaceLabel(workspace).map { title + " · " + $0 }
            ?? title
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
    var onHoverChanged: ((NSPoint) -> Void)?
    var normalColor = NSColor.clear {
        didSet { updateAppearance() }
    }
    var isSelected = false {
        didSet { if isSelected != oldValue { updateAppearance() } }
    }

    var pendingMessage: String? {
        didSet { updateAppearance() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private weak var primaryLabel: NSTextField?
    private weak var secondaryLabel: NSTextField?
    private var primaryLabelColor: NSColor = .labelColor

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
        if let onHoverChanged {
            onHoverChanged(event.locationInWindow)
        } else {
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let onHoverChanged {
            onHoverChanged(event.locationInWindow)
        } else {
            setHovered(false)
        }
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
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

    func registerLabels(
        primary: NSTextField, secondary: NSTextField? = nil,
        primaryColor: NSColor = .labelColor
    ) {
        primaryLabel = primary
        secondaryLabel = secondary
        primaryLabelColor = primaryColor
        updateAppearance()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if isSelected {
                color = SwitcherStyle.accentColor.withAlphaComponent(0.18)
                primaryLabel?.textColor = primaryLabelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            } else if isHovered {
                color = NSColor.labelColor.withAlphaComponent(0.065)
                primaryLabel?.textColor = primaryLabelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            } else {
                color = normalColor
                primaryLabel?.textColor = primaryLabelColor
                secondaryLabel?.textColor = .secondaryLabelColor
            }
            layer?.backgroundColor = color.cgColor
            layer?.borderWidth = pendingMessage == nil ? 0 : 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            if pendingMessage != nil { primaryLabel?.textColor = .secondaryLabelColor }
            setAccessibilityValue([isSelected ? "Selected" : nil, pendingMessage].compactMap { $0 }.joined(separator: ", "))
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
    private var settingsObserver: NSObjectProtocol?
    private var searchObserver: NSObjectProtocol?
    private var applicationTerminationObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var forwardSignalSource: DispatchSourceSignal?
    private var reverseSignalSource: DispatchSourceSignal?
    private var windowControlSignalSource: DispatchSourceSignal?
    private var searchSignalSource: DispatchSourceSignal?
    private var windowSearchController: WindowSearchController?
    private var commandTabEventTap: CFMachPort?
    private var commandTabRunLoopSource: CFRunLoopSource?
    private var capturedSwitcherKeyCodes: Set<Int64> = []
    private var commandTabRetryTimer: Timer?
    private var permissionGuide: PermissionGuideWindowController?
    private var didPresentPermissionGuide = false
    private var permissionGuideCompletion: DispatchWorkItem?
    private var targetScreen: NSScreen?
    private var iconCache: [String: NSImage] = [:]
    private var dockBadgeSnapshot = DockBadgeSnapshot.empty
    private var audioActivitySnapshot = AudioActivitySnapshot.empty
    private var allWindows: [AeroWindow] = []
    private var allWorkspaces: [AeroWorkspace] = []
    private var allRunningApps: [RunningApp] = []
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
    private var isAwaitingPresentation = false
    private var isRefreshing = false
    private var isSnapshotLoading = false
    private var loadGeneration = 0
    private var actionTracker = SwitcherActionTracker()
    private var reopenTracker = SwitcherReopenTracker()
    private var reopenRefreshWorkItem: DispatchWorkItem?
    private var reopenPresentationDeadline: TimeInterval?
    private var actionRefreshWorkItem: DispatchWorkItem?
    private var actionFeedback: SwitcherActionFeedback?
    private var feedbackDismissWorkItem: DispatchWorkItem?
    private var latestFeedbackActionID: UUID?
    private var suppressedAutomaticActivationPID: pid_t?
    private weak var actionFeedbackView: SwitcherActionFeedbackView?
    private var keepsPanelFrame = false
    private var watchesActionChanges = false
    private var documentMinimumHeightConstraint: NSLayoutConstraint?
    private var requestWindowClose: (Int, @escaping (Error?) -> Void) -> Void = {
        AeroSpaceClient.close(windowID: $0, completion: $1)
    }
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
            if invokedByShortcut {
                DistributedNotificationCenter.default().postNotificationName(
                    cycleNotificationName, object: nil,
                    userInfo: ["direction": launchDirection], deliverImmediately: true
                )
            } else if CommandLine.arguments.contains("--search") {
                DistributedNotificationCenter.default().postNotificationName(
                    searchNotificationName, object: nil, deliverImmediately: true
                )
            } else if !CommandLine.arguments.contains("--daemon") {
                DistributedNotificationCenter.default().postNotificationName(
                    settingsNotificationName, object: nil, deliverImmediately: true
                )
            }
            NSApp.terminate(nil)
            return
        }

        prepareSettingsEntryPoints()
        applicationTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            guard self.allWindows.contains(where: { $0.appPID == pid })
                    || self.windowlessApps.contains(where: { $0.processIdentifier == pid })
                    || self.actionTracker.pending.values.contains(where: { $0.processIdentifier == pid })
            else { return }
            self.actionTracker.applicationDidTerminate(pid, now: ProcessInfo.processInfo.systemUptime)
            if self.panel != nil { self.keepsPanelFrame = true }
            self.loadWindows(presentErrors: false, preserveSelection: true)
        }
        startSignalHandling()
        startCommandTabInterception()
        prepareWindowControlPanel()
        prepareWindowSearch()
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
        if CommandLine.arguments.contains("--search") {
            showWindowSearch()
            return
        }
        if CommandLine.arguments.contains("--daemon") {
            // AeroSpace may not have created its socket yet during login or installation.
            // Keep the daemon responsive so the first shortcut can retry the load.
            loadWindows(presentErrors: false)
            return
        }
        if !invokedByShortcut {
            loadWindows(presentErrors: false)
            if !presentedPermissionGuide || CommandLine.arguments.contains("--settings") {
                showSettings()
            }
            return
        }
        showSwitcher()
        loadWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windowSearchController?.isVisible == true {
            showWindowSearch()
            return true
        }
        showSettings()
        return false
    }

    private func prepareSettingsEntryPoints() {
        func settingsItem() -> NSMenuItem {
            let item = NSMenuItem(
                title: localized("Settings…", "设置…"), action: #selector(showSettings), keyEquivalent: ","
            )
            item.target = self
            return item
        }
        func quitItem() -> NSMenuItem {
            let item = NSMenuItem(
                title: localized("Quit AeroSpace Companion", "退出 AeroSpace Companion"),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
            )
            item.target = NSApp
            return item
        }

        let statusMenu = NSMenu(title: "AeroSpace Companion")
        let heading = NSMenuItem(title: "AeroSpace Companion", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        statusMenu.addItem(heading)
        let searchItem = NSMenuItem(title: localized("Search windows…", "搜索窗口…"),
                                    action: #selector(showWindowSearch), keyEquivalent: "")
        searchItem.target = self
        statusMenu.addItem(searchItem)
        statusMenu.addItem(settingsItem())
        statusMenu.addItem(.separator())
        statusMenu.addItem(quitItem())
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(
            systemSymbolName: "rectangle.3.group", accessibilityDescription: "AeroSpace Companion"
        ) {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "AC"
        }
        item.button?.toolTip = "AeroSpace Companion"
        item.menu = statusMenu
        statusItem = item

        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "AeroSpace Companion", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "AeroSpace Companion")
        appMenu.addItem(settingsItem())
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem())
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        // Native field editors resolve Command-A/C/V/X through the responder
        // chain's Edit menu, including the search field and its input method.
        let editItem = NSMenuItem(title: localized("Edit", "编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editItem.title)
        for (title, selector, key) in [
            (localized("Cut", "剪切"), #selector(NSText.cut(_:)), "x"),
            (localized("Copy", "复制"), #selector(NSText.copy(_:)), "c"),
            (localized("Paste", "粘贴"), #selector(NSText.paste(_:)), "v"),
            (localized("Select All", "全选"), #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem(title: localized("Window", "窗口"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: localized("Window", "窗口"))
        windowMenu.addItem(NSMenuItem(
            title: localized("Close", "关闭"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        ))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu

        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: settingsNotificationName, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showSettings()
        }
    }

    @objc private func showSettings() {
        windowSearchController?.hide()
        if panel != nil { hideSwitcher() }
        windowControlPanelController?.hide(deactivateApplication: false)
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
            settingsController = controller
        }
        settingsController?.show()
    }

    private func applyPreferences() {
        let previousKey = selectedItem?.key
        iconCache.removeAll()
        selectedIndex = nil
        hoveredItemKey = nil
        orderedItems = makeOrderedItems()
        guard panel?.isVisible == true else { return }
        refreshContent()
        if let previousKey, let index = orderedItems.firstIndex(where: { $0.key == previousKey }) {
            setSelectedIndex(index)
        } else {
            prepareInitialSelection()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        actionRefreshWorkItem?.cancel()
        reopenRefreshWorkItem?.cancel()
        feedbackDismissWorkItem?.cancel()
        stopEventMonitoring()
        stopCommandTabInterception()
        permissionGuideCompletion?.cancel()
        if let cycleObserver {
            DistributedNotificationCenter.default().removeObserver(cycleObserver)
        }
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
        }
        if let searchObserver {
            DistributedNotificationCenter.default().removeObserver(searchObserver)
        }
        if let applicationTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationTerminationObserver)
        }
        forwardSignalSource?.cancel()
        reverseSignalSource?.cancel()
        windowControlSignalSource?.cancel()
        searchSignalSource?.cancel()
        windowSearchController?.hide()
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
        fallbackSelectionIndex: Int? = nil,
        refreshActivity: Bool = true
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        isSnapshotLoading = true
        // Background action reconciliation must not stall Tab or modifier release.
        isRefreshing = !preserveSelection
        let reopenedPIDs = reopenTracker.processIdentifiers
        let preparesCachedSelection = !preserveSelection && isLoaded && isAwaitingPresentation
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                let focusedWindowID = AeroSpaceClient.focusedWindowID()
                if preparesCachedSelection {
                    // Focus is cheap to query. Paint the cached selection before
                    // presenting, without waiting for the catalog or activity reads.
                    DispatchQueue.main.async {
                        guard let self, self.loadGeneration == generation else { return }
                        if self.prepareCachedSelection(focusedID: focusedWindowID) {
                            self.presentSwitcherIfNeeded()
                        }
                    }
                }
                let windows = try AeroSpaceClient.allWindows(validatingReopenedPIDs: reopenedPIDs)
                // If metadata is unavailable, keep window switching functional.
                let workspaces = (try? AeroSpaceClient.allWorkspaces()) ?? []
                let dockBadgeSnapshot = refreshActivity ? DockBadgeClient.currentSnapshot() : nil
                let audioActivitySnapshot = refreshActivity ? AudioActivityClient.currentSnapshot() : nil
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else { return }
                    let statusChanged = dockBadgeSnapshot.map { self.dockBadgeSnapshot != $0 } == true
                        || audioActivitySnapshot.map { self.audioActivitySnapshot != $0 } == true
                    if let dockBadgeSnapshot { self.dockBadgeSnapshot = dockBadgeSnapshot }
                    if let audioActivitySnapshot { self.audioActivitySnapshot = audioActivitySnapshot }
                    let applications = NSWorkspace.shared.runningApplications
                    self.applyWindowSnapshot(
                        windows: windows, workspaces: workspaces,
                        apps: self.runningApplicationCatalog(from: applications),
                        runningPIDs: Set(applications.filter { !$0.isTerminated }.map(\.processIdentifier)),
                        focusedID: focusedWindowID,
                        preserveSelection: preserveSelection || (preparesCachedSelection && self.selectedIndex != nil),
                        fallbackSelectionIndex: fallbackSelectionIndex, forceRefresh: statusChanged
                    )
                    self.scheduleActionRefresh()
                    self.scheduleReopenRefresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    let wasWaitingForReopen = self.reopenPresentationDeadline != nil
                    self.isRefreshing = false
                    self.isSnapshotLoading = false
                    let resolutions = self.actionTracker.reconcile(
                        liveWindowIDs: nil, runningPIDs: self.runningApplicationPIDs,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    self.presentActionResolutions(resolutions)
                    if !resolutions.isEmpty {
                        self.applyWindowSnapshot(
                            windows: self.allWindows, workspaces: self.allWorkspaces,
                            apps: self.allRunningApps, runningPIDs: self.runningApplicationPIDs,
                            focusedID: self.focusedWindowID, preserveSelection: true, forceRefresh: true
                        )
                    }
                    self.scheduleActionRefresh()
                    self.reopenTracker.reconcile(
                        windowsByPID: [:], runningPIDs: self.runningApplicationPIDs,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    self.scheduleReopenRefresh()
                    if let deadline = self.reopenPresentationDeadline,
                       ProcessInfo.processInfo.systemUptime >= deadline || !self.reopenTracker.needsRefresh {
                        self.finishReopenPresentationUsingCache()
                    }
                    if presentErrors && !wasWaitingForReopen {
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private var runningApplicationPIDs: Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
    }

    private func applyWindowSnapshot(
        windows: [AeroWindow], workspaces: [AeroWorkspace], apps: [RunningApp],
        runningPIDs: Set<pid_t>, focusedID: Int?, preserveSelection: Bool,
        fallbackSelectionIndex: Int? = nil, forceRefresh: Bool = false
    ) {
        let preserveSelection = preserveSelection && isLoaded
            && (selectedIndex != nil || fallbackSelectionIndex != nil)
        let previousKey = preserveSelection ? selectedItem?.key : nil
        let previousAppPID: pid_t?
        if preserveSelection, case .application(let app) = selectedItem {
            previousAppPID = app.processIdentifier
        } else {
            previousAppPID = nil
        }
        let previousIndex = selectedIndex ?? fallbackSelectionIndex ?? 0
        let resolutions = actionTracker.reconcile(
            liveWindowIDs: Set(windows.map(\.windowID)), runningPIDs: runningPIDs,
            now: ProcessInfo.processInfo.systemUptime
        )
        var visibleWindows = windows.filter {
            !actionTracker.suppresses(windowID: $0.windowID, processIdentifier: $0.appPID)
        }
        let incomingIDs = Set(visibleWindows.map(\.windowID))
        // An app can lose its windows before finishing termination. Retain its
        // existing rows, with progress, until the process actually exits.
        visibleWindows += allWindows.filter {
            !incomingIDs.contains($0.windowID)
                && actionTracker.action(windowID: $0.windowID, processIdentifier: $0.appPID) != nil
        }
        if preserveSelection {
            let previousOrder = Dictionary(uniqueKeysWithValues: allWindows.enumerated().map { ($0.element.windowID, $0.offset) })
            visibleWindows = visibleWindows.enumerated().sorted {
                let left = previousOrder[$0.element.windowID] ?? (allWindows.count + $0.offset)
                let right = previousOrder[$1.element.windowID] ?? (allWindows.count + $1.offset)
                return left < right
            }.map(\.element)
        }
        let windowPIDs = Set(visibleWindows.map(\.appPID))
        var visibleApps = apps.filter {
            !windowPIDs.contains($0.processIdentifier)
                && !actionTracker.suppresses(processIdentifier: $0.processIdentifier)
        }
        let incomingPIDs = Set(visibleApps.map(\.processIdentifier))
        visibleApps += windowlessApps.filter {
            !incomingPIDs.contains($0.processIdentifier)
                && !windowPIDs.contains($0.processIdentifier)
                && actionTracker.action(processIdentifier: $0.processIdentifier) != nil
        }
        if preserveSelection {
            let previousOrder = Dictionary(uniqueKeysWithValues: windowlessApps.enumerated().map { ($0.element.processIdentifier, $0.offset) })
            visibleApps = visibleApps.enumerated().sorted {
                (previousOrder[$0.element.processIdentifier] ?? (windowlessApps.count + $0.offset))
                    < (previousOrder[$1.element.processIdentifier] ?? (windowlessApps.count + $1.offset))
            }.map(\.element)
        }
        let needsRefresh = !isLoaded || !preserveSelection || forceRefresh || !resolutions.isEmpty
            || allWindows != visibleWindows || allWorkspaces != workspaces
            || windowlessApps != visibleApps || focusedWindowID != focusedID
            || orderedItems.contains { itemRows[$0.key]?.pendingMessage != pendingAction(for: $0).map(pendingStatusText) }
        allWindows = visibleWindows
        allWorkspaces = workspaces
        allRunningApps = apps
        focusedWindowID = focusedID
        windowlessApps = visibleApps
        warmIconCache()
        reopenTracker.reconcile(
            windowsByPID: Dictionary(grouping: visibleWindows, by: \.appPID).mapValues { Set($0.map(\.windowID)) },
            runningPIDs: runningPIDs, now: ProcessInfo.processInfo.systemUptime
        )
        isSnapshotLoading = false
        if let deadline = reopenPresentationDeadline,
           ProcessInfo.processInfo.systemUptime < deadline, reopenTracker.hasUnresolvedReopen {
            // Update the cache atomically, but do not paint the old windowless
            // row while the app is registering the window we just requested.
            isRefreshing = true
            return
        }
        reopenPresentationDeadline = nil
        // Publish rebuilt rows and their selected appearance in one transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        selectedIndex = nil
        orderedItems = makeOrderedItems()
        isLoaded = true
        isRefreshing = false
        isSnapshotLoading = false
        presentActionResolutions(resolutions)
        updateWindowControlPanelIfVisible()
        if needsRefresh {
            refreshContent(preservingViewport: preserveSelection, preferredViewportKey: previousKey)
        }
        guard !orderedItems.isEmpty else {
            presentSwitcherIfNeeded()
            if commitWhenLoaded { dismiss() }
            return
        }
        let directIndex = pendingDirectSelectionIndex
        pendingDirectSelectionIndex = nil
        if let directIndex, orderedItems.indices.contains(directIndex) {
            pendingCycleDelta = 0
            setSelectedIndex(directIndex)
        } else if preserveSelection {
            let promotedIndex = previousAppPID.flatMap { pid in
                orderedItems.firstIndex { item in
                    guard case .window(let window) = item else { return false }
                    return window.appPID == pid && window.windowID == focusedID
                } ?? orderedItems.firstIndex { item in
                    guard case .window(let window) = item else { return false }
                    return window.appPID == pid
                }
            }
            let preservedIndex = previousKey.flatMap { key in orderedItems.firstIndex { $0.key == key } }
                ?? promotedIndex ?? min(previousIndex, orderedItems.count - 1)
            let delta = pendingCycleDelta
            pendingCycleDelta = 0
            setSelectedIndex(preservedIndex + delta, reveal: delta != 0)
        } else {
            prepareInitialSelection()
        }
        presentSwitcherIfNeeded()
        if commitWhenLoaded { commitSelectedWindow() }
    }

    private func handleCycleRequest(
        direction: Int,
        tracking modifier: NSEvent.ModifierFlags = .option,
        modifierIsPressed: Bool? = nil
    ) {
        windowSearchController?.hide()
        let trackingChanged = trackedReleaseModifier != modifier
        let isPressed = modifierIsPressed ?? NSEvent.modifierFlags.contains(modifier)
        trackedReleaseModifier = isPressed ? modifier : nil
        if isPressed {
            commitWhenLoaded = false
        }

        if panel != nil {
            if isRefreshing {
                pendingCycleDelta += direction
                return
            }
            // The list stays identical; only Command's direct-selection keycaps change.
            if trackingChanged { refreshContent() }
            moveSelection(by: direction)
            return
        }

        launchDirection = direction
        commitWhenLoaded = !isPressed
        focusedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusedWindowID = nil
        // Both shortcuts use the same cached workspace/window/application list.
        orderedItems = makeOrderedItems()
        let hasCachedItems = !orderedItems.isEmpty
        let waitsForReopenedWindow = reopenTracker.hasUnresolvedReopen
        reopenPresentationDeadline = waitsForReopenedWindow
            ? ProcessInfo.processInfo.systemUptime + SwitcherReopenTracker.presentationWait : nil
        pendingCycleDelta = 0
        selectedIndex = nil
        isLoaded = hasCachedItems && !waitsForReopenedWindow
        showSwitcher()
        loadWindows(refreshActivity: !reopenTracker.needsRefresh)
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
        panel.acceptsMouseMovedEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = makeContentView(for: screen)
        self.panel = panel
        isAwaitingPresentation = true

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            if event.type == .flagsChanged {
                self?.handleModifierFlags(event.modifierFlags)
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self?.showSettings()
                return nil
            } else if self?.handleCommandSelectionShortcut(event) == true {
                return nil
            } else if event.keyCode == 53 {
                self?.trackedReleaseModifier = nil
                self?.dismiss()
                return nil
            } else if event.keyCode == 36 {
                self?.commitSelectedWindow(allowPendingActivation: true)
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
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseDownEvents.union(.mouseMoved)
        ) {
            [weak self] event in
            guard
                let self,
                let panel = self.panel,
                event.window === panel,
                let contentView = panel.contentView
            else {
                return event
            }

            if event.type == .mouseMoved {
                self.reconcileHoveredItem(at: event.locationInWindow)
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
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents.union(.mouseMoved)) {
            [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard
                    let self,
                    let panel = self.panel,
                    panel.isVisible
                else {
                    return
                }
                if event.type == .mouseMoved {
                    self.reconcileHoveredItem(at: panel.convertPoint(fromScreen: mouseLocation))
                } else if !panel.frame.contains(mouseLocation) {
                    self.dismiss()
                }
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

            self.scrollSwitcher(with: event, in: scrollView)
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
                self.scrollSwitcher(with: event, in: scrollView)
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
        // A cached list waits only for its opening selection. Cold/reopen loads
        // can show the existing progress view while the catalog is unavailable.
        if !isLoaded { presentSwitcherIfNeeded() }
    }

    private func prepareCachedSelection(focusedID: Int?) -> Bool {
        guard panel != nil, isLoaded, selectedIndex == nil else { return false }
        // Missing focus or a newly focused window needs the fresh catalog. A
        // cached workspace/app fallback could highlight the wrong item first.
        guard let focusedID, allWindows.contains(where: { $0.windowID == focusedID }) else { return false }
        focusedWindowID = focusedID
        prepareInitialSelection()
        refreshContent(preservingViewport: false)
        if let key = selectedItem?.key, let row = itemRows[key] {
            row.scrollToVisible(row.bounds)
        }
        return selectedIndex != nil
    }

    private func presentSwitcherIfNeeded() {
        guard isAwaitingPresentation, let panel, !panel.isVisible else { return }
        isAwaitingPresentation = false
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        reconcileHoveredItemWithPointer()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func refreshContent(preservingViewport: Bool = true, preferredViewportKey: String? = nil) {
        guard let panel, let targetScreen else { return }
        let viewport = preservingViewport ? switcherScrollView.flatMap {
            SwitcherScroll.capture(in: $0, rows: itemRows, preferredKey: preferredViewportKey ?? selectedItem?.key)
        } : nil
        if !keepsPanelFrame {
            panel.setFrame(switcherFrame(for: targetScreen), display: false)
        }
        panel.contentView = makeContentView(for: targetScreen)
        panel.contentView?.layoutSubtreeIfNeeded()
        if let key = selectedItem?.key { itemRows[key]?.isSelected = true }
        if let viewport, let scrollView = switcherScrollView {
            if keepsPanelFrame {
                // Leave just enough trailing space to avoid a jump when removing
                // items at the end of a scrolled list. Reset on the next invocation.
                documentMinimumHeightConstraint?.constant = SwitcherScroll.anchoredY(
                    viewport, in: scrollView, rows: itemRows
                ) + scrollView.contentView.bounds.height
                panel.contentView?.layoutSubtreeIfNeeded()
            }
            SwitcherScroll.restore(viewport, in: scrollView, rows: itemRows)
        }
        // Refreshing a pending operation must not steal focus from a save dialog.
        reconcileHoveredItemWithPointer()
    }

    private func scrollSwitcher(with event: NSEvent, in scrollView: NSScrollView) {
        reclaimSwitcherKeyboardFocus()
        // Events intercepted by the session tap do not travel through AppKit's
        // normal gesture routing. Apply deltas directly instead of asking
        // NSScrollView to reconstruct a trackpad gesture from forwarded events.
        // Deltas already respect natural scrolling; do not invert them again.
        SwitcherScroll.apply(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            to: scrollView
        )
        reconcileHoveredItemWithPointer()
    }

    private func scrollSwitcher(byMagnification magnification: CGFloat) {
        guard let scrollView = switcherScrollView else { return }
        reclaimSwitcherKeyboardFocus()
        SwitcherScroll.apply(deltaY: magnification * 800, precise: true, to: scrollView)
        reconcileHoveredItemWithPointer()
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
        } else if orderedItems.isEmpty {
            let message = textLabel(
                localized("No windows to show", "没有可显示的窗口"),
                size: 13, color: .secondaryLabelColor
            )
            message.alignment = .center
            message.heightAnchor.constraint(equalToConstant: 56).isActive = true
            groupStack.addArrangedSubview(message)
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

        let naturalBottom = groupStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        naturalBottom.priority = .defaultLow
        let minimumHeight = documentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        documentMinimumHeightConstraint = minimumHeight
        NSLayoutConstraint.activate([
            groupStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            groupStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            groupStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            groupStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            naturalBottom,
            minimumHeight,
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        root.addSubview(surface)
        surface.addSubview(glass)
        surface.addSubview(scrollView)
        actionFeedbackView = nil
        let scrollBottom: NSLayoutConstraint
        if trackedReleaseModifier == .command {
            let footer = SwitcherActionFeedbackView()
            surface.addSubview(footer)
            actionFeedbackView = footer
            NSLayoutConstraint.activate([
                footer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -SwitcherStyle.contentPadding),
            ])
            scrollBottom = scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4)
            updateActionFeedback()
        } else {
            scrollBottom = scrollView.bottomAnchor.constraint(
                equalTo: surface.bottomAnchor, constant: -SwitcherStyle.contentPadding
            )
        }
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
            scrollBottom,
        ])

        return root
    }

    private func switcherFrame(for screen: NSScreen) -> NSRect {
        let groups = workspaceGroups()
        let listHeight = SwitcherStyle.metrics.listHeight(
            workspaceWindowCounts: groups.map { $0.windows.count },
            windowlessAppCount: windowlessApps.count
        )
        let visibleFrame = screen.visibleFrame
        let width = min(588, max(360, visibleFrame.width - 48))
        let maximumHeight = min(
            SwitcherStyle.maximumPanelHeight,
            max(176, visibleFrame.height - SwitcherStyle.panelScreenInset * 2)
        )
        let surfaceChromeHeight = SwitcherStyle.contentPadding * 2
            + (trackedReleaseModifier == .command ? 32 : 0)
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
        if group.windows.isEmpty {
            return makeEmptyWorkspaceRow(group)
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = SwitcherStyle.rowSpacing
        stack.addArrangedSubview(makeGroupHeader(
            title: workspaceHeaderTitle(group.workspace),
            metadata: group.monitorID > 0 ? "D\(group.monitorID)" : "D?",
            titleIcons: makeWorkspaceTitleIcons(group)
        ))

        for window in group.windows {
            let row = makeWindowRow(window)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func makeEmptyWorkspaceRow(_ group: WorkspaceGroup) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let item = SwitcherItem.workspace(group)
        let shortcutNumber = commandSelectionShortcutNumber(for: item)
        let description = localized("Enter this workspace", "进入此工作区")
        var accessibilityLabel = "\(workspaceHeaderTitle(group.workspace)), \(description)"
        if let shortcutNumber {
            accessibilityLabel += localized(
                ", Command-\(shortcutNumber) selects this item",
                "，Command-\(shortcutNumber) 选择此项"
            )
        }
        row.setAccessibilityLabel(accessibilityLabel)
        row.toolTip = localized(
            "Switch to workspace \(group.workspace) without opening an app",
            "进入工作区 \(group.workspace)，不启动应用"
        )
        row.onClick = { [weak self] in self?.select(item) }
        row.onHoverChanged = { [weak self] point in
            self?.reconcileHoveredItem(at: point)
        }
        let icon = NSView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: NSImage(
            systemSymbolName: "rectangle.dashed", accessibilityDescription: nil
        ) ?? NSImage())
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        icon.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),
        ])
        let title = textLabel(
            workspaceHeaderTitle(group.workspace),
            size: 10,
            weight: .semibold,
            color: .secondaryLabelColor
        )
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let status = NSStackView()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8
        status.addArrangedSubview(makeWorkspaceTitleIcons(group))
        status.addArrangedSubview(textLabel(
            group.monitorID > 0 ? "D\(group.monitorID)" : "D?",
            size: 9,
            weight: .medium,
            color: .tertiaryLabelColor
        ))
        status.addArrangedSubview(textLabel(
            localized("Enter", "进入"),
            size: 10,
            weight: .medium,
            color: .tertiaryLabelColor
        ))
        if let shortcutNumber {
            status.addArrangedSubview(makeShortcutKeycap(shortcutNumber))
        }
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        layoutRowContent(
            row: row, icon: icon, title: title,
            status: status, height: SwitcherStyle.emptyWorkspaceRowHeight
        )
        row.registerLabels(primary: title, primaryColor: .secondaryLabelColor)
        row.isSelected = selectedItem?.key == item.key
        itemRows[item.key] = row
        return row
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

    private func makeGroupHeader(
        title: String,
        metadata: String? = nil,
        titleIcons: NSView? = nil
    ) -> NSView {
        let metrics = SwitcherStyle.metrics
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
            titleLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor, constant: metrics.groupHeaderHorizontalInset
            ),
            titleLabel.bottomAnchor.constraint(
                equalTo: header.bottomAnchor, constant: -metrics.groupHeaderBottomInset
            ),
        ]
        var titleTrailingAnchor = titleLabel.trailingAnchor
        if let titleIcons {
            header.addSubview(titleIcons)
            constraints.append(contentsOf: [
                titleIcons.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
                titleIcons.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ])
            titleTrailingAnchor = titleIcons.trailingAnchor
        }
        var accessory: NSView?
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
            accessory = metadataLabel
        }
        if let accessory {
            header.addSubview(accessory)
            constraints.append(contentsOf: [
                titleTrailingAnchor.constraint(
                    lessThanOrEqualTo: accessory.leadingAnchor,
                    constant: -10
                ),
                accessory.trailingAnchor.constraint(
                    equalTo: header.trailingAnchor,
                    constant: -metrics.groupHeaderHorizontalInset
                ),
                accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ])
        } else {
            constraints.append(
                titleTrailingAnchor.constraint(
                    lessThanOrEqualTo: header.trailingAnchor,
                    constant: -metrics.groupHeaderHorizontalInset
                )
            )
        }
        NSLayoutConstraint.activate(constraints)
        return header
    }

    private func workspaceHeaderTitle(_ workspace: String) -> String {
        let role = SwitcherConfiguration.workspaceLabel(workspace)
        return role.map { "\(workspace) · \($0)" }
            ?? localized("WORKSPACE \(workspace)", "WORKSPACE \(workspace)")
    }

    private func workspaceHeaderMetadata(_ group: WorkspaceGroup) -> String {
        WorkspaceHeaderMetadata.text(
            monitorID: group.monitorID,
            layout: group.layout,
            isFocused: group.isFocused,
            isVisible: group.isVisible,
            usesChinese: (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        )
    }

    private func makeWorkspaceTitleIcons(_ group: WorkspaceGroup) -> NSView {
        let metadata = NSStackView()
        metadata.translatesAutoresizingMaskIntoConstraints = false
        metadata.orientation = .horizontal
        metadata.alignment = .centerY
        metadata.spacing = 7
        metadata.toolTip = workspaceHeaderMetadata(group)
        if let symbol = WorkspaceHeaderMetadata.statusSymbol(
            isFocused: group.isFocused, isVisible: group.isVisible
        ) {
            metadata.addArrangedSubview(workspaceMetadataIcon(
                symbol: symbol,
                description: group.isFocused
                    ? localized("Current workspace", "当前工作区")
                    : localized("Visible workspace", "可见工作区"),
                size: 6,
                color: group.isFocused ? .secondaryLabelColor : .tertiaryLabelColor
            ))
        }
        metadata.addArrangedSubview(workspaceMetadataIcon(
            symbol: WorkspaceHeaderMetadata.layoutSymbol(group.layout),
            description: WorkspaceHeaderMetadata.layoutLabel(
                group.layout,
                usesChinese: (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
            ),
            size: 14,
            rotation: WorkspaceHeaderMetadata.layoutRotation(group.layout),
            color: .tertiaryLabelColor
        ))
        metadata.setContentHuggingPriority(.required, for: .horizontal)
        metadata.setContentCompressionResistancePriority(.required, for: .horizontal)
        return metadata
    }

    private func workspaceMetadataIcon(
        symbol: String,
        description: String,
        size: CGFloat,
        rotation: CGFloat = 0,
        color: NSColor
    ) -> NSView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let source = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if rotation != 0, let source {
            let rotated = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX, yBy: rect.midY)
                transform.rotate(byDegrees: rotation)
                transform.concat()
                source.draw(in: NSRect(x: -size / 2, y: -size / 2, width: size, height: size))
                return true
            }
            rotated.isTemplate = true
            icon.image = rotated
        } else {
            icon.image = source
        }
        icon.contentTintColor = color
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = description
        icon.setAccessibilityElement(true)
        icon.setAccessibilityRole(.image)
        icon.setAccessibilityLabel(description)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: size),
            icon.heightAnchor.constraint(equalToConstant: size),
        ])
        return icon
    }

    private func makeWindowRow(_ window: AeroWindow) -> NSView {
        let row = ActionRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        let fallbackTitle = WindowDisplayTitle.resolve(
            windowTitle: window.windowTitle,
            appName: window.appName,
            fallback: localized("Untitled Window", "无标题窗口")
        )
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
        row.onHoverChanged = { [weak self] point in
            self?.reconcileHoveredItem(at: point)
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
            size: SwitcherStyle.metrics.rowTitleFontSize,
            weight: .medium,
            color: .labelColor
        )
        windowTitle.lineBreakMode = .byTruncatingMiddle
        windowTitle.maximumNumberOfLines = 1
        windowTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layoutRowContent(row: row, icon: icon, title: windowTitle, status: status)
        row.registerLabels(primary: windowTitle)
        row.pendingMessage = pendingAction(for: item).map(pendingStatusText)
        row.isSelected = selectedItem?.key == item.key
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
        row.onHoverChanged = { [weak self] point in
            self?.reconcileHoveredItem(at: point)
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
            size: SwitcherStyle.metrics.rowTitleFontSize,
            weight: .medium,
            color: .labelColor
        )
        appName.lineBreakMode = .byTruncatingMiddle
        appName.maximumNumberOfLines = 1
        appName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        layoutRowContent(row: row, icon: icon, title: appName, status: status)
        row.registerLabels(primary: appName)
        row.pendingMessage = pendingAction(for: item).map(pendingStatusText)
        row.isSelected = selectedItem?.key == item.key
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
        let names = WorkspaceCatalog.orderedNames(
            occupied: Array(grouped.keys), workspaces: allWorkspaces,
            showEmptyWorkspaces: SwitcherPreferences.shared.showEmptyWorkspaces
        )
        return names.compactMap { workspace in
            let windows = grouped[workspace] ?? []
            if windows.isEmpty {
                guard let info = allWorkspaces.first(where: { $0.workspace == workspace }) else {
                    return nil
                }
                return WorkspaceGroup(
                    workspace: workspace, isFocused: info.isFocused, isVisible: info.isVisible,
                    monitorID: info.monitorID, monitorName: info.monitorName,
                    layout: info.layout, windows: []
                )
            }
            guard
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
                layout: firstWindow.workspaceLayout,
                windows: windows
            )
        }
    }

    private func makeOrderedItems() -> [SwitcherItem] {
        workspaceGroups().flatMap { group -> [SwitcherItem] in
            group.windows.isEmpty ? [.workspace(group)] : group.windows.map(SwitcherItem.window)
        } + windowlessApps.map(SwitcherItem.application)
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
        } else if let emptyIndex = orderedItems.firstIndex(where: {
            guard case .workspace(let group) = $0 else { return false }
            return group.isFocused
        }) {
            initialIndex = emptyIndex + pendingCycleDelta
        } else if let focusedApplicationPID,
                  let currentIndex = orderedItems.firstIndex(where: {
                      switch $0 {
                      case .window(let window): return window.appPID == focusedApplicationPID
                      case .application(let app): return app.processIdentifier == focusedApplicationPID
                      case .workspace: return false
                      }
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
        suppressedAutomaticActivationPID = nil
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

    private func setSelectedIndex(_ index: Int, reveal: Bool = true) {
        guard !orderedItems.isEmpty else { return }

        let count = orderedItems.count
        let normalizedIndex = ((index % count) + count) % count
        selectedIndex = normalizedIndex
        let selectedItem = orderedItems[normalizedIndex]
        for (key, row) in itemRows {
            row.isSelected = key == selectedItem.key
        }
        if let row = itemRows[selectedItem.key] {
            if reveal { row.scrollToVisible(row.bounds) }
        }
        updateActionFeedback()
        reconcileHoveredItemWithPointer()
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        guard
            let trackedReleaseModifier,
            !flags.contains(trackedReleaseModifier)
        else {
            return
        }
        self.trackedReleaseModifier = nil

        if isRefreshing {
            commitWhenLoaded = true
        } else if orderedItems.isEmpty {
            dismiss()
        } else {
            commitSelectedWindow()
        }
    }

    private func commitSelectedWindow(allowPendingActivation: Bool = false) {
        if !isRefreshing && orderedItems.isEmpty {
            dismiss()
            return
        }
        guard
            let selectedIndex,
            orderedItems.indices.contains(selectedIndex)
        else {
            commitWhenLoaded = true
            return
        }
        let item = orderedItems[selectedIndex]
        if !allowPendingActivation {
            if pendingAction(for: item) != nil {
                dismiss()
                return
            }
            if case .application(let app) = item,
               app.processIdentifier == suppressedAutomaticActivationPID {
                // Closing the last window must not immediately reopen it when
                // Command is released. Explicit navigation/click/Return can reopen.
                dismiss()
                return
            }
        }
        select(item)
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

    private func reconcileHoveredItemWithPointer() {
        guard let panel else { return }
        reconcileHoveredItem(at: panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }

    private func reconcileHoveredItem(at windowPoint: NSPoint) {
        guard let scrollView = switcherScrollView else { return }
        // A row can move under the pointer without receiving mouseExited.
        let clipView = scrollView.contentView
        let clipPoint = clipView.convert(windowPoint, from: nil)
        let hoveredKey = clipView.bounds.contains(clipPoint)
            ? itemRows.first { _, row in
                row.bounds.contains(row.convert(windowPoint, from: nil))
            }?.key
            : nil

        for (key, row) in itemRows {
            row.setHovered(key == hoveredKey)
        }
        hoveredItemKey = hoveredKey
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

    private func handleCommandSelectionShortcut(_ event: NSEvent, pointerLocation: NSPoint? = nil) -> Bool {
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
                reconcileCommandPointer(pointerLocation)
                closeSelectedWindow()
            }
            return true
        case kVK_ANSI_Q:
            if !event.isARepeat {
                reconcileCommandPointer(pointerLocation)
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
                suppressedAutomaticActivationPID = nil
                setSelectedIndex(index)
            } else {
                showActionFeedback(localized(
                    "There is no item \(index + 1) in this list",
                    "列表中没有第 \(index + 1) 项"
                ), tone: .neutral)
            }
            return true
        default:
            return false
        }
    }

    private func reconcileCommandPointer(_ screenPoint: NSPoint?) {
        guard let panel else { return }
        // Tracking-area notifications can lag behind a rebuilt list or be sent
        // to another app after AeroSpace focuses a surviving window.
        reconcileHoveredItem(at: panel.convertPoint(fromScreen: screenPoint ?? NSEvent.mouseLocation))
    }

    private func reclaimSwitcherKeyboardFocus() {
        guard let panel, panel.isVisible, !panel.isKeyWindow || !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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

    private func pendingAction(for item: SwitcherItem) -> PendingSwitcherAction? {
        switch item {
        case .window(let window):
            return actionTracker.action(windowID: window.windowID, processIdentifier: window.appPID)
        case .application(let app):
            return actionTracker.action(processIdentifier: app.processIdentifier)
        case .workspace: return nil
        }
    }

    private func pendingStatusText(_ action: PendingSwitcherAction) -> String {
        if ProcessInfo.processInfo.systemUptime - action.startedAt >= SwitcherActionTracker.waitingDelay {
            return localized("Waiting…", "等待响应…")
        }
        return action.isQuit ? localized("Quitting…", "退出中…") : localized("Closing…", "关闭中…")
    }

    private func closeSelectedWindow(target: (index: Int, item: SwitcherItem)? = nil) {
        guard let target = target ?? commandActionTarget else {
            showActionFeedback(localized("No window selected", "没有选中的窗口"), tone: .neutral)
            return
        }
        guard case .window(let window) = target.item else {
            let message: String
            if case .application(let app) = target.item {
                message = localized(
                    "\(app.appName) has no windows to close · ⌘Q quits the app",
                    "\(app.appName) 没有可关闭的窗口 · ⌘Q 可退出 App"
                )
            } else {
                message = localized("This workspace has no windows to close", "此工作区没有可关闭的窗口")
            }
            showActionFeedback(message, tone: .neutral)
            return
        }
        if let pending = pendingAction(for: target.item) {
            showPendingFeedback(pending)
            return
        }
        let subject = WindowDisplayTitle.resolve(
            windowTitle: window.windowTitle, appName: window.appName,
            fallback: localized("Window", "窗口")
        )
        guard let action = actionTracker.begin(
            target: .window(window.windowID), processIdentifier: window.appPID,
            subject: subject, now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        beginActionFeedback(action)
        requestWindowClose(window.windowID) { [weak self] error in
            guard let self else { return }
            if let error, self.actionTracker.cancel(action) {
                if self.latestFeedbackActionID == action.id {
                    self.showActionFeedback(localized(
                        "Couldn’t close \(subject): \(error.localizedDescription)",
                        "无法关闭 \(subject)：\(error.localizedDescription)"
                    ), tone: .warning)
                }
                self.refreshContent()
            }
            self.scheduleActionRefresh()
        }
    }

    private func quitSelectedApplication(target: (index: Int, item: SwitcherItem)? = nil) {
        guard let target = target ?? commandActionTarget else {
            showActionFeedback(localized("No app selected", "没有选中的 App"), tone: .neutral)
            return
        }
        let processIdentifier: pid_t
        let appName: String
        switch target.item {
        case .window(let window):
            processIdentifier = window.appPID
            appName = window.appName
        case .application(let app):
            processIdentifier = app.processIdentifier
            appName = app.appName
        case .workspace:
            showActionFeedback(localized("This workspace has no app to quit", "此工作区没有可退出的 App"), tone: .neutral)
            return
        }
        if let pending = actionTracker.pending[.application(processIdentifier)] {
            showPendingFeedback(pending)
            return
        }
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let runningApplication = NSRunningApplication(processIdentifier: processIdentifier),
              !runningApplication.isTerminated else {
            showActionFeedback(localized("This app is no longer running", "此 App 已不在运行"), tone: .neutral)
            loadWindows(presentErrors: false, preserveSelection: true)
            return
        }
        guard let action = actionTracker.begin(
            target: .application(processIdentifier), processIdentifier: processIdentifier,
            subject: appName, now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        beginActionFeedback(action)
        guard runningApplication.terminate() else {
            actionTracker.cancel(action)
            showActionFeedback(localized("Couldn’t quit \(appName)", "无法退出 \(appName)"), tone: .warning)
            refreshContent()
            return
        }
        scheduleActionRefresh()
    }

    private func beginActionFeedback(_ action: PendingSwitcherAction) {
        // Discard any snapshot started before this command, and keep the panel's
        // screen position and height for the rest of this invocation.
        loadGeneration += 1
        isRefreshing = false
        isSnapshotLoading = false
        keepsPanelFrame = true
        watchesActionChanges = true
        latestFeedbackActionID = action.id
        suppressedAutomaticActivationPID = action.processIdentifier
        showPendingFeedback(action)
        refreshContent()
        scheduleActionRefresh()
    }

    private func scheduleActionRefresh() {
        actionRefreshWorkItem?.cancel()
        guard !actionTracker.pending.isEmpty || (watchesActionChanges && panel != nil) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isSnapshotLoading {
                self.scheduleActionRefresh()
                return
            }
            self.loadWindows(presentErrors: false, preserveSelection: true)
        }
        actionRefreshWorkItem = work
        let delay: TimeInterval = actionTracker.pending.isEmpty ? 1 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func presentActionResolutions(_ resolutions: [SwitcherActionResolution]) {
        if resolutions.contains(where: \.completed) {
            // A confirmed close/quit may make AeroSpace focus a different app.
            // Restore input for continued interaction, but leave pending save
            // dialogs alone until the user explicitly scrolls or chooses a row.
            reclaimSwitcherKeyboardFocus()
        }
        for resolution in resolutions where resolution.action.id == latestFeedbackActionID {
            let action = resolution.action
            if resolution.completed {
                showActionFeedback(action.isQuit
                    ? localized("Quit \(action.subject)", "已退出 \(action.subject)")
                    : localized("Closed \(action.subject)", "已关闭 \(action.subject)"), tone: .success)
            } else {
                showActionFeedback(localized(
                    "\(action.subject) hasn’t finished · Switch to the app to check for a dialog",
                    "\(action.subject) 尚未完成操作 · 请切换到 App 检查确认对话框"
                ), tone: .warning)
            }
        }
        if let action = actionTracker.pending.values.first(where: { $0.id == latestFeedbackActionID }),
           ProcessInfo.processInfo.systemUptime - action.startedAt >= SwitcherActionTracker.waitingDelay {
            showPendingFeedback(action)
        }
    }

    private func showPendingFeedback(_ action: PendingSwitcherAction) {
        latestFeedbackActionID = action.id
        let waiting = ProcessInfo.processInfo.systemUptime - action.startedAt >= SwitcherActionTracker.waitingDelay
        let message = waiting ? localized(
            "Waiting for \(action.subject) · Select it to check for a dialog",
            "等待 \(action.subject) 响应 · 选择此项可检查确认对话框"
        ) : (action.isQuit
            ? localized("Quitting \(action.subject)…", "正在退出 \(action.subject)…")
            : localized("Closing \(action.subject)…", "正在关闭 \(action.subject)…"))
        showActionFeedback(message, tone: .progress, expires: false)
    }

    private func showActionFeedback(_ message: String, tone: SwitcherFeedbackTone, expires: Bool = true) {
        guard panel != nil else { return }
        if tone != .progress { latestFeedbackActionID = nil }
        let changed = actionFeedback?.message != message
        actionFeedback = SwitcherActionFeedback(message: message, tone: tone)
        feedbackDismissWorkItem?.cancel()
        updateActionFeedback()
        if changed, let view = actionFeedbackView {
            NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        if expires {
            let work = DispatchWorkItem { [weak self] in
                self?.actionFeedback = nil
                self?.updateActionFeedback()
            }
            feedbackDismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func updateActionFeedback() {
        let feedback = actionFeedback ?? SwitcherActionFeedback(
            message: localized("⌘W Close window    ⌘Q Quit app", "⌘W 关闭窗口    ⌘Q 退出 App"),
            tone: .neutral
        )
        actionFeedbackView?.update(feedback)
    }

    private func showTransientActionError(_ message: String) {
        showActionFeedback(message, tone: .warning)
        NSSound.beep()
        NSLog("AeroSpace Window Switcher action failed: %@", message)
    }

    private func select(_ item: SwitcherItem) {
        if let action = pendingAction(for: item) {
            hideSwitcher()
            // A pending quit must never send a reopen event and create a new window.
            NSRunningApplication(processIdentifier: action.processIdentifier)?.activate(options: [])
            return
        }
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
        case .workspace(let group):
            hideSwitcher()
            AeroSpaceClient.activateWorkspace(group.workspace) { [weak self] error in
                if let error { self?.showTransientActionError(error.localizedDescription) }
            }
        }
    }

    private func reopenApplication(_ app: RunningApp) {
        guard let runningApplication = NSRunningApplication(
            processIdentifier: app.processIdentifier
        ) else {
            return
        }

        if reopenTracker.contains(app.processIdentifier) {
            // A fast second invocation activates the app without sending a
            // duplicate reopen event while its first window is being created.
            runningApplication.activate(options: [])
            scheduleReopenRefresh()
            return
        }
        beginReopeningApplication(app.processIdentifier)

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

    private func beginReopeningApplication(_ processIdentifier: pid_t) {
        actionTracker.prepareForReopen(processIdentifier)
        reopenTracker.begin(processIdentifier, now: ProcessInfo.processInfo.systemUptime)
        // A snapshot started before the reopen request must not overwrite the
        // warmed catalog, even if its slower status queries finish later.
        loadGeneration += 1
        isSnapshotLoading = false
        isRefreshing = false
        scheduleReopenRefresh()
    }

    private func finishReopenPresentationUsingCache() {
        reopenPresentationDeadline = nil
        applyWindowSnapshot(
            windows: allWindows, workspaces: allWorkspaces, apps: allRunningApps,
            runningPIDs: runningApplicationPIDs, focusedID: focusedWindowID,
            preserveSelection: false, forceRefresh: true
        )
        showActionFeedback(localized("Window list update is delayed", "窗口列表更新稍有延迟"), tone: .neutral)
    }

    private func scheduleReopenRefresh() {
        reopenRefreshWorkItem?.cancel()
        guard reopenTracker.needsRefresh else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isSnapshotLoading {
                self.scheduleReopenRefresh()
                return
            }
            self.loadWindows(
                presentErrors: false, preserveSelection: self.panel == nil || self.isLoaded,
                refreshActivity: false
            )
        }
        reopenRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func dismiss() {
        hideSwitcher()
        NSApp.deactivate()
    }

    private func hideSwitcher() {
        isAwaitingPresentation = false
        reopenPresentationDeadline = nil
        trackedReleaseModifier = nil
        commitWhenLoaded = false
        pendingCycleDelta = 0
        pendingDirectSelectionIndex = nil
        selectedIndex = nil
        hoveredItemKey = nil
        isRefreshing = false
        isSnapshotLoading = false
        loadGeneration += 1
        keepsPanelFrame = false
        watchesActionChanges = false
        actionFeedback = nil
        latestFeedbackActionID = nil
        suppressedAutomaticActivationPID = nil
        feedbackDismissWorkItem?.cancel()
        actionFeedbackView = nil
        panel?.orderOut(nil)
        panel = nil
        targetScreen = nil
        switcherScrollView = nil
        itemRows.removeAll()
        stopEventMonitoring()
        scheduleActionRefresh()
        scheduleReopenRefresh()
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
        status: NSView?,
        height: CGFloat = SwitcherStyle.rowHeight
    ) {
        let metrics = SwitcherStyle.metrics
        row.addSubview(icon)
        row.addSubview(title)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: height),
            icon.leadingAnchor.constraint(
                equalTo: row.leadingAnchor, constant: metrics.rowLeadingInset
            ),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SwitcherStyle.iconSize),
            title.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: metrics.rowContentSpacing
            ),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ]
        if let status {
            row.addSubview(status)
            constraints.append(contentsOf: [
                title.trailingAnchor.constraint(
                    lessThanOrEqualTo: status.leadingAnchor,
                    constant: -metrics.rowContentSpacing
                ),
                status.trailingAnchor.constraint(
                    equalTo: row.trailingAnchor, constant: -metrics.rowTrailingInset
                ),
                status.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        } else {
            constraints.append(
                title.trailingAnchor.constraint(
                    equalTo: row.trailingAnchor, constant: -metrics.rowTextTrailingInset
                )
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
        if let action = actionTracker.action(windowID: window?.windowID, processIdentifier: processIdentifier) {
            let status = NSStackView()
            status.translatesAutoresizingMaskIntoConstraints = false
            status.orientation = .horizontal
            status.alignment = .centerY
            status.spacing = 6
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.widthAnchor.constraint(equalToConstant: 12).isActive = true
            progress.heightAnchor.constraint(equalToConstant: 12).isActive = true
            progress.startAnimation(nil)
            status.addArrangedSubview(progress)
            status.addArrangedSubview(textLabel(pendingStatusText(action), size: 10, weight: .medium, color: .secondaryLabelColor))
            if let commandShortcutNumber { status.addArrangedSubview(makeShortcutKeycap(commandShortcutNumber)) }
            status.setContentHuggingPriority(.required, for: .horizontal)
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            status.toolTip = localized("Select to check the app for a confirmation dialog", "选择此项可查看 App 的确认对话框")
            return status
        }
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

    private func runningApplicationCatalog(from applications: [NSRunningApplication]) -> [RunningApp] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return applications.compactMap { app -> RunningApp? in
            guard app.processIdentifier != ownProcessIdentifier,
                  !app.isTerminated, app.activationPolicy == .regular,
                  let appName = app.localizedName else { return nil }
            return RunningApp(
                processIdentifier: app.processIdentifier,
                appName: appName,
                bundleIdentifier: app.bundleIdentifier ?? ""
            )
        }.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private func startSignalHandling() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        signal(SIGURG, SIG_IGN)
        signal(SIGWINCH, SIG_IGN)

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

        let searchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        searchSource.setEventHandler { [weak self] in self?.showWindowSearch() }
        searchSource.resume()
        searchSignalSource = searchSource
    }

    private func prepareWindowSearch() {
        let controller = WindowSearchController()
        controller.loadItems = { completion in
            DispatchQueue.global(qos: .userInteractive).async {
                let result = Result { try AeroSpaceClient.allWindows().filter { $0.appPID != getpid() }.map {
                    WindowSearchItem(windowID: $0.windowID, appName: $0.appName,
                                     bundleID: $0.appBundleID, title: $0.windowTitle,
                                     workspace: $0.workspace,
                                     workspaceLabel: SwitcherConfiguration.workspaceLabel($0.workspace) ?? "",
                                     monitorName: $0.monitorName)
                }.sorted {
                    if $0.workspace != $1.workspace {
                        return $0.workspace.localizedStandardCompare($1.workspace) == .orderedAscending
                    }
                    if $0.appName != $1.appName {
                        return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
                    }
                    return $0.windowID < $1.windowID
                } }
                DispatchQueue.main.async { completion(result) }
            }
        }
        controller.activateItem = { item, completion in
            AeroSpaceClient.activateSearchWindow(item.windowID, completion: completion)
        }
        windowSearchController = controller
        searchObserver = DistributedNotificationCenter.default().addObserver(
            forName: searchNotificationName, object: nil, queue: .main
        ) { [weak self] _ in self?.showWindowSearch() }
    }

    @objc private func showWindowSearch() {
        if panel != nil { hideSwitcher() }
        windowControlPanelController?.hide(deactivateApplication: false)
        guard let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first else { return }
        windowSearchController?.show(on: screen)
    }

    private func prepareWindowControlPanel() {
        let controller = WindowControlPanelController()
        controller.onCommand = { [weak self] request in
            self?.performWindowControl(request)
        }
        windowControlPanelController = controller
    }

    private func showWindowControlPanel() {
        windowSearchController?.hide()
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
        capturedSwitcherKeyCodes.removeAll()
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
                let scrollEvent = NSEvent(cgEvent: event)
            else {
                return Unmanaged.passUnretained(event)
            }

            // Consume once, before modifier-dependent system routing; both
            // Option-Tab and Command-Tab use the same pixel/line handling.
            scrollSwitcher(with: scrollEvent, in: scrollView)
            return nil
        }

        if interceptSwitcherKeyEvent(type: type, event: event, pointerLocation: NSEvent.mouseLocation) {
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

    private func interceptSwitcherKeyEvent(type: CGEventType, event: CGEvent, pointerLocation: NSPoint) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, capturedSwitcherKeyCodes.remove(keyCode) != nil { return true }
        guard type == .keyDown,
              let panel, panel.isVisible || isAwaitingPresentation,
              trackedReleaseModifier == .command,
              event.flags.contains(.maskCommand),
              event.flags.intersection([.maskAlternate, .maskControl, .maskShift]).isEmpty,
              [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
               kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].contains(Int(keyCode)),
              let keyEvent = NSEvent(cgEvent: event)
        else { return false }
        capturedSwitcherKeyCodes.insert(keyCode)
        guard !keyEvent.isARepeat else { return true }
        if isAwaitingPresentation {
            // Do not let Q/W reach the frontmost app before the switcher's
            // target is ready. Number shortcuts can already be queued safely.
            if let index = commandSelectionIndex(for: Int(keyCode)) {
                pendingDirectSelectionIndex = index
            }
            return true
        }
        let isAction = keyCode == Int64(kVK_ANSI_W) || keyCode == Int64(kVK_ANSI_Q)
        let actionKey: String?
        if isAction {
            reconcileCommandPointer(pointerLocation)
            actionKey = commandActionTarget?.item.key
        } else {
            actionKey = nil
        }
        // Swallow before delivery to the frontmost app, even when our panel has
        // lost key status. Dispatch UI/AX work outside the event-tap callback.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel, panel.isVisible else { return }
            if isAction {
                guard let actionKey, let index = self.orderedItems.firstIndex(where: { $0.key == actionKey }) else {
                    self.showActionFeedback(localized("This item is no longer available", "该项目已不在列表中"), tone: .neutral)
                    return
                }
                let target = (index: index, item: self.orderedItems[index])
                if keyCode == Int64(kVK_ANSI_W) {
                    self.closeSelectedWindow(target: target)
                } else {
                    self.quitSelectedApplication(target: target)
                }
            } else {
                _ = self.handleCommandSelectionShortcut(keyEvent, pointerLocation: pointerLocation)
            }
        }
        return true
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

#if !SWITCHER_ACTION_TESTING
private let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
#endif
