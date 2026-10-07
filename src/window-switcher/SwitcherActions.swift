import Foundation

enum SwitcherActionTarget: Hashable {
    case window(Int)
    case application(pid_t)
}

struct PendingSwitcherAction {
    let id = UUID()
    let target: SwitcherActionTarget
    let processIdentifier: pid_t
    let subject: String
    let startedAt: TimeInterval

    var isQuit: Bool {
        if case .application = target { return true }
        return false
    }
}

struct SwitcherActionResolution {
    let action: PendingSwitcherAction
    let completed: Bool
}

// A successful command only acknowledges a request. Keep the item until the
// window disappears or the process exits, including while a save dialog is open.
struct SwitcherActionTracker {
    private(set) var pending: [SwitcherActionTarget: PendingSwitcherAction] = [:]
    private var removedWindows: [Int: (processIdentifier: pid_t, expiresAt: TimeInterval)] = [:]
    private var removedApplications: [pid_t: TimeInterval] = [:]
    static let waitingDelay: TimeInterval = 2
    static let timeout: TimeInterval = 12

    mutating func begin(
        target: SwitcherActionTarget, processIdentifier: pid_t,
        subject: String, now: TimeInterval
    ) -> PendingSwitcherAction? {
        guard pending[target] == nil,
              pending[.application(processIdentifier)] == nil else { return nil }
        if case .application = target {
            // Quitting supersedes outstanding closes for the same process.
            pending = pending.filter { $0.value.processIdentifier != processIdentifier }
        }
        let action = PendingSwitcherAction(
            target: target, processIdentifier: processIdentifier,
            subject: subject, startedAt: now
        )
        pending[target] = action
        return action
    }

    @discardableResult
    mutating func cancel(_ action: PendingSwitcherAction) -> Bool {
        guard pending[action.target]?.id == action.id else { return false }
        pending.removeValue(forKey: action.target)
        return true
    }

    func action(windowID: Int? = nil, processIdentifier: pid_t) -> PendingSwitcherAction? {
        pending[.application(processIdentifier)] ?? windowID.flatMap { pending[.window($0)] }
    }

    func suppresses(windowID: Int, processIdentifier: pid_t) -> Bool {
        removedWindows[windowID] != nil || suppresses(processIdentifier: processIdentifier)
    }

    func suppresses(processIdentifier: pid_t) -> Bool {
        removedApplications[processIdentifier] != nil
    }

    mutating func applicationDidTerminate(_ processIdentifier: pid_t, now: TimeInterval) {
        removedApplications[processIdentifier] = now + 3
    }

    mutating func prepareForReopen(_ processIdentifier: pid_t) {
        // Some apps reuse a window identity. An explicit reopen supersedes the
        // brief suppression of that app's previously closed windows.
        removedWindows = removedWindows.filter { $0.value.processIdentifier != processIdentifier }
        removedApplications.removeValue(forKey: processIdentifier)
    }

    mutating func reconcile(
        liveWindowIDs: Set<Int>?, runningPIDs: Set<pid_t>, now: TimeInterval
    ) -> [SwitcherActionResolution] {
        removedWindows = removedWindows.filter { $0.value.expiresAt > now }
        removedApplications = removedApplications.filter { $0.value > now }
        var resolutions: [SwitcherActionResolution] = []
        for action in pending.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            let age = now - action.startedAt
            let disappeared: Bool
            switch action.target {
            case .window(let id):
                disappeared = liveWindowIDs.map { !$0.contains(id) } ?? false
            case .application(let pid):
                disappeared = !runningPIDs.contains(pid) || removedApplications[pid] != nil
            }
            // Give immediate feedback a chance to render, even for very fast apps.
            let completed = disappeared && age >= 0.25
            guard completed || age >= Self.timeout else { continue }
            pending.removeValue(forKey: action.target)
            if completed {
                // Briefly reject lagging AeroSpace snapshots after confirmation.
                switch action.target {
                case .window(let id): removedWindows[id] = (action.processIdentifier, now + 3)
                case .application(let pid): removedApplications[pid] = now + 3
                }
            }
            resolutions.append(SwitcherActionResolution(action: action, completed: completed))
        }
        return resolutions
    }
}
