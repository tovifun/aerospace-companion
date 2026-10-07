import Foundation

struct WorkspaceMonitorRoutingProfile: Codable {
    static let preferenceKey = "workspaceMonitorRoutingProfile"
    let primaryNames: [String]
    let workNames: [String]
    let extraNames: [String]

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let json = defaults.string(forKey: preferenceKey), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func destinations(for monitors: [RoutingMonitor]) -> [Int] {
        var available = monitors.sorted { $0.id < $1.id }
        var result: [Int] = []
        for names in [primaryNames, workNames, extraNames] {
            guard !available.isEmpty else { break }
            let match = names.lazy.compactMap { name in
                available.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }.first ?? 0
            result.append(available.remove(at: match).id)
        }
        return result
    }

    func destination(for workspace: String, monitors: [RoutingMonitor]) -> Int? {
        let roles = destinations(for: monitors)
        guard !roles.isEmpty else { return nil }
        if workspace == "1" { return roles[0] }
        if let number = Int(workspace), (2...8).contains(number) { return roles[min(1, roles.count - 1)] }
        return roles[min(2, roles.count - 1)]
    }
}

struct RoutingMonitor: Codable, Equatable {
    let id: Int
    let name: String
    enum CodingKeys: String, CodingKey {
        case id = "monitor-id"
        case name = "monitor-name"
    }
}

struct RoutingWorkspace: Codable {
    let workspace: String
    let monitorID: Int
    let isFocused: Bool
    enum CodingKeys: String, CodingKey {
        case workspace
        case monitorID = "monitor-id"
        case isFocused = "workspace-is-focused"
    }
}

// Opt-in personal policy. Poll off the main thread so hotplug and newly created
// workspaces are covered without enumerating a fixed upper workspace number.
final class WorkspaceMonitorRoutingController {
    private let profile: WorkspaceMonitorRoutingProfile
    private let run: ([String]) throws -> Data
    private let queue = DispatchQueue(label: "aerospace-companion.monitor-routing", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observedMonitors: [RoutingMonitor] = []
    private var stableObservations = 0

    init(profile: WorkspaceMonitorRoutingProfile, run: @escaping ([String]) throws -> Data) {
        self.profile = profile
        self.run = run
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            do { try self?.reconcile() }
            catch { NSLog("Workspace monitor routing: %@", error.localizedDescription) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }

    func reconcile() throws {
        do {
            let monitors = try currentMonitors()
            guard !monitors.isEmpty else { stableObservations = 0; return }
            if monitors != observedMonitors {
                observedMonitors = monitors
                stableObservations = 1
                return
            }
            stableObservations += 1
            guard stableObservations >= 2 else { return }
            let workspaces = try JSONDecoder().decode([RoutingWorkspace].self, from: run([
                "list-workspaces", "--all", "--json", "--format",
                "%{workspace} %{monitor-id} %{workspace-is-focused}",
            ]))
            // A cable may be disconnected during the workspace query. Verify
            // identities once more before using transient monitor sequence IDs.
            guard try currentMonitors() == monitors else { stableObservations = 0; return }
            for workspace in workspaces.sorted(by: { !$0.isFocused && $1.isFocused }) {
                guard let target = profile.destination(for: workspace.workspace, monitors: monitors),
                      target != workspace.monitorID else { continue }
                _ = try run(["move-workspace-to-monitor", "--workspace", workspace.workspace, "--", String(target)])
            }
        } catch {
            stableObservations = 0
            observedMonitors = []
            throw error
        }
    }

    private func currentMonitors() throws -> [RoutingMonitor] {
        try JSONDecoder().decode([RoutingMonitor].self, from: run(["list-monitors", "--json"]))
            .sorted { $0.id < $1.id }
    }
}
