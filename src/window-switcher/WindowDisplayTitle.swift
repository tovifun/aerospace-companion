import Foundation

enum WindowDisplayTitle {
    static func resolve(windowTitle: String, appName: String, fallback: String) -> String {
        // Installed web apps can expose an empty window title but a useful app name.
        for candidate in [windowTitle, appName] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }
}
