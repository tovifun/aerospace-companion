import AppKit

let suiteName = "aerospace-companion-settings-test.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let preferences = SwitcherPreferences(defaults: defaults)
precondition(preferences.layoutMode == .standard && preferences.showEmptyWorkspaces)
defaults.set("unknown-mode", forKey: "layoutMode")
precondition(preferences.layoutMode == .standard)
preferences.restoreDefaults()

let normal = SwitcherLayoutMode.standard.metrics
let compact = SwitcherLayoutMode.compact.metrics
// Five occupied workspaces and two empty workspaces: compact avoids scrolling
// on a screen with 768pt of usable height (32pt screen inset, 64pt panel chrome).
let groups = [3, 3, 3, 3, 3, 0, 0]
precondition(normal.listHeight(workspaceWindowCounts: groups, windowlessAppCount: 0) == 703)
precondition(compact.listHeight(workspaceWindowCounts: groups, windowlessAppCount: 0) == 642)
precondition(normal.listHeight(workspaceWindowCounts: groups, windowlessAppCount: 0) + 64 > 736)
precondition(compact.listHeight(workspaceWindowCounts: groups, windowlessAppCount: 0) + 64 <= 736)
// Only visible groups contribute height; a windowless-app group still has its header.
precondition(compact.listHeight(workspaceWindowCounts: [1], windowlessAppCount: 2) == 134)
precondition(compact.listHeight(workspaceWindowCounts: [], windowlessAppCount: 0) == 0)
precondition(normal.iconSize < normal.rowHeight && compact.iconSize < compact.rowHeight)
print("Default and compact list sizing checks passed.")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = SettingsWindowController(preferences: preferences)
let contentView = controller.window!.contentView!
contentView.layoutSubtreeIfNeeded()

func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}
func control<T: NSControl>(_ identifier: String, in view: NSView) -> T {
    descendants(view).first { $0.identifier?.rawValue == identifier } as! T
}
let layout: NSSegmentedControl = control("layoutMode", in: contentView)
let visibility: NSSwitch = control("showEmptyWorkspaces", in: contentView)
precondition(layout.selectedSegment == 0 && visibility.state == .on)
var changes = 0
controller.onPreferencesChanged = { changes += 1 }
layout.selectedSegment = 1
precondition(layout.sendAction(layout.action, to: layout.target))
visibility.state = .off
precondition(visibility.sendAction(visibility.action, to: visibility.target))
precondition(changes == 2)
let reloaded = SwitcherPreferences(defaults: UserDefaults(suiteName: suiteName)!)
precondition(reloaded.layoutMode == .compact && !reloaded.showEmptyWorkspaces)
let reopened = SettingsWindowController(preferences: reloaded)
let reopenedLayout: NSSegmentedControl = control("layoutMode", in: reopened.window!.contentView!)
let reopenedVisibility: NSSwitch = control("showEmptyWorkspaces", in: reopened.window!.contentView!)
precondition(reopenedLayout.selectedSegment == 1 && reopenedVisibility.state == .off)

defaults.set(["1": "Custom"], forKey: "workspaceLabels")
defaults.set(true, forKey: "hoveredItemActionPriority")
let restore: NSButton = control("restoreDefaults", in: contentView)
restore.performClick(nil)
precondition(changes == 3)
precondition(preferences.layoutMode == .standard && preferences.showEmptyWorkspaces)
precondition(layout.selectedSegment == 0 && visibility.state == .on)
precondition(defaults.dictionary(forKey: "workspaceLabels")?["1"] as? String == "Custom")
precondition(defaults.bool(forKey: "hoveredItemActionPriority"))
precondition(contentView.bounds.contains(restore.convert(restore.bounds, to: contentView)))
print("Settings controls, persistence, reopening, and restore checks passed.")

// Optional local artifact for inspecting the actual AppKit controls without
// changing the running daemon's preferences or taking over the user's screen.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.indices.contains(flag + 1) {
    controller.window?.appearance = NSAppearance(named: .aqua)
    contentView.wantsLayer = true
    contentView.effectiveAppearance.performAsCurrentDrawingAppearance {
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
    contentView.layoutSubtreeIfNeeded()
    let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)!
    contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    )
}
