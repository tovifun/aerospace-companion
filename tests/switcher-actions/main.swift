
// Appended to the production main.swift with SWITCHER_ACTION_TESTING. Exercise
// real AppKit rows and snapshot reconciliation without issuing OS close/quit
// commands, showing a window, or writing the user's preference domain.
private func testActionTracker() {
    var tracker = SwitcherActionTracker()
    let close = tracker.begin(target: .window(1), processIdentifier: -1, subject: "Document", now: 0)!
    precondition(tracker.begin(target: .window(1), processIdentifier: -1, subject: "Document", now: 0.1) == nil)
    precondition(tracker.reconcile(liveWindowIDs: [], runningPIDs: [-1], now: 0.1).isEmpty)
    precondition(tracker.reconcile(liveWindowIDs: nil, runningPIDs: [-1], now: 1).isEmpty)
    precondition(tracker.reconcile(liveWindowIDs: [1], runningPIDs: [-1], now: 2).isEmpty)
    let quit = tracker.begin(target: .application(-1), processIdentifier: -1, subject: "App", now: 2)!
    precondition(!tracker.cancel(close)) // A late close callback cannot cancel a quit.
    precondition(tracker.pending.count == 1)
    precondition(tracker.reconcile(liveWindowIDs: [], runningPIDs: [-1], now: 2.4).isEmpty)
    precondition(tracker.reconcile(liveWindowIDs: [], runningPIDs: [-1], now: 5).isEmpty)
    let completed = tracker.reconcile(liveWindowIDs: [1], runningPIDs: [], now: 6)
    precondition(completed.count == 1 && completed[0].action.id == quit.id && completed[0].completed)
    precondition(tracker.suppresses(windowID: 1, processIdentifier: -1))
    _ = tracker.reconcile(liveWindowIDs: [1], runningPIDs: [-1], now: 8)
    precondition(tracker.suppresses(processIdentifier: -1))
    _ = tracker.reconcile(liveWindowIDs: [1], runningPIDs: [-1], now: 9.1)
    precondition(!tracker.suppresses(processIdentifier: -1))

    let retry = tracker.begin(target: .window(2), processIdentifier: -2, subject: "Unsaved", now: 10)!
    let timedOut = tracker.reconcile(liveWindowIDs: [2], runningPIDs: [-2], now: 22)
    precondition(timedOut.count == 1 && !timedOut[0].completed)
    precondition(!tracker.suppresses(windowID: 2, processIdentifier: -2))
    let newRequest = tracker.begin(target: .window(2), processIdentifier: -2, subject: "Unsaved", now: 23)!
    precondition(!tracker.cancel(retry))
    precondition(tracker.cancel(newRequest))
    precondition(tracker.pending.isEmpty)

    _ = tracker.begin(target: .window(10), processIdentifier: -10, subject: "A", now: 30)
    _ = tracker.begin(target: .window(11), processIdentifier: -11, subject: "B", now: 30)
    let first = tracker.reconcile(liveWindowIDs: [11], runningPIDs: [-10, -11], now: 31)
    precondition(first.count == 1 && tracker.pending.count == 1)
    precondition(tracker.suppresses(windowID: 10, processIdentifier: -10))
    precondition(!tracker.suppresses(windowID: 11, processIdentifier: -11))
    _ = tracker.begin(target: .application(-12), processIdentifier: -12, subject: "Slow App", now: 32)
    tracker.applicationDidTerminate(-12, now: 33)
    // The OS exit notification wins even if the running-app snapshot still lags.
    let notified = tracker.reconcile(liveWindowIDs: [11], runningPIDs: [-11, -12], now: 33)
    precondition(notified.count == 1 && notified[0].completed)
    print("Close/quit acknowledgment, slow exit, stale snapshots, timeout, retry and superseding checks passed.")
}

private func testReopenTracker() {
    var tracker = SwitcherReopenTracker()
    tracker.begin(-1, now: 0)
    precondition(tracker.hasUnresolvedReopen && tracker.needsRefresh && tracker.contains(-1))
    tracker.reconcile(windowsByPID: [:], runningPIDs: [-1], now: 0.1)
    precondition(tracker.hasUnresolvedReopen)
    tracker.reconcile(windowsByPID: [-1: [10]], runningPIDs: [-1], now: 0.2)
    precondition(!tracker.hasUnresolvedReopen && tracker.needsRefresh)
    tracker.reconcile(windowsByPID: [:], runningPIDs: [-1], now: 0.3)
    precondition(tracker.hasUnresolvedReopen && tracker.needsRefresh)
    tracker.reconcile(windowsByPID: [-1: [10]], runningPIDs: [-1], now: 0.4)
    tracker.reconcile(windowsByPID: [-1: [10]], runningPIDs: [-1], now: 0.5)
    precondition(!tracker.needsRefresh)
    tracker.begin(-1, now: 1)
    tracker.reconcile(windowsByPID: [:], runningPIDs: [-1], now: 4)
    precondition(!tracker.needsRefresh)
    tracker.begin(-1, now: 5)
    tracker.reconcile(windowsByPID: [:], runningPIDs: [], now: 5.1)
    precondition(!tracker.needsRefresh)

    var actions = SwitcherActionTracker()
    _ = actions.begin(target: .window(10), processIdentifier: -1, subject: "B", now: 0)
    _ = actions.begin(target: .window(20), processIdentifier: -2, subject: "C", now: 0)
    _ = actions.reconcile(liveWindowIDs: [], runningPIDs: [-1, -2], now: 1)
    actions.prepareForReopen(-1)
    precondition(!actions.suppresses(windowID: 10, processIdentifier: -1))
    precondition(actions.suppresses(windowID: 20, processIdentifier: -2))
    print("Reopen warm-up, stable snapshots, bounded retries and per-app suppression reset checks passed.")
}

private extension AeroSpaceClient {
    static func testReopenedWindowValidation() {
        let old = AppDelegate.fixtureWindow(801, pid: -8)
        let new = AppDelegate.fixtureWindow(802, pid: -8)
        let other = AppDelegate.fixtureWindow(803, pid: -9)
        let result = matchingLiveWindows([old, new, other], validating: [-8], liveWindowOwners: [802: -8])
        precondition(result.map(\.windowID) == [802, 803])
        precondition(matchingLiveWindows([new], validating: [-8], liveWindowOwners: [802: -99]).isEmpty)
        precondition(matchingLiveWindows([old], validating: [-8], liveWindowOwners: [801: -8]).count == 1)
        print("Reopened-window validation rejects stale IDs and accepts live reused IDs.")
    }
}

private extension AppDelegate {
    static func fixtureWindow(_ id: Int, pid: pid_t? = nil, workspace: String = "1") -> AeroWindow {
        AeroWindow(
            windowID: id, appName: "Fixture App", appBundleID: "com.apple.finder",
            appPID: pid ?? pid_t(-1000 - id), workspace: workspace,
            windowTitle: "Document \(id) — Project notes and important ending.txt",
            isFullscreen: false, windowLayout: "tiles", workspaceLayout: "h_tiles",
            workspaceIsFocused: false, workspaceIsVisible: true,
            monitorID: 1, monitorName: "Test display"
        )
    }

    static func fixture(windows: [AeroWindow], apps: [RunningApp] = []) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.allWindows = windows
        delegate.windowlessApps = apps
        delegate.orderedItems = delegate.makeOrderedItems()
        delegate.isLoaded = true
        delegate.trackedReleaseModifier = .command
        delegate.keepsPanelFrame = true
        delegate.targetScreen = NSScreen.main!
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 100, y: 100, width: 588, height: 360),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        panel.appearance = NSAppearance(named: .aqua)
        delegate.panel = panel
        panel.contentView = delegate.makeContentView(for: NSScreen.main!)
        panel.contentView?.layoutSubtreeIfNeeded()
        if !delegate.orderedItems.isEmpty { delegate.setSelectedIndex(0) }
        return delegate
    }

    func snapshot(_ windows: [AeroWindow], apps: [RunningApp] = [], runningPIDs: Set<pid_t>? = nil) {
        applyWindowSnapshot(
            windows: windows, workspaces: [], apps: apps,
            runningPIDs: runningPIDs ?? Set(windows.map(\.appPID) + apps.map(\.processIdentifier)),
            focusedID: nil, preserveSelection: true
        )
    }

    func startFixtureAction(_ target: SwitcherActionTarget, pid: pid_t, age: TimeInterval = 1) {
        let action = actionTracker.begin(
            target: target, processIdentifier: pid, subject: "Fixture App",
            now: ProcessInfo.processInfo.systemUptime - age
        )!
        beginActionFeedback(action)
        actionRefreshWorkItem?.cancel()
    }

    func viewportY(_ key: String) -> CGFloat {
        let scroll = switcherScrollView!
        let row = itemRows[key]!
        return row.convert(row.bounds, to: scroll.documentView!).minY - scroll.contentView.bounds.minY
    }

    static func testOpeningSelection() {
        let windows = (1...36).map { fixtureWindow($0, pid: -1) }
        let delegate = fixture(windows: windows)
        delegate.selectedIndex = nil
        delegate.isRefreshing = true
        delegate.refreshContent(preservingViewport: false)
        let hiddenPanel = delegate.panel!
        precondition(!hiddenPanel.isVisible && delegate.itemRows.values.allSatisfy { !$0.isSelected })

        // A second Tab before the focus query completes must queue against the
        // same panel. Select the exact focused window, not the app's first one.
        delegate.handleCycleRequest(direction: 1, tracking: .command, modifierIsPressed: true)
        precondition(delegate.panel === hiddenPanel && delegate.pendingCycleDelta == 1)
        precondition(delegate.prepareCachedSelection(focusedID: 20))
        precondition(!hiddenPanel.isVisible && delegate.isRefreshing)
        precondition(delegate.selectedItem?.key == "window:21")
        precondition(delegate.pendingCycleDelta == 0)
        let openingRow = delegate.itemRows["window:21"]!
        precondition(openingRow.isSelected)
        precondition(openingRow.layer?.backgroundColor == SwitcherStyle.accentColor.withAlphaComponent(0.18).cgColor)
        let scroll = delegate.switcherScrollView!
        let rowBounds = openingRow.convert(openingRow.bounds, to: scroll.documentView!)
        precondition(scroll.contentView.bounds.contains(rowBounds))

        // Content is already selected before attachment; rebuilding it cannot
        // expose a frame with plain rows followed by a separate blue highlight.
        let readyContent = delegate.makeContentView(for: NSScreen.main!)
        precondition(delegate.itemRows["window:21"]!.isSelected)
        hiddenPanel.contentView = readyContent
        readyContent.layoutSubtreeIfNeeded()

        delegate.handleCycleRequest(direction: 1, tracking: .command, modifierIsPressed: true)
        let retainedRow = delegate.itemRows["window:21"]!
        delegate.applyWindowSnapshot(windows: windows, workspaces: [], apps: [], runningPIDs: [-1],
            focusedID: 20, preserveSelection: true)
        precondition(delegate.itemRows["window:21"] === retainedRow)
        precondition(delegate.selectedItem?.key == "window:22")
        precondition(delegate.itemRows.values.filter(\.isSelected).count == 1)
        precondition(!retainedRow.isSelected)
        delegate.applyWindowSnapshot(windows: windows, workspaces: [], apps: [], runningPIDs: [-1],
            focusedID: 20, preserveSelection: true, forceRefresh: true)
        precondition(delegate.selectedItem?.key == "window:22")
        precondition(delegate.itemRows.values.filter(\.isSelected).count == 1)
        CATransaction.flush()
        precondition(delegate.itemRows.values.allSatisfy { $0.layer?.animation(forKey: "backgroundColor") == nil })

        // Do not guess from stale cache when focus belongs to a new window, or
        // an empty workspace. The first fresh list still arrives fully selected.
        let uncached = fixture(windows: [windows[0]])
        uncached.selectedIndex = nil
        uncached.refreshContent(preservingViewport: false)
        precondition(!uncached.prepareCachedSelection(focusedID: nil))
        precondition(!uncached.prepareCachedSelection(focusedID: 2))
        precondition(!uncached.panel!.isVisible && uncached.selectedIndex == nil)
        // An unrelated background refresh can supersede the opening query;
        // with no selected item yet, it must initialize from the fresh focus.
        uncached.applyWindowSnapshot(windows: Array(windows.prefix(2)), workspaces: [], apps: [],
            runningPIDs: [-1], focusedID: 2, preserveSelection: true)
        precondition(uncached.itemRows["window:2"]!.isSelected)
        precondition(uncached.itemRows.values.filter(\.isSelected).count == 1)

        let cold = fixture(windows: [])
        cold.isLoaded = false
        cold.applyWindowSnapshot(windows: windows, workspaces: [], apps: [], runningPIDs: [-1],
            focusedID: 36, preserveSelection: false)
        precondition(cold.itemRows["window:36"]!.isSelected)
        precondition(cold.itemRows.values.filter(\.isSelected).count == 1)

        // The brief focus-query phase owns its shortcuts even before showing:
        // Q/W cannot leak to the previously focused app, and digits stay queued.
        let awaiting = fixture(windows: windows)
        awaiting.selectedIndex = nil
        awaiting.isRefreshing = true
        awaiting.isAwaitingPresentation = true
        for code in [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_3] {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
            down.flags = .maskCommand
            precondition(awaiting.interceptSwitcherKeyEvent(type: .keyDown, event: down, pointerLocation: .zero))
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)!
            precondition(awaiting.interceptSwitcherKeyEvent(type: .keyUp, event: up, pointerLocation: .zero))
        }
        precondition(awaiting.actionTracker.pending.isEmpty && awaiting.pendingDirectSelectionIndex == 2)
        awaiting.isAwaitingPresentation = false // Keep the fixture off screen.
        precondition(awaiting.prepareCachedSelection(focusedID: 20))
        awaiting.applyWindowSnapshot(windows: windows, workspaces: [], apps: [], runningPIDs: [-1],
            focusedID: 20, preserveSelection: true)
        precondition(awaiting.selectedItem?.key == "window:3")
        print("Opening selection, exact focus, queued Tab, first-row paint, refresh stability and cold-cache checks passed.")
    }

    static func testReopenCatalog() {
        let a = fixtureWindow(501, pid: -501, workspace: "1")
        let b = fixtureWindow(502, pid: -502, workspace: "2")
        let appA = RunningApp(processIdentifier: a.appPID, appName: "Same app", bundleIdentifier: "fixture.shared")
        let appB = RunningApp(processIdentifier: b.appPID, appName: "Same app", bundleIdentifier: "fixture.shared")
        let apps = [appA, appB]
        let delegate = fixture(windows: [a, b])
        delegate.startFixtureAction(.window(b.windowID), pid: b.appPID)
        delegate.snapshot([a], apps: apps)
        precondition(delegate.windowlessApps.map(\.processIdentifier) == [b.appPID])
        // AeroSpace still reports the just-closed window. Classify from the final
        // visible window set, so B cannot vanish from both sections.
        delegate.snapshot([a, b], apps: apps)
        precondition(delegate.allWindows.map(\.windowID) == [a.windowID])
        precondition(delegate.windowlessApps.map(\.processIdentifier) == [b.appPID])
        delegate.setSelectedIndex(delegate.orderedItems.count - 1)
        let generation = delegate.loadGeneration
        delegate.beginReopeningApplication(b.appPID)
        delegate.reopenRefreshWorkItem?.cancel()
        precondition(delegate.loadGeneration > generation)
        precondition(!delegate.actionTracker.suppresses(windowID: b.windowID, processIdentifier: b.appPID))
        // A genuinely reopened window may reuse its former ID.
        delegate.snapshot([a, b], apps: apps)
        precondition(delegate.windowlessApps.isEmpty)
        precondition(delegate.selectedItem?.key == "window:502")
        precondition(delegate.orderedItems.filter { $0.key == "window:502" }.count == 1)

        // Warm the model while the switcher is hidden. The next invocation's
        // initial catalog already places B under its workspace, not OTHER APPS.
        let cached = AppDelegate()
        cached.allWindows = [a]
        cached.windowlessApps = [appB]
        cached.beginReopeningApplication(b.appPID)
        cached.reopenRefreshWorkItem?.cancel()
        cached.snapshot([a, b], apps: apps)
        cached.snapshot([a, b], apps: apps)
        precondition(cached.panel == nil && !cached.reopenTracker.needsRefresh)
        precondition(cached.makeOrderedItems().map(\.key) == ["window:501", "window:502"])

        // Very fast re-entry shows a loading state until the first useful window
        // snapshot; it never paints B at the bottom just before moving it.
        let fast = fixture(windows: [a], apps: [appB])
        fast.beginReopeningApplication(b.appPID)
        fast.reopenRefreshWorkItem?.cancel()
        fast.reopenPresentationDeadline = ProcessInfo.processInfo.systemUptime + 1
        fast.isLoaded = false
        fast.selectedIndex = nil
        fast.refreshContent(preservingViewport: false)
        let loadingView = fast.panel!.contentView
        fast.applyWindowSnapshot(windows: [a], workspaces: [], apps: apps,
            runningPIDs: [-501, -502], focusedID: nil, preserveSelection: false)
        precondition(!fast.isLoaded && fast.isRefreshing && fast.itemRows.isEmpty)
        precondition(fast.panel!.contentView === loadingView)
        fast.focusedApplicationPID = b.appPID
        fast.applyWindowSnapshot(windows: [a, b], workspaces: [], apps: apps,
            runningPIDs: [-501, -502], focusedID: nil, preserveSelection: false)
        precondition(fast.isLoaded && !fast.isRefreshing && fast.reopenPresentationDeadline == nil)
        precondition(fast.selectedItem?.key == "window:502")
        precondition(fast.itemRows["application:-502"] == nil && fast.itemRows["window:502"] != nil)

        // A slow/unsupported reopen still leaves an actionable app entry after
        // the bounded presentation wait. A query failure also exits loading.
        let slow = fixture(windows: [a], apps: [appB])
        slow.beginReopeningApplication(b.appPID)
        slow.reopenRefreshWorkItem?.cancel()
        slow.reopenPresentationDeadline = ProcessInfo.processInfo.systemUptime - 1
        slow.isLoaded = false
        slow.snapshot([a], apps: apps)
        precondition(slow.isLoaded && slow.windowlessApps.map(\.processIdentifier) == [b.appPID])
        precondition(slow.reopenTracker.contains(b.appPID))
        slow.isLoaded = false
        slow.reopenPresentationDeadline = ProcessInfo.processInfo.systemUptime - 1
        slow.finishReopenPresentationUsingCache()
        precondition(slow.isLoaded && !slow.isRefreshing && slow.reopenPresentationDeadline == nil)
        precondition(slow.itemRows["application:-502"] != nil)
        print("Atomic window/app catalog, hidden warm-up, fast re-entry, selection promotion and slow/error fallback checks passed.")
    }

    static func testContinuousHoverActions() {
        let originalDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var hoverDomain = originalDomain
        hoverDomain["hoveredItemActionPriority"] = true
        UserDefaults.standard.setVolatileDomain(hoverDomain, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalDomain, forName: UserDefaults.argumentDomain) }

        let windows = (1...36).map { fixtureWindow($0) }
        let delegate = fixture(windows: windows)
        // A visible, non-key panel outside every display models AeroSpace handing
        // focus to another app. No synthetic event is ever posted to the OS.
        delegate.panel!.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        delegate.panel!.orderFront(nil)
        delegate.panel!.resignKey()
        precondition(delegate.panel!.isVisible && !delegate.panel!.isKeyWindow)
        delegate.setSelectedIndex(18)
        delegate.setSelectedIndex(0, reveal: false) // Keyboard A, pointer over B.
        var requests: [Int] = []
        delegate.requestWindowClose = { id, completion in
            requests.append(id)
            completion(nil)
        }
        func pointer(_ key: String) -> NSPoint {
            let row = delegate.itemRows[key]!
            let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let clip = delegate.switcherScrollView!.contentView
            precondition(clip.bounds.contains(clip.convert(point, from: nil)))
            return delegate.panel!.convertPoint(toScreen: point)
        }
        func key(_ code: Int, down: Bool) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = down ? .maskCommand : []
            return event
        }
        func drainAction() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            delegate.actionRefreshWorkItem?.cancel()
        }
        func wheel(_ delta: Int32) {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                wheel1: delta, wheel2: 0, wheel3: 0)!
            event.flags = .maskCommand
            delegate.scrollSwitcher(with: NSEvent(cgEvent: event)!, in: delegate.switcherScrollView!)
        }
        let bPoint = pointer("window:19")
        delegate.hoveredItemKey = "window:1" // Stale hover notification must not win.
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyDown, event: key(kVK_ANSI_W, down: true), pointerLocation: bPoint))
        // The pointer can move again before queued work executes; target B is fixed.
        delegate.hoveredItemKey = "window:1"
        drainAction()
        precondition(requests == [19] && delegate.selectedItem?.key == "window:1")
        let repeatedW = key(kVK_ANSI_W, down: true)
        repeatedW.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyDown, event: repeatedW, pointerLocation: bPoint))
        drainAction()
        precondition(requests == [19])
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyUp, event: key(kVK_ANSI_W, down: false), pointerLocation: bPoint))
        RunLoop.current.run(until: Date().addingTimeInterval(0.27))
        let appB = RunningApp(processIdentifier: windows[18].appPID, appName: "B without windows", bundleIdentifier: "fixture.b")
        delegate.snapshot(windows.filter { $0.windowID != 19 }, apps: [appB])
        precondition(delegate.orderedItems.last?.key == "application:\(appB.processIdentifier)")
        let origin = delegate.switcherScrollView!.contentView.bounds.minY
        wheel(80)
        let up = delegate.switcherScrollView!.contentView.bounds.minY
        precondition(up < origin)
        wheel(-48)
        precondition(delegate.switcherScrollView!.contentView.bounds.minY > up)
        let wheelOrigin = delegate.switcherScrollView!.contentView.bounds.minY
        delegate.scrollSwitcher(byMagnification: -0.02)
        precondition(delegate.switcherScrollView!.contentView.bounds.minY > wheelOrigin)

        // Losing key status again must still route W to hovered C, never to A.
        delegate.panel!.resignKey()
        let cPoint = pointer("window:17")
        delegate.hoveredItemKey = "window:1"
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyDown, event: key(kVK_ANSI_W, down: true), pointerLocation: cPoint))
        drainAction()
        precondition(requests == [19, 17] && delegate.selectedItem?.key == "window:1")
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyUp, event: key(kVK_ANSI_W, down: false), pointerLocation: cPoint))
        RunLoop.current.run(until: Date().addingTimeInterval(0.27))
        let appC = RunningApp(processIdentifier: windows[16].appPID, appName: "C without windows", bundleIdentifier: "fixture.c")
        delegate.snapshot(windows.filter { ![19, 17].contains($0.windowID) }, apps: [appB, appC])
        let afterSecondClose = delegate.switcherScrollView!.contentView.bounds.minY
        wheel(48)
        precondition(delegate.switcherScrollView!.contentView.bounds.minY < afterSecondClose)

        // A captured item disappearing before execution must not fall back to A.
        let dPoint = pointer("window:16")
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyDown, event: key(kVK_ANSI_W, down: true), pointerLocation: dPoint))
        delegate.snapshot(windows.filter { ![19, 17, 16].contains($0.windowID) }, apps: [appB, appC])
        drainAction()
        precondition(requests == [19, 17] && delegate.selectedItem?.key == "window:1")

        // Q follows the same hover routing, including a windowless application.
        delegate.itemRows["application:\(appB.processIdentifier)"]!.scrollToVisible(
            delegate.itemRows["application:\(appB.processIdentifier)"]!.bounds
        )
        let appPoint = pointer("application:\(appB.processIdentifier)")
        let pendingQuit = delegate.actionTracker.begin(
            target: .application(appB.processIdentifier), processIdentifier: appB.processIdentifier,
            subject: appB.appName, now: ProcessInfo.processInfo.systemUptime
        )!
        delegate.hoveredItemKey = "window:1"
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyDown, event: key(kVK_ANSI_Q, down: true), pointerLocation: appPoint))
        drainAction()
        precondition(delegate.latestFeedbackActionID == pendingQuit.id)
        precondition(delegate.selectedItem?.key == "window:1" && requests == [19, 17])
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyUp, event: key(kVK_ANSI_Q, down: false), pointerLocation: appPoint))
        delegate.actionTracker.cancel(pendingQuit)

        // Consume the matching key-up even if the overlay was dismissed meanwhile.
        delegate.hideSwitcher()
        delegate.actionRefreshWorkItem?.cancel()
        precondition(delegate.interceptSwitcherKeyEvent(type: .keyUp, event: key(kVK_ANSI_W, down: false), pointerLocation: dPoint))
        precondition(!delegate.interceptSwitcherKeyEvent(type: .keyDown, event: key(kVK_ANSI_W, down: true), pointerLocation: dPoint))
        print("Non-key panel: hover B/W, windowless B, wheel/zoom scrolling, hover C/W, stale target and key-up routing checks passed.")
    }

    static func testInteraction() throws {
        let windows = (1...24).map { fixtureWindow($0) }
        let delegate = fixture(windows: windows)
        delegate.setSelectedIndex(17)
        let initialFrame = delegate.panel!.frame
        let selectedY = delegate.viewportY("window:18")
        delegate.startFixtureAction(.window(1), pid: windows[0].appPID)
        delegate.snapshot(Array(windows.dropFirst()))
        precondition(delegate.panel!.frame == initialFrame)
        precondition(delegate.selectedItem?.key == "window:18")
        precondition(abs(delegate.viewportY("window:18") - selectedY) < 1)
        precondition(delegate.itemRows["window:18"]!.isSelected)

        // At the bottom, removing a later row must not clamp the viewport upward.
        delegate.setSelectedIndex(delegate.orderedItems.count - 1)
        delegate.setSelectedIndex(20, reveal: false)
        let bottomKey = delegate.selectedItem!.key
        let bottomY = delegate.viewportY(bottomKey)
        delegate.startFixtureAction(.window(24), pid: windows[23].appPID)
        delegate.snapshot(Array(windows.dropFirst().dropLast()))
        precondition(abs(delegate.viewportY(bottomKey) - bottomY) < 1)
        precondition(delegate.panel!.frame == initialFrame)

        // An offscreen keyboard selection must not override a manually scrolled viewport.
        delegate.setSelectedIndex(0, reveal: false)
        let manualOffset = delegate.switcherScrollView!.contentView.bounds.minY
        let unchangedContent = delegate.panel!.contentView
        delegate.snapshot(Array(windows.dropFirst().dropLast()))
        precondition(delegate.panel!.contentView === unchangedContent)
        precondition(delegate.switcherScrollView!.contentView.bounds.minY == manualOffset)

        // Removing the selected last item clamps the index instead of wrapping to the top.
        let short = fixture(windows: Array(windows.prefix(3)))
        short.setSelectedIndex(2)
        short.startFixtureAction(.window(3), pid: windows[2].appPID)
        short.snapshot(Array(windows.prefix(2)))
        precondition(short.selectedItem?.key == "window:2")
        short.snapshot([])
        precondition(short.orderedItems.isEmpty && short.panel != nil)

        let appPID: pid_t = -777
        let slowWindows = [fixtureWindow(101, pid: appPID), fixtureWindow(102, pid: appPID)]
        let slow = fixture(windows: slowWindows + [windows[0]])
        slow.startFixtureAction(.application(appPID), pid: appPID, age: 3)
        let app = RunningApp(processIdentifier: appPID, appName: "Fixture App", bundleIdentifier: "fixture.app")
        slow.snapshot([windows[0]], apps: [app], runningPIDs: [appPID, windows[0].appPID])
        precondition(slow.allWindows.map(\.windowID) == [101, 102, 1])
        precondition(slow.windowlessApps.isEmpty)
        precondition(slow.itemRows["window:101"]?.pendingMessage != nil)
        precondition(!slow.isRefreshing)
        let pendingContent = slow.panel!.contentView
        slow.snapshot([windows[0]], apps: [app], runningPIDs: [appPID, windows[0].appPID])
        precondition(slow.panel!.contentView === pendingContent) // No repeated spinner reconstruction.
        slow.closeSelectedWindow() // Already quitting: feedback only, never issues a close.
        precondition(slow.actionTracker.pending.count == 1)
        precondition(slow.actionFeedback?.tone == .progress)
        slow.moveSelection(by: 1)
        precondition(slow.selectedItem?.key == "window:102")
        try slow.saveFixtureSnapshot("pending")
        slow.snapshot(slowWindows + [windows[0]], apps: [app], runningPIDs: [windows[0].appPID])
        precondition(slow.allWindows.map(\.windowID) == [1])
        precondition(slow.windowlessApps.isEmpty && slow.actionTracker.pending.isEmpty)
        precondition(slow.actionFeedback?.tone == .success)
        slow.snapshot(slowWindows + [windows[0]], apps: [app], runningPIDs: [appPID, windows[0].appPID])
        precondition(slow.allWindows.map(\.windowID) == [1] && slow.windowlessApps.isEmpty)
        try slow.saveFixtureSnapshot("success")

        let waiting = fixture(windows: slowWindows)
        waiting.startFixtureAction(.application(appPID), pid: appPID, age: 13)
        waiting.snapshot(slowWindows)
        precondition(waiting.actionTracker.pending.isEmpty)
        precondition(waiting.allWindows.count == 2)
        precondition(waiting.itemRows["window:101"]?.pendingMessage == nil)
        precondition(waiting.actionFeedback?.tone == .warning)
        try waiting.saveFixtureSnapshot("timeout")

        let windowless = fixture(windows: [], apps: [app])
        windowless.closeSelectedWindow()
        precondition(windowless.actionTracker.pending.isEmpty)
        precondition(windowless.actionFeedback?.tone == .neutral)
        precondition(windowless.actionFeedback?.message.contains("⌘Q") == true)
        precondition(windowless.selectedItem?.key == "application:-777")
        try windowless.saveFixtureSnapshot("no-windows")
        let unavailableShortcut = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "9", charactersIgnoringModifiers: "9",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_9)
        )!
        precondition(windowless.handleCommandSelectionShortcut(unavailableShortcut))
        precondition(windowless.actionFeedback?.message.contains("9") == true)
        precondition(windowless.selectedItem?.key == "application:-777")

        // Releasing Command after the final close must dismiss, not send reopen.
        let last = fixture(windows: [slowWindows[0]])
        last.startFixtureAction(.window(101), pid: appPID)
        last.snapshot([], apps: [app])
        precondition(last.selectedItem?.key == "application:-777")
        precondition(last.suppressedAutomaticActivationPID == appPID)
        last.commitSelectedWindow()
        precondition(last.panel == nil)
        let navigating = fixture(windows: [slowWindows[0]])
        navigating.startFixtureAction(.window(101), pid: appPID)
        navigating.snapshot([], apps: [app])
        navigating.moveSelection(by: 1)
        precondition(navigating.suppressedAutomaticActivationPID == nil)
        print("Native list anchoring, bottom deletion, selection, slow quit, stale data and visual-feedback checks passed.")
    }

    func saveFixtureSnapshot(_ name: String) throws {
        guard let flag = CommandLine.arguments.firstIndex(of: "--snapshot-dir"),
              CommandLine.arguments.indices.contains(flag + 1) else { return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel!.appearance = NSAppearance(named: appearance)
            let content = panel!.contentView!
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
                "\(CommandLine.arguments[flag + 1])/\(name)-\(appearance.rawValue).png"
            ))
        }
    }
}

testActionTracker()
testReopenTracker()
private let testApplication = NSApplication.shared
testApplication.setActivationPolicy(.prohibited)
UserDefaults.standard.setVolatileDomain([
    "layoutMode": "compact", "showEmptyWorkspaces": true,
    "hoveredItemActionPriority": false,
], forName: UserDefaults.argumentDomain)
try AppDelegate.testInteraction()
AppDelegate.testContinuousHoverActions()
AppDelegate.testReopenCatalog()
AppDelegate.testOpeningSelection()
AeroSpaceClient.testReopenedWindowValidation()
