import Foundation

struct WindowSearchItem: Equatable {
    let windowID: Int
    let appName: String
    let bundleID: String
    let title: String
    let workspace: String
    let workspaceLabel: String
    let monitorName: String

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
    }

    var detail: String {
        let workspaceTitle = workspaceLabel.isEmpty ? workspace : "\(workspace) · \(workspaceLabel)"
        return [appName, workspaceTitle, monitorName].filter { !$0.isEmpty }.joined(separator: "  —  ")
    }
}

struct WindowSearchState {
    private(set) var items: [WindowSearchItem] = []
    private(set) var matches: [WindowSearchItem] = []
    private(set) var query = ""
    private(set) var selectedWindowID: Int?

    var selectedIndex: Int? { matches.firstIndex { $0.windowID == selectedWindowID } }
    var selectedItem: WindowSearchItem? { selectedIndex.map { matches[$0] } }

    mutating func replaceItems(_ items: [WindowSearchItem]) {
        self.items = items
        filter()
    }

    mutating func search(_ query: String) {
        self.query = query
        filter()
    }

    mutating func select(index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedWindowID = matches[index].windowID
    }

    mutating func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        select(index: max(0, min(matches.count - 1, (selectedIndex ?? 0) + delta)))
    }

    private mutating func filter() {
        // Every word must match, but words can match different fields. Keep
        // source order stable so equal matches never jump while typing.
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        matches = items.filter { item in
            let fields = [item.appName, item.title, item.workspace, item.workspaceLabel, item.monitorName]
            return words.allSatisfy { word in
                fields.contains { field in
                    field.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
                }
            }
        }
        if !matches.contains(where: { $0.windowID == selectedWindowID }) {
            selectedWindowID = matches.first?.windowID
        }
    }
}
