import AppKit

private final class WindowSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WindowSearchController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate {
    var loadItems: ((@escaping (Result<[WindowSearchItem], Error>) -> Void) -> Void)?
    var activateItem: ((WindowSearchItem, @escaping (Error?) -> Void) -> Void)?

    private(set) var state = WindowSearchState()
    let panel: NSPanel
    let searchField = NSSearchField()
    let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var generation = 0
    private var isLoading = false
    private var isActivating = false
    private var previousApplication: NSRunningApplication?
    private var icons: [String: NSImage] = [:]

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = WindowSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = localized("Search windows", "搜索窗口")
        panel.identifier = NSUserInterfaceItemIdentifier("windowSearchPanel")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        panel.contentView = surface

        let heading = NSTextField(labelWithString: localized("Search windows", "搜索窗口"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        searchField.identifier = NSUserInterfaceItemIdentifier("windowSearchQuery")
        searchField.placeholderString = localized("App, window title or workspace…", "应用、窗口标题或工作区…")
        searchField.setAccessibilityLabel(localized("Search windows", "搜索窗口"))
        searchField.font = .systemFont(ofSize: 17)
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self

        table.identifier = NSUserInterfaceItemIdentifier("windowSearchResults")
        table.setAccessibilityLabel(localized("Matching windows", "匹配的窗口"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedResult)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let help = NSTextField(labelWithString: localized("↑↓ Select   ↵ Switch   Esc Cancel", "↑↓ 选择   ↵ 切换   Esc 取消"))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        for view in [heading, searchField, scroll, emptyLabel, status, help] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            searchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
            help.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            help.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: help.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: help.leadingAnchor, constant: -12),
        ])
    }

    func show(on screen: NSScreen) {
        if isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
            return
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        state = WindowSearchState()
        searchField.stringValue = ""
        let frame = screen.visibleFrame
        let size = NSSize(width: min(640, frame.width - 32), height: min(460, frame.height - 32))
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                             width: size.width, height: size.height), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        refresh()
    }

    func hide(restoreFocus: Bool = false) {
        let previous = previousApplication
        previousApplication = nil
        generation += 1
        isLoading = false
        isActivating = false
        panel.orderOut(nil)
        if restoreFocus { previous?.activate(options: []) }
    }

    func refresh() {
        generation += 1
        let request = generation
        isLoading = true
        render()
        loadItems? { [weak self] result in
            guard let self, self.generation == request, self.isVisible else { return }
            self.isLoading = false
            switch result {
            case .success(let items):
                self.state.replaceItems(items)
                self.render()
            case .failure:
                self.state.replaceItems([])
                self.render()
                self.emptyLabel.stringValue = localized("Unable to load windows. Check AeroSpace and try again.", "无法读取窗口，请检查 AeroSpace 后重试。")
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        state.search(searchField.stringValue)
        render()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Let the input method handle candidate navigation/confirmation first.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            state.moveSelection(by: 1)
            selectCurrentRow()
        case #selector(NSResponder.moveUp(_:)):
            state.moveSelection(by: -1)
            selectCurrentRow()
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            hide(restoreFocus: true)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if isVisible && !isActivating { hide() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { state.matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = state.matches[row]
        let cell = NSTableCellView()
        cell.setAccessibilityLabel("\(item.displayTitle), \(item.detail)")
        let icon = NSImageView()
        if let cached = icons[item.bundleID] {
            icon.image = cached
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            icons[item.bundleID] = image
            icon.image = image
        }
        let title = NSTextField(labelWithString: item.displayTitle)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        cell.textField = title
        cell.imageView = icon
        for view in [icon, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        state.select(index: table.selectedRow)
    }

    @objc private func clickedResult() {
        guard table.clickedRow >= 0 else { return }
        state.select(index: table.clickedRow)
        activateSelection()
    }

    private func activateSelection() {
        guard !isLoading, !isActivating, let item = state.selectedItem else { return }
        isActivating = true
        let request = generation
        status.stringValue = localized("Switching…", "正在切换…")
        activateItem?(item) { [weak self] error in
            guard let self, self.generation == request else { return }
            self.isActivating = false
            if error == nil {
                self.hide()
            } else {
                // The selected window may have closed since the list was loaded.
                self.refresh()
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.searchField)
            }
        }
    }

    private func render() {
        table.reloadData()
        selectCurrentRow()
        emptyLabel.isHidden = !state.matches.isEmpty
        emptyLabel.stringValue = isLoading ? localized("Loading windows…", "正在读取窗口…")
            : localized("No matching windows", "没有匹配的窗口")
        let count = state.matches.count
        status.stringValue = isLoading ? localized("Loading…", "读取中…")
            : localized(count == 1 ? "1 window" : "\(count) windows", "\(count) 个窗口")
    }

    private func selectCurrentRow() {
        if let index = state.selectedIndex {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }
}
