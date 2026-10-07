import Foundation

enum SwitcherLayoutMode: String {
    case standard
    case compact

    var metrics: SwitcherLayoutMetrics {
        switch self {
        case .standard:
            return SwitcherLayoutMetrics(
                rowHeight: 34, emptyWorkspaceRowHeight: 32,
                groupHeaderHeight: 21, groupSpacing: 4, iconSize: 28,
                rowTitleFontSize: 15, rowLeadingInset: 9, rowContentSpacing: 10,
                rowTrailingInset: 11, rowTextTrailingInset: 12,
                groupHeaderHorizontalInset: 10, groupHeaderBottomInset: 6
            )
        case .compact:
            return SwitcherLayoutMetrics(
                rowHeight: 32, emptyWorkspaceRowHeight: 30,
                groupHeaderHeight: 18, groupSpacing: 2, iconSize: 26,
                rowTitleFontSize: 14, rowLeadingInset: 3, rowContentSpacing: 8,
                rowTrailingInset: 6, rowTextTrailingInset: 6,
                groupHeaderHorizontalInset: 6, groupHeaderBottomInset: 3
            )
        }
    }
}

struct SwitcherLayoutMetrics {
    let rowHeight: CGFloat
    let emptyWorkspaceRowHeight: CGFloat
    let groupHeaderHeight: CGFloat
    let groupSpacing: CGFloat
    let iconSize: CGFloat
    let rowTitleFontSize: CGFloat
    let rowLeadingInset: CGFloat
    let rowContentSpacing: CGFloat
    let rowTrailingInset: CGFloat
    let rowTextTrailingInset: CGFloat
    let groupHeaderHorizontalInset: CGFloat
    let groupHeaderBottomInset: CGFloat
    let rowSpacing: CGFloat = 0

    func listHeight(workspaceWindowCounts: [Int], windowlessAppCount: Int) -> CGFloat {
        let workspaceHeight = workspaceWindowCounts.reduce(CGFloat.zero) { height, count in
            height + (count == 0
                ? emptyWorkspaceRowHeight
                : groupHeaderHeight + CGFloat(count) * (rowHeight + rowSpacing))
        }
        let appHeight = windowlessAppCount == 0 ? 0
            : groupHeaderHeight + CGFloat(windowlessAppCount) * (rowHeight + rowSpacing)
        let groupCount = workspaceWindowCounts.count + (windowlessAppCount == 0 ? 0 : 1)
        return workspaceHeight + appHeight + CGFloat(max(0, groupCount - 1)) * groupSpacing
    }
}

final class SwitcherPreferences {
    static let shared = SwitcherPreferences()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var layoutMode: SwitcherLayoutMode {
        get { SwitcherLayoutMode(rawValue: defaults.string(forKey: "layoutMode") ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "layoutMode") }
    }

    var showEmptyWorkspaces: Bool {
        get { (defaults.object(forKey: "showEmptyWorkspaces") as? Bool) ?? true }
        set { defaults.set(newValue, forKey: "showEmptyWorkspaces") }
    }

    func restoreDefaults() {
        defaults.removeObject(forKey: "layoutMode")
        defaults.removeObject(forKey: "showEmptyWorkspaces")
    }
}
