import Foundation

let profile = WorkspaceMonitorRoutingProfile(
    primaryNames: ["Built-in Retina Display"],
    workNames: ["DELL P2723QE", "KOIOS K2721UD"],
    extraNames: ["Portrait"]
)
let laptop = RoutingMonitor(id: 1, name: "Built-in Retina Display")
let work = RoutingMonitor(id: 2, name: "KOIOS K2721UD")
let portrait = RoutingMonitor(id: 3, name: "Portrait")
for name in ["1", "2", "8", "9", "10", "12", "101", "notes"] {
    precondition(profile.destination(for: name, monitors: [laptop]) == 1)
    precondition(profile.destination(for: name, monitors: [laptop, work]) == (name == "1" ? 1 : 2))
    let expected = name == "1" ? 1 : ((Int(name).map { (2...8).contains($0) } ?? false) ? 2 : 3)
    precondition(profile.destination(for: name, monitors: [laptop, work, portrait]) == expected)
}
let reordered = [RoutingMonitor(id: 3, name: laptop.name), RoutingMonitor(id: 1, name: work.name),
                 RoutingMonitor(id: 2, name: portrait.name)]
precondition(profile.destination(for: "1", monitors: reordered) == 3)
precondition(profile.destination(for: "8", monitors: reordered) == 1)
precondition(profile.destination(for: "99", monitors: reordered) == 2)
precondition(profile.destination(for: "1", monitors: [work, portrait]) == 2)
precondition(profile.destination(for: "9", monitors: [work, portrait]) == 3)
precondition(profile.destination(for: "9", monitors: []) == nil)

var monitors = [laptop, work]
var workspaces = [RoutingWorkspace(workspace: "1", monitorID: 1, isFocused: false),
                  RoutingWorkspace(workspace: "2", monitorID: 1, isFocused: true),
                  RoutingWorkspace(workspace: "12", monitorID: 1, isFocused: false)]
var moved: [String] = []
var disconnectDuringQuery = false
let controller = WorkspaceMonitorRoutingController(profile: profile) { arguments in
    switch arguments[0] {
    case "list-monitors": return try JSONEncoder().encode(monitors)
    case "list-workspaces":
        if disconnectDuringQuery { monitors = [laptop] }
        return try JSONEncoder().encode(workspaces)
    case "move-workspace-to-monitor":
        let name = arguments[2], target = Int(arguments[4])!
        moved.append(name)
        workspaces = workspaces.map {
            RoutingWorkspace(workspace: $0.workspace, monitorID: $0.workspace == name ? target : $0.monitorID,
                             isFocused: $0.isFocused)
        }
        return Data()
    default: preconditionFailure("Unexpected command")
    }
}
try controller.reconcile()
precondition(moved.isEmpty) // Wait for two stable monitor observations.
try controller.reconcile()
precondition(moved == ["12", "2"]) // Focused workspace is moved last.
try controller.reconcile()
precondition(moved.count == 2) // No redundant moves once positioned correctly.
workspaces.append(RoutingWorkspace(workspace: "12345", monitorID: 1, isFocused: false))
try controller.reconcile()
precondition(moved.last == "12345") // Newly created workspaces have no upper limit.
monitors = [laptop, work, portrait]
try controller.reconcile()
precondition(moved.count == 3)
try controller.reconcile()
precondition(workspaces.first { $0.workspace == "12" }!.monitorID == 3)
precondition(workspaces.first { $0.workspace == "12345" }!.monitorID == 3)
let beforeDisconnect = moved.count
disconnectDuringQuery = true
try controller.reconcile()
precondition(moved.count == beforeDisconnect) // No moves using stale display IDs.
disconnectDuringQuery = false
try controller.reconcile()
try controller.reconcile()
precondition(workspaces.allSatisfy { $0.monitorID == 1 })
print("Monitor routing: 1/2/3 screens, device identities, lid closed, unlimited/new workspaces, stable hotplug and idempotence passed.")
