import SwiftUI

// A vertical scroll view that keeps showing the same items when its width changes. Opening a side pane or resizing
// the window reflows an adaptive grid into a different number of columns; at an unchanged scroll offset that shows
// entirely different items. AnchoredScrollView remembers the first item whose top edge is in view and, after a
// reflow, scrolls so that item sits at the same distance from the top again. A focused item (the one whose details
// are open) takes priority: if any of it was on screen before the reflow, all of it is on screen after it.
//
// How it measures: one preference carries the content size, the scroll offset, the viewport height and the frames of
// the marked items (content coordinates), so every update sees one consistent snapshot. A width change restores the
// anchor taken from the last snapshot of the old width, using the snapshots of the new one.
//
// Constraints found by testing, which the restore is built around:
// - Keep width changes unanimated (see WorkshopView.content). During an animated resize SwiftUI lays the content out
//   at every intermediate width while the items glide to their new places, and scrollTo aims at where an item is
//   drawn at that moment, not where it ends up.
// - A lazy grid lays out only the items near the current offset, so after a reflow the anchor is often not laid out.
//   scrollTo on an item that is not laid out, called from the update that reflowed, is silently dropped; deferring
//   it to the next turn shows a few frames of the wrong items. So the restore always scrolls by an item that IS laid
//   out (by a unit point far outside 0...1 if need be) to a position extrapolated from the laid-out items and the
//   reading order, and corrects it once the real frames arrive. All of that lands before the next frame is drawn.

/// Vertical ScrollView that keeps the same items in view when the content reflows to a new width. Mark the items that
/// may anchor the position with `scrollAnchorItem(_:)` and list their ids in reading order in `order`;
/// `keepingVisible` names the item that must stay on screen.
struct AnchoredScrollView<ID: Hashable, Content: View>: View {
    let order: [ID]
    let keepingVisible: ID?
    @ViewBuilder let content: Content
    @State private var tracker = ScrollAnchorTracker<ID>()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ScrollAnchorLayout.Key.self, value: ScrollAnchorLayout(
                                contentSize: geometry.size,
                                offset: -geometry.frame(in: .named(ScrollAnchorLayout.viewportSpace)).minY))
                        }
                    }
                    .coordinateSpace(name: ScrollAnchorLayout.contentSpace)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ScrollAnchorLayout.Key.self,
                                           value: ScrollAnchorLayout(viewportHeight: geometry.size.height))
                }
            }
            .coordinateSpace(name: ScrollAnchorLayout.viewportSpace)
            .onPreferenceChange(ScrollAnchorLayout.Key.self) { [order, keepingVisible] layout in
                tracker.update(layout, order: order, focus: keepingVisible, proxy: proxy)
            }
        }
    }
}

extension View {
    /// Lets the enclosing AnchoredScrollView anchor its position on this item. `id` must be unique in the scroll view;
    /// it also becomes the item's explicit identity, which is what ScrollViewProxy.scrollTo finds.
    func scrollAnchorItem<ID: Hashable>(_ id: ID) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ScrollAnchorLayout.Key.self, value: ScrollAnchorLayout(
                    items: [AnyHashable(id): geometry.frame(in: .named(ScrollAnchorLayout.contentSpace))]))
            }
        }
        .id(id)
    }
}

/// One snapshot of the scroll view, assembled from several geometry readers.
private struct ScrollAnchorLayout: Equatable {
    static let contentSpace = "AnchoredScrollView.content"
    static let viewportSpace = "AnchoredScrollView.viewport"

    var contentSize: CGSize?
    var offset: CGFloat?            // viewport top, in content coordinates
    var viewportHeight: CGFloat?
    var items: [AnyHashable: CGRect] = [:]   // laid-out marked items only

    struct Key: PreferenceKey {
        static let defaultValue = ScrollAnchorLayout()

        static func reduce(value: inout ScrollAnchorLayout, nextValue: () -> ScrollAnchorLayout) {
            let next = nextValue()
            value.contentSize = next.contentSize ?? value.contentSize
            value.offset = next.offset ?? value.offset
            value.viewportHeight = next.viewportHeight ?? value.viewportHeight
            value.items.merge(next.items) { $1 }
        }
    }

    func frame<ID: Hashable>(of id: ID) -> CGRect? { items[AnyHashable(id)] }

    /// The scroll view stops between these viewport tops.
    var offsetRange: ClosedRange<CGFloat>? {
        guard let contentSize, let viewportHeight else { return nil }
        return 0...max(0, contentSize.height - viewportHeight)
    }

    /// Any part of the item is in view.
    func shows<ID: Hashable>(_ id: ID) -> Bool {
        guard let frame = frame(of: id), let offset, let viewportHeight else { return false }
        return frame.maxY > offset && frame.minY < offset + viewportHeight
    }
}

/// The frames of one snapshot's items: measured for the laid-out ones, extrapolated for the others from the rows of
/// the laid-out ones and the reading order. The grid fills rows left to right, so item `i` sits in row `i / columns`.
private struct ScrollAnchorPlacement<ID: Hashable> {
    private let layout: ScrollAnchorLayout
    private let laidOut: [(id: ID, frame: CGRect, index: Int)]
    private let index: [ID: Int]
    private let columns: Int
    private let rowPitch: CGFloat?

    init(layout: ScrollAnchorLayout, order: [ID]) {
        self.layout = layout
        let index = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.index = index
        laidOut = layout.items.compactMap { key, frame in
            guard let id = key.base as? ID, let position = index[id] else { return nil }
            return (id, frame, position)
        }
        columns = max(1, Set(laidOut.map { $0.frame.minX.rounded() }).count)
        // Row tops of the laid-out rows; rows of mixed heights center their items, so take each row's highest top.
        var tops: [Int: CGFloat] = [:]
        for item in laidOut { tops[item.index / columns] = min(tops[item.index / columns] ?? .infinity, item.frame.minY) }
        if let first = tops.keys.min(), let last = tops.keys.max(), last > first {
            rowPitch = (tops[last]! - tops[first]!) / CGFloat(last - first)
        } else {
            rowPitch = nil
        }
    }

    /// The item's frame; `exact` turns false when it had to be extrapolated or cannot be placed yet.
    func frame(of id: ID, exact: inout Bool) -> CGRect? {
        if let frame = layout.frame(of: id) { return frame }
        exact = false
        guard let position = index[id], let rowPitch,
              let nearest = laidOut.min(by: { abs($0.index - position) < abs($1.index - position) }) else { return nil }
        let rows = CGFloat(position / columns - nearest.index / columns)
        return nearest.frame.offsetBy(dx: 0, dy: rows * rowPitch)
    }

    /// The laid-out item to scroll by for a viewport top of `offset`. One that ends up fully in view keeps the unit
    /// point within 0...1, where scrollTo lands exactly. Outside that range it proved reliable only for items far from
    /// the target, which is all an estimate across a long reflow has to offer.
    func handle(for offset: CGFloat, viewportHeight: CGFloat) -> (id: ID, frame: CGRect)? {
        let inView = laidOut.filter { $0.frame.minY >= offset && $0.frame.maxY <= offset + viewportHeight }
        return (inView.isEmpty ? laidOut : inView)
            .min { abs($0.frame.minY - offset) < abs($1.frame.minY - offset) }
            .map { ($0.id, $0.frame) }
    }
}

/// Plain reference state: it changes on every scroll step, and none of it is drawn.
@MainActor
private final class ScrollAnchorTracker<ID: Hashable> {
    private struct Anchor {
        let id: ID
        let distance: CGFloat       // item top minus viewport top
    }

    /// What a width change has to bring back, kept until a snapshot has placed it from measured frames.
    private struct Restore {
        let anchor: Anchor?
        let focus: ID?              // only set when the focused item was in view before the reflow
        let since: TimeInterval     // system uptime of the latest width change
        var attempts = 0
    }

    /// Snapshots a restore may take to place and verify its items. Some arrive before the previous scroll has
    /// landed, and each estimate or late row shift costs one more.
    private static var maxAttempts: Int { 8 }
    /// Seconds after the latest width change in which a restore may still act.
    private static var maxRestoreTime: TimeInterval { 0.5 }
    /// Seconds to wait for the snapshot a restoring scroll should produce before scrolling again.
    private static var retryDelay: TimeInterval { 0.1 }

    private var last: ScrollAnchorLayout?   // latest snapshot of the current width
    private var anchor: Anchor?
    private var pending: Restore?
    private var settledOffset: CGFloat?     // where the last restore placed the view
    private var retry: DispatchWorkItem?

    func update(_ layout: ScrollAnchorLayout, order: [ID], focus: ID?, proxy: ScrollViewProxy) {
        guard let width = layout.contentSize?.width, let offset = layout.offset, layout.viewportHeight != nil else { return }
        retry?.cancel()
        if let previous = last, previous.contentSize?.width != width {
            pending = Restore(anchor: pending?.anchor ?? anchor,
                              focus: pending?.focus ?? focus.flatMap { previous.shows($0) ? $0 : nil },
                              since: ProcessInfo.processInfo.systemUptime)
        }
        last = layout
        expireRestore()
        if pending != nil {
            restore(in: layout, order: order, proxy: proxy)
            return
        }
        // Until the user scrolls away from where a restore placed the view, the anchor from before the reflow stays in
        // charge (as long as it is still listed): closing the detail pane then returns to exactly where its opening
        // started, even when the focused item moved the view, and a live window resize, which restores on every
        // step, cannot creep away through pixel rounding.
        if let settledOffset, abs(offset - settledOffset) <= 1, anchor.map({ order.contains($0.id) }) ?? true { return }
        settledOffset = nil
        anchor = Self.anchor(in: layout)
    }

    /// A restore that outlived its time must not act on a later, unrelated snapshot, such as the user scrolling.
    private func expireRestore() {
        if let since = pending?.since, ProcessInfo.processInfo.systemUptime - since > Self.maxRestoreTime { pending = nil }
    }

    /// The first item whose top edge is in view, else the item cut by the top edge. Nil at the very top of the
    /// content, which a reflow keeps by itself.
    private static func anchor(in layout: ScrollAnchorLayout) -> Anchor? {
        guard let offset = layout.offset, let viewportHeight = layout.viewportHeight, offset > 0.5 else { return nil }
        let inOrder = layout.items.compactMap { entry in (entry.key.base as? ID).map { (id: $0, frame: entry.value) } }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let bottom = offset + viewportHeight
        guard let item = inOrder.first(where: { $0.frame.minY >= offset - 0.5 && $0.frame.minY < bottom })
                ?? inOrder.first(where: { $0.frame.maxY > offset && $0.frame.minY < bottom }) else { return nil }
        return Anchor(id: item.id, distance: item.frame.minY - offset)
    }

    private func restore(in layout: ScrollAnchorLayout, order: [ID], proxy: ScrollViewProxy) {
        guard var target = pending, let offset = layout.offset, let viewportHeight = layout.viewportHeight else { return }
        let placement = ScrollAnchorPlacement(layout: layout, order: order)
        var exact = true
        var top: CGFloat?
        if let anchor = target.anchor, let frame = placement.frame(of: anchor.id, exact: &exact) {
            top = frame.minY - anchor.distance
        }
        if let focus = target.focus, let frame = placement.frame(of: focus, exact: &exact) {
            let current = top ?? offset
            if frame.minY < current || frame.height > viewportHeight {
                top = frame.minY
            } else if frame.maxY > current + viewportHeight {
                top = frame.maxY - viewportHeight
            }
        }
        // The ends of the content stop the scroll view short of some tops; a top it cannot reach is reached there.
        if let range = layout.offsetRange { top = top.map { min(max($0, range.lowerBound), range.upperBound) } }
        // Done once a snapshot shows everything in place from measured frames. Until then keep correcting: laying
        // out the rows around a new offset can still shift the items when those rows are taller than estimated.
        let placed = exact && top.map { abs($0 - offset) <= 0.5 } ?? exact
        target.attempts += 1
        pending = placed || target.attempts >= Self.maxAttempts ? nil : target
        settledOffset = placed ? top : nil
        guard !placed, let top, let handle = placement.handle(for: top, viewportHeight: viewportHeight) else { return }
        // scrollTo aligns the point at `unit` of the item with the point at `unit` of the viewport, so the item's top
        // lands unit * (viewport height - item height) below the viewport top. Solved for a viewport top of `top`.
        let slack = viewportHeight - handle.frame.height
        guard abs(slack) >= 1 else { return }
        proxy.scrollTo(handle.id, anchor: UnitPoint(x: 0, y: (handle.frame.minY - top) / slack))
        // A scroll issued as a live window resize ends can be dropped, and then no snapshot follows to correct it.
        // Without a newer snapshot, try again from this one; the tries count against the limits above.
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expireRestore()
            if self.pending != nil { self.restore(in: layout, order: order, proxy: proxy) }
        }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: retry)
    }
}
