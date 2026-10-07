import AppKit

enum SwitcherScroll {
    struct Anchor {
        let key: String
        let offset: CGFloat
    }

    struct Snapshot {
        let origin: NSPoint
        let anchors: [Anchor]
    }

    static func capture(in scrollView: NSScrollView, rows: [String: NSView], preferredKey: String?) -> Snapshot? {
        guard let document = scrollView.documentView else { return nil }
        let viewport = scrollView.contentView.bounds
        let visible = rows.map { key, row in (key, row.convert(row.bounds, to: document)) }
            .filter { $0.1.intersects(viewport) }
            .sorted { $0.1.minY < $1.1.minY }
        var anchors = visible.map { Anchor(key: $0.0, offset: $0.1.minY - viewport.minY) }
        if let index = anchors.firstIndex(where: { $0.key == preferredKey }) {
            let selected = anchors.remove(at: index)
            anchors.insert(selected, at: 0)
        }
        return Snapshot(origin: viewport.origin, anchors: anchors)
    }

    static func anchoredY(_ snapshot: Snapshot, in scrollView: NSScrollView, rows: [String: NSView]) -> CGFloat {
        guard let document = scrollView.documentView else { return snapshot.origin.y }
        for anchor in snapshot.anchors {
            guard let row = rows[anchor.key] else { continue }
            return max(0, row.convert(row.bounds, to: document).minY - anchor.offset)
        }
        return snapshot.origin.y
    }

    static func restore(_ snapshot: Snapshot, in scrollView: NSScrollView, rows: [String: NSView]) {
        guard let document = scrollView.documentView else { return }
        let y = anchoredY(snapshot, in: scrollView, rows: rows)
        let maximumY = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: snapshot.origin.x, y: min(maximumY, max(0, y))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    static func targetY(
        currentY: CGFloat, deltaY: CGFloat, precise: Bool,
        documentHeight: CGFloat, viewportHeight: CGFloat
    ) -> CGFloat {
        let maximumY = max(0, documentHeight - viewportHeight)
        // Trackpads (including momentum) already report pixel-sized deltas.
        // Traditional wheel events use line-sized deltas instead.
        let distance = deltaY * (precise ? 1 : 32)
        guard distance.isFinite else { return currentY }
        return min(maximumY, max(0, currentY - distance))
    }

    static func apply(deltaY: CGFloat, precise: Bool, to scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let origin = clipView.bounds.origin
        let y = targetY(
            currentY: origin.y, deltaY: deltaY, precise: precise,
            documentHeight: documentView.bounds.height,
            viewportHeight: clipView.bounds.height
        )
        guard y != origin.y else { return }
        clipView.scroll(to: NSPoint(x: origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }
}
