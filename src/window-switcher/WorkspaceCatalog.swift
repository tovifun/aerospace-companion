import Foundation

struct AeroWorkspace: Decodable, Equatable {
    let workspace: String
    let isFocused: Bool
    let isVisible: Bool
    let monitorID: Int
    let monitorName: String
    let layout: String?

    enum CodingKeys: String, CodingKey {
        case workspace
        case isFocused = "workspace-is-focused"
        case isVisible = "workspace-is-visible"
        case monitorID = "monitor-id"
        case monitorName = "monitor-name"
        case layout = "workspace-root-container-layout"
    }
}

enum WorkspaceCatalog {
    static func orderedNames(
        occupied: [String], workspaces: [AeroWorkspace], showEmptyWorkspaces: Bool = true
    ) -> [String] {
        var names = Set(occupied)
        // Both shortcuts use the same visibility preference and ordering.
        if showEmptyWorkspaces {
            names.formUnion(workspaces.map(\.workspace))
        }
        return names.sorted { left, right in
            if let l = Int(left), let r = Int(right), l != r { return l < r }
            if Int(left) != nil && Int(right) == nil { return true }
            if Int(right) != nil && Int(left) == nil { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
