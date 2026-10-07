import AppKit

func item(_ id: Int, _ app: String, _ title: String, _ workspace: String, _ label: String = "") -> WindowSearchItem {
    WindowSearchItem(windowID: id, appName: app, bundleID: "test.app", title: title,
                     workspace: workspace, workspaceLabel: label, monitorName: "DELL P2723QE")
}
let windows = [
    item(1, "Zed", "aerospace-companion — main.swift", "3", "开发"),
    item(2, "Zed", "造梦次元 — README.md", "4", "终端 Agent"),
    item(3, "Chrome", "Café — Research", "2", "浏览器"),
    item(4, "Chrome", "\n  ", "2", "浏览器"),
]
var state = WindowSearchState()
state.replaceItems(windows)
precondition(state.matches == windows && state.selectedWindowID == 1)
state.search("zed MAIN")
precondition(state.matches.map(\.windowID) == [1])
state.search("ZED   造梦")
precondition(state.matches.map(\.windowID) == [2])
state.search("cafe")
precondition(state.matches.map(\.windowID) == [3])
state.search("ｃｈｒｏｍｅ")
precondition(state.matches.map(\.windowID) == [3, 4])
state.search("Agent dell")
precondition(state.matches.map(\.windowID) == [2])
state.search("2 Chrome")
precondition(state.matches.map(\.windowID) == [3, 4])
state.moveSelection(by: 1)
precondition(state.selectedWindowID == 4)
state.search("chrome")
precondition(state.selectedWindowID == 4)
state.replaceItems(Array(windows.dropLast()))
precondition(state.selectedWindowID == 3) // Selected window closed during search.
state.search("not-a-window")
precondition(state.matches.isEmpty && state.selectedItem == nil && state.selectedIndex == nil)
state.moveSelection(by: 1)
precondition(state.selectedItem == nil)
state.search(" \n\t")
precondition(state.matches.count == 3 && state.selectedWindowID == 1)
state.moveSelection(by: -99)
precondition(state.selectedWindowID == 1)
state.moveSelection(by: 99)
precondition(state.selectedWindowID == 3)
precondition(windows[3].displayTitle == "Chrome")
precondition(windows[1].detail.contains("终端 Agent"))
print("Window search: multi-field, Chinese, case/diacritics/width, empty results and selection checks passed.")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let controller = WindowSearchController()
let editor = NSTextView()
var activations = 0
controller.activateItem = { _, _ in activations += 1 }
precondition(controller.control(controller.searchField, textView: editor,
                                doCommandBy: #selector(NSResponder.insertNewline(_:))))
precondition(activations == 0) // Enter with no result never activates anything.
editor.setMarkedText("造", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:))] {
    precondition(!controller.control(controller.searchField, textView: editor, doCommandBy: command))
}
editor.unmarkText()
precondition(controller.control(controller.searchField, textView: editor,
                                doCommandBy: #selector(NSResponder.moveDown(_:))))
precondition(!controller.control(controller.searchField, textView: editor,
                                 doCommandBy: #selector(NSResponder.moveLeft(_:))))
let surface = controller.panel.contentView!
surface.layoutSubtreeIfNeeded()
precondition(surface.bounds.contains(controller.searchField.convert(controller.searchField.bounds, to: surface)))
print("Window search: native controls, empty Enter and input-method command handling checks passed.")
