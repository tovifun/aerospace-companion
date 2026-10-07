import Foundation

// Reopen Apple events are sent without waiting for the app to create a window.
// Warm the catalog briefly, and distinguish an unresolved reopen from a cache
// that is already safe to show on the next invocation.
struct SwitcherReopenTracker {
    private struct Entry {
        let startedAt: TimeInterval
        var observedWindowIDs: Set<Int> = []
    }

    private var entries: [pid_t: Entry] = [:]
    static let timeout: TimeInterval = 3
    static let presentationWait: TimeInterval = 0.25

    var needsRefresh: Bool { !entries.isEmpty }
    var hasUnresolvedReopen: Bool { entries.values.contains { $0.observedWindowIDs.isEmpty } }
    var processIdentifiers: Set<pid_t> { Set(entries.keys) }

    func contains(_ pid: pid_t) -> Bool { entries[pid] != nil }

    mutating func begin(_ pid: pid_t, now: TimeInterval) {
        entries[pid] = Entry(startedAt: now)
    }

    mutating func reconcile(windowsByPID: [pid_t: Set<Int>], runningPIDs: Set<pid_t>, now: TimeInterval) {
        for (pid, var entry) in entries {
            guard runningPIDs.contains(pid), now - entry.startedAt < Self.timeout else {
                entries.removeValue(forKey: pid)
                continue
            }
            let ids = windowsByPID[pid] ?? []
            if !ids.isEmpty && ids == entry.observedWindowIDs {
                // Two consecutive observations settle the reopen; a single
                // intermediate snapshot must not end the warm-up too early.
                entries.removeValue(forKey: pid)
            } else {
                entry.observedWindowIDs = ids
                entries[pid] = entry
            }
        }
    }
}
