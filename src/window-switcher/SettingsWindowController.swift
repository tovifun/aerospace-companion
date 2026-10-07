import AppKit

final class SettingsWindowController: NSWindowController {
    var onPreferencesChanged: (() -> Void)?

    private let preferences: SwitcherPreferences
    private let layoutControl = NSSegmentedControl(
        labels: [localized("Default", "默认"), localized("Compact", "紧凑")],
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let emptyWorkspacesSwitch = NSSwitch()

    init(preferences: SwitcherPreferences = .shared) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 496, height: 368),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = localized("AeroSpace Companion Settings", "AeroSpace Companion 设置")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        synchronizeControls()
        window.center()
        window.setFrameAutosaveName("CompanionSettings")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        synchronizeControls()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: localized("Window Switcher", "窗口切换器"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = detailLabel(localized(
            "Customize the list in Option-Tab and Command-Tab.",
            "自定义 Option-Tab 和 Command-Tab 中显示的列表。"
        ))

        layoutControl.identifier = NSUserInterfaceItemIdentifier("layoutMode")
        layoutControl.setAccessibilityLabel(localized("List layout", "列表布局"))
        layoutControl.target = self
        layoutControl.action = #selector(changeLayout(_:))
        layoutControl.setWidth(80, forSegment: 0)
        layoutControl.setWidth(80, forSegment: 1)

        emptyWorkspacesSwitch.identifier = NSUserInterfaceItemIdentifier("showEmptyWorkspaces")
        emptyWorkspacesSwitch.setAccessibilityLabel(localized("Show empty workspaces", "显示空工作区"))
        emptyWorkspacesSwitch.target = self
        emptyWorkspacesSwitch.action = #selector(changeEmptyWorkspaces(_:))

        let layoutGroup = preferenceGroup(
            title: localized("List layout", "列表布局"),
            detail: localized(
                "Compact uses smaller rows, icons, and group spacing to fit more items on screen.",
                "紧凑布局缩小行高、图标和分组间距，让屏幕容纳更多项目。"
            ), control: layoutControl
        )
        let visibilityGroup = preferenceGroup(
            title: localized("Show empty workspaces", "显示空工作区"),
            detail: localized(
                "Include workspaces with no windows so you can switch directly to them.",
                "在列表中保留没有窗口的工作区，可直接切换进入。"
            ), control: emptyWorkspacesSwitch
        )
        let savedHint = detailLabel(localized(
            "Changes are saved automatically and used the next time you open the switcher.",
            "更改会自动保存，下次打开切换器时生效。"
        ))
        let restoreButton = NSButton(
            title: localized("Restore Defaults", "恢复默认设置"),
            target: self, action: #selector(restoreDefaults)
        )
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.identifier = NSUserInterfaceItemIdentifier("restoreDefaults")

        for view in [title, subtitle, layoutGroup, visibilityGroup, savedHint, restoreButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            layoutGroup.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            layoutGroup.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor),
            layoutGroup.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            visibilityGroup.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            visibilityGroup.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor),
            visibilityGroup.topAnchor.constraint(equalTo: layoutGroup.bottomAnchor, constant: 12),
            savedHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            savedHint.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor),
            savedHint.topAnchor.constraint(equalTo: visibilityGroup.bottomAnchor, constant: 14),
            restoreButton.trailingAnchor.constraint(equalTo: subtitle.trailingAnchor),
            restoreButton.topAnchor.constraint(equalTo: savedHint.bottomAnchor, constant: 12),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
        ])
    }

    private func preferenceGroup(title: String, detail: String, control: NSControl) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 8
        box.contentViewMargins = .zero
        guard let content = box.contentView else { return box }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let description = detailLabel(detail)
        for view in [label, description, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 80),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            control.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            description.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            description.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            description.topAnchor.constraint(equalTo: control.bottomAnchor, constant: 8),
            description.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -10),
        ])
        return box
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func synchronizeControls() {
        layoutControl.selectedSegment = preferences.layoutMode == .compact ? 1 : 0
        emptyWorkspacesSwitch.state = preferences.showEmptyWorkspaces ? .on : .off
    }

    @objc private func changeLayout(_ sender: NSSegmentedControl) {
        preferences.layoutMode = sender.selectedSegment == 1 ? .compact : .standard
        onPreferencesChanged?()
    }

    @objc private func changeEmptyWorkspaces(_ sender: NSSwitch) {
        preferences.showEmptyWorkspaces = sender.state == .on
        onPreferencesChanged?()
    }

    @objc private func restoreDefaults() {
        preferences.restoreDefaults()
        synchronizeControls()
        onPreferencesChanged?()
    }
}
