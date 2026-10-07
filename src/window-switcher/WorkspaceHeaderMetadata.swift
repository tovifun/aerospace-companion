import Foundation

enum WorkspaceHeaderMetadata {
    static func statusSymbol(isFocused: Bool, isVisible: Bool) -> String? {
        isFocused ? "circle.fill" : (isVisible ? "circle" : nil)
    }

    static func layoutSymbol(_ layout: String?) -> String {
        switch layout?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "h_tiles": return "rectangle.split.2x1"
        case "v_tiles": return "rectangle.split.1x2"
        case "h_accordion", "v_accordion": return "rectangle.stack"
        default: return "questionmark"
        }
    }

    static func layoutRotation(_ layout: String?) -> CGFloat {
        layout?.trimmingCharacters(in: .whitespacesAndNewlines) == "h_accordion" ? 90 : 0
    }

    static func text(
        monitorID: Int,
        layout: String?,
        isFocused: Bool,
        isVisible: Bool,
        usesChinese: Bool
    ) -> String {
        var parts = [monitorID > 0 ? "D\(monitorID)" : "D?"]
        if isFocused {
            parts.append(usesChinese ? "当前" : "CURRENT")
        } else if isVisible {
            parts.append(usesChinese ? "可见" : "VISIBLE")
        }
        parts.append(layoutLabel(layout, usesChinese: usesChinese))
        return parts.joined(separator: " · ")
    }

    static func layoutLabel(_ layout: String?, usesChinese: Bool) -> String {
        switch layout?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "h_tiles": return usesChinese ? "横向平铺" : "Horizontal tiles"
        case "v_tiles": return usesChinese ? "纵向平铺" : "Vertical tiles"
        case "h_accordion": return usesChinese ? "横向手风琴" : "Horizontal accordion"
        case "v_accordion": return usesChinese ? "纵向手风琴" : "Vertical accordion"
        default: return usesChinese ? "布局未知" : "Unknown layout"
        }
    }
}
