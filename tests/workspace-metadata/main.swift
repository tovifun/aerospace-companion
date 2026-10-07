import Foundation
import AppKit

// Fractional trackpad and momentum deltas must not be rounded to wheel ticks.
for (current, delta, precise, expected) in [
    (100.0, -0.25, true, 100.25),
    (100.0, 0.25, true, 99.75),
    (100.0, -2.0, false, 164.0),
    (100.0, 2.0, false, 36.0),
    (100.0, 0.0, true, 100.0),
    (0.0, 20.0, true, 0.0),
    (590.0, -20.0, true, 600.0),
] {
    precondition(SwitcherScroll.targetY(
        currentY: current, deltaY: delta, precise: precise,
        documentHeight: 1000, viewportHeight: 400
    ) == expected)
}
precondition(SwitcherScroll.targetY(
    currentY: 0, deltaY: -10, precise: true,
    documentHeight: 100, viewportHeight: 400
) == 0)

final class ScrollTestDocument: NSView {
    override var isFlipped: Bool { true }
}
let scrollTestView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
scrollTestView.hasVerticalScroller = false
scrollTestView.documentView = ScrollTestDocument(
    frame: NSRect(x: 0, y: 0, width: 300, height: 1000)
)
SwitcherScroll.apply(deltaY: -12.5, precise: true, to: scrollTestView)
precondition(scrollTestView.contentView.bounds.origin.y == 12.5)
SwitcherScroll.apply(deltaY: -0.25, precise: true, to: scrollTestView)
precondition(scrollTestView.contentView.bounds.origin.y == 12.75)
SwitcherScroll.apply(deltaY: -1, precise: false, to: scrollTestView)
precondition(scrollTestView.contentView.bounds.origin.y == 44.75)
SwitcherScroll.apply(deltaY: 1000, precise: true, to: scrollTestView)
precondition(scrollTestView.contentView.bounds.origin.y == 0)
print("Trackpad, momentum, wheel and scrollbar-free clip scrolling checks passed.")

for (windowTitle, appName, expected) in [
    ("", "X", "X"),
    ("", "NTS Radio", "NTS Radio"),
    (" \n\t", " X ", "X"),
    ("Home / X", "X", "Home / X"),
    ("Untitled", "TextEdit", "Untitled"),
    ("Report", "", "Report"),
    ("", " \n", "无标题窗口"),
] {
    precondition(WindowDisplayTitle.resolve(
        windowTitle: windowTitle, appName: appName, fallback: "无标题窗口"
    ) == expected)
}
print("Window title fallback checks passed.")

precondition(WorkspaceHeaderMetadata.statusSymbol(isFocused: true, isVisible: true) == "circle.fill")
precondition(WorkspaceHeaderMetadata.statusSymbol(isFocused: false, isVisible: true) == "circle")
precondition(WorkspaceHeaderMetadata.statusSymbol(isFocused: false, isVisible: false) == nil)
precondition(WorkspaceHeaderMetadata.layoutSymbol("h_tiles") == "rectangle.split.2x1")
precondition(WorkspaceHeaderMetadata.layoutSymbol("v_tiles") == "rectangle.split.1x2")
precondition(WorkspaceHeaderMetadata.layoutSymbol("h_accordion") == "rectangle.stack")
precondition(WorkspaceHeaderMetadata.layoutSymbol("v_accordion") == "rectangle.stack")
precondition(WorkspaceHeaderMetadata.layoutRotation("h_accordion") == 90)
precondition(WorkspaceHeaderMetadata.layoutRotation("v_accordion") == 0)
for symbol in ["circle.fill", "circle", "rectangle.split.2x1", "rectangle.split.1x2", "rectangle.stack", "questionmark"] {
    precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
}

let layouts = [
    ("h_tiles", "横向平铺", "Horizontal tiles"),
    ("v_tiles", "纵向平铺", "Vertical tiles"),
    ("h_accordion", "横向手风琴", "Horizontal accordion"),
    ("v_accordion", "纵向手风琴", "Vertical accordion"),
]
for (raw, chinese, english) in layouts {
    precondition(WorkspaceHeaderMetadata.layoutLabel(raw, usesChinese: true) == chinese)
    precondition(WorkspaceHeaderMetadata.layoutLabel(raw, usesChinese: false) == english)
}
precondition(WorkspaceHeaderMetadata.text(
    monitorID: 2, layout: "h_accordion", isFocused: true, isVisible: true,
    usesChinese: true
) == "D2 · 当前 · 横向手风琴")
precondition(WorkspaceHeaderMetadata.text(
    monitorID: 3, layout: "v_tiles", isFocused: false, isVisible: true,
    usesChinese: false
) == "D3 · VISIBLE · Vertical tiles")
precondition(WorkspaceHeaderMetadata.text(
    monitorID: 1, layout: "h_tiles", isFocused: false, isVisible: false,
    usesChinese: true
) == "D1 · 横向平铺")
for raw in [nil, "", "new_layout"] as [String?] {
    precondition(WorkspaceHeaderMetadata.layoutLabel(raw, usesChinese: true) == "布局未知")
}
precondition(WorkspaceHeaderMetadata.text(
    monitorID: 0, layout: nil, isFocused: false, isVisible: false,
    usesChinese: false
) == "D? · Unknown layout")
print("Workspace header metadata checks passed.")

let workspaceJSON = """
[
  {"workspace":"1","workspace-is-focused":false,"workspace-is-visible":true,
   "monitor-id":1,"monitor-name":"Laptop","workspace-root-container-layout":"h_tiles"},
  {"workspace":"2","workspace-is-focused":false,"workspace-is-visible":false,
   "monitor-id":2,"monitor-name":"Work","workspace-root-container-layout":"h_accordion"},
  {"workspace":"9","workspace-is-focused":false,"workspace-is-visible":false,
   "monitor-id":2,"monitor-name":"Work"},
  {"workspace":"10","workspace-is-focused":true,"workspace-is-visible":true,
   "monitor-id":3,"monitor-name":"Third","workspace-root-container-layout":"v_tiles"},
  {"workspace":"A","workspace-is-focused":false,"workspace-is-visible":false,
   "monitor-id":2,"monitor-name":"Work","workspace-root-container-layout":"h_tiles"}
]
"""
let workspaces = try JSONDecoder().decode([AeroWorkspace].self, from: Data(workspaceJSON.utf8))
precondition(workspaces[3].isFocused && workspaces[3].monitorID == 3)
precondition(workspaces[2].layout == nil)
precondition(WorkspaceCatalog.orderedNames(
    occupied: ["2", "2", "12"], workspaces: workspaces
) == ["1", "2", "9", "10", "12", "A"])
// With no modifier-dependent input, both shortcuts share the visibility setting.
precondition(WorkspaceCatalog.orderedNames(
    occupied: [], workspaces: workspaces
) == ["1", "2", "9", "10", "A"])
// A missing workspace snapshot must not hide existing windows.
precondition(WorkspaceCatalog.orderedNames(
    occupied: ["2"], workspaces: []
) == ["2"])
// Opening the first window does not duplicate a workspace.
precondition(WorkspaceCatalog.orderedNames(
    occupied: ["9"], workspaces: workspaces
) == ["1", "2", "9", "10", "A"])
// Hiding empty workspaces removes only unoccupied entries, including a focused empty one.
precondition(WorkspaceCatalog.orderedNames(
    occupied: ["9", "2", "2", "12"], workspaces: workspaces, showEmptyWorkspaces: false
) == ["2", "9", "12"])
precondition(WorkspaceCatalog.orderedNames(
    occupied: [], workspaces: workspaces, showEmptyWorkspaces: false
).isEmpty)
precondition(WorkspaceCatalog.orderedNames(
    occupied: ["2"], workspaces: [], showEmptyWorkspaces: false
) == ["2"])
print("Empty workspace catalog checks passed.")
