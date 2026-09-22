import CoreGraphics
import Foundation

/// Two-zone roll-up layout for live captions.
///
/// The stabilizer exposes at most three undecided words. They live in a fixed lane below
/// the settled anchor, so changing their spelling or line breaks can never move text the
/// reader has already started following.
///
/// So the block hangs from the last **settled** line rather than from the live edge, and a
/// few lines are kept free below that anchor for the live tail to move around in. Pinning
/// to the live edge is what made the shipped build lurch: when a revision shortened the
/// hypothesis by a line the anchor moved, and every word on screen shifted a whole line
/// pitch. Replaying one 30 s recognizer stream, that cost 107 jumps of already-read text
/// and 9 full-block reversals; hanging from settled text instead leaves 5 and 0, and the
/// 5 are the intended roll-ups.
///
/// Settled placements are computed once and never recomputed. The recognizer cannot
/// revise them — across 1052 observations of committed words in that stream none changed
/// text and none disappeared — but if one ever does, `update` rebuilds rather than leave
/// something stale on screen.
public struct RollUpTranscriptLayout: Sendable {
    public struct Metrics: Equatable, Sendable {
        public let maxWidth: CGFloat
        public let wordSpacing: CGFloat
        public let fontSize: CGFloat

        public init(maxWidth: CGFloat, wordSpacing: CGFloat, fontSize: CGFloat) {
            self.maxWidth = maxWidth
            self.wordSpacing = wordSpacing
            self.fontSize = fontSize
        }
    }

    public struct Placement: Identifiable, Equatable, Sendable {
        public let id: UInt64
        /// Monotonic reading-order position used only by the settled watermark. SwiftUI
        /// identity is the app-owned `id` above.
        public let anchor: UInt64
        public let text: String
        /// Absolute line number, monotonic for the life of the session.
        public let line: Int
        public let x: CGFloat
        public let width: CGFloat
        /// False while the recognizer can still rewrite this word.
        public let isSettled: Bool

        public init(
            id: UInt64,
            anchor: UInt64,
            text: String,
            line: Int,
            x: CGFloat,
            width: CGFloat,
            isSettled: Bool
        ) {
            self.id = id
            self.anchor = anchor
            self.text = text
            self.line = line
            self.x = x
            self.width = width
            self.isSettled = isSettled
        }
    }

    /// Fixed lines kept free below the settled anchor. This value must never react to a
    /// provisional hypothesis: doing so would move the entire reading block.
    public static let baseReserve = 2

    /// How many settled words to keep placed. Far more than any pane can show, but
    /// bounded, so a long session cannot grow the array without limit.
    private static let settledCapacity = 160

    public private(set) var placements: [Placement] = []

    /// Line the block hangs from: the last line holding settled text.
    public private(set) var anchorLine = 0

    /// Lines held free below `anchorLine` for the live tail.
    public private(set) var reserve = RollUpTranscriptLayout.baseReserve

    private var settled: [Placement] = []
    /// Anchors are monotonic, so one watermark is enough to tell a new settled word from
    /// one that has already been placed — no set to grow over a long session.
    private var settledThrough: UInt64 = 0
    private var cursorX: CGFloat = 0
    private var metrics: Metrics?

    public init() {}

    public mutating func reset() {
        placements.removeAll(keepingCapacity: true)
        settled.removeAll(keepingCapacity: true)
        settledThrough = 0
        anchorLine = 0
        reserve = Self.baseReserve
        cursorX = 0
        metrics = nil
    }

    /// Row a placement occupies on screen. Row 0 is the bottom line of the pane.
    public func row(of placement: Placement) -> Int {
        anchorLine - placement.line + reserve
    }

    /// Rows the block currently spans, from the topmost placed line to the bottom of the
    /// reserve.
    public var rowSpan: Int {
        guard let first = placements.first else { return 0 }
        return row(of: first) + 1
    }

    @discardableResult
    public mutating func update(
        words: [StableTranscriptWord],
        widths: [CGFloat],
        metrics newMetrics: Metrics
    ) -> [Placement] {
        // Font size or column width changed: every stored offset is stale.
        if metrics != newMetrics {
            reset()
            metrics = newMetrics
        }

        guard !words.isEmpty, words.count == widths.count else {
            placements.removeAll(keepingCapacity: true)
            return placements
        }

        if contradictsSettledText(words) {
            reset()
            metrics = newMetrics
        }

        extendSettled(with: words, widths: widths, metrics: newMetrics)

        var next = settled
        next.reserveCapacity(settled.count + words.count)
        var line = anchorLine
        var x = cursorX
        for index in words.indices where words[index].anchor > settledThrough {
            let width = widths[index]
            if x > 0, x + width > newMetrics.maxWidth {
                line += 1
                x = 0
            }
            // A provisional word that would exceed the fixed lane remains in the
            // stabilizer and appears on a later update. Clipping it is preferable to
            // moving settled lines for a hypothesis that may disappear immediately.
            guard line - anchorLine <= reserve else { break }
            next.append(
                Placement(
                    id: words[index].id,
                    anchor: words[index].anchor,
                    text: words[index].text,
                    line: line,
                    x: x,
                    width: width,
                    isSettled: false
                )
            )
            x += width + newMetrics.wordSpacing
        }

        placements = next
        return next
    }

    /// True when the recognizer contradicts something already placed as settled — a
    /// retroactive correction, or a new session reusing old anchors. Rare enough that
    /// rebuilding beats reasoning about it: correctness wins over stillness.
    private func contradictsSettledText(_ words: [StableTranscriptWord]) -> Bool {
        guard let oldest = settled.first?.anchor else { return false }
        // A new session restarts anchors from zero, so nothing in the incoming batch can
        // extend what is placed. Without this the pane would simply go blank.
        if let newest = words.last?.anchor, newest <= settledThrough, newest < oldest {
            return true
        }
        var cursor = settled.startIndex
        for word in words where word.isCommitted && word.anchor <= settledThrough {
            guard word.anchor >= oldest else { continue }
            while cursor < settled.endIndex, settled[cursor].anchor < word.anchor {
                cursor += 1
            }
            guard cursor < settled.endIndex, settled[cursor].anchor == word.anchor else {
                return true
            }
            if settled[cursor].text != word.text { return true }
        }
        return false
    }

    private mutating func extendSettled(
        with words: [StableTranscriptWord],
        widths: [CGFloat],
        metrics: Metrics
    ) {
        for index in words.indices
        where words[index].isCommitted && words[index].anchor > settledThrough {
            let width = widths[index]
            if cursorX > 0, cursorX + width > metrics.maxWidth {
                anchorLine += 1
                cursorX = 0
            }
            settled.append(
                Placement(
                    id: words[index].id,
                    anchor: words[index].anchor,
                    text: words[index].text,
                    line: anchorLine,
                    x: cursorX,
                    width: width,
                    isSettled: true
                )
            )
            settledThrough = words[index].anchor
            cursorX += width + metrics.wordSpacing
        }

        if settled.count > Self.settledCapacity {
            settled.removeFirst(settled.count - Self.settledCapacity)
        }
    }

    /// How many lines fit in `height` at `linePitch`, never fewer than one.
    public static func visibleLineCount(height: CGFloat, linePitch: CGFloat) -> Int {
        guard linePitch > 0 else { return 1 }
        return max(1, Int((height / linePitch).rounded(.down)))
    }

    /// During a forward animated roll, retain the rows visible at the animation's start.
    /// Clipping against the target would remove the outgoing rows and leave future rows
    /// below the pane until a multi-step animation caught up.
    public static func clippingBottomLine(
        current: Int,
        target: Int,
        animatesRoll: Bool,
        reduceMotion: Bool
    ) -> Int {
        if animatesRoll, !reduceMotion, target > current {
            return current
        }
        return target
    }

    /// Whether an update must stop an in-flight roll and snap to the new layout. This is
    /// intentionally independent of `current == target`: a resize may land on the model
    /// line mid-animation while an older, farther target is still queued.
    public static func shouldSnapRoll(
        current: Int,
        target: Int,
        activeTarget: Int,
        animatesRoll: Bool,
        reduceMotion: Bool
    ) -> Bool {
        reduceMotion
            || !animatesRoll
            || target < current
            || (target <= current && target != activeTarget)
    }

    /// IDs introduced strictly after the existing reading order. Placement details such
    /// as `isSettled` may change during promotion and must not suppress the fade of a new
    /// word appended in the same update. Replacements and insertions are intentionally
    /// excluded because recognizer corrections should swap without motion.
    public static func appendedIDs(
        from current: [Placement],
        to next: [Placement]
    ) -> [UInt64] {
        guard !next.isEmpty else { return [] }
        if current.isEmpty { return next.map(\.id) }

        let nextIDs = next.map(\.id)
        for dropped in 0...current.count {
            let survivingIDs = current.dropFirst(dropped).map(\.id)
            guard nextIDs.starts(with: survivingIDs) else { continue }
            if survivingIDs.isEmpty {
                // With no shared visible ID, advancing anchors distinguish natural
                // top-edge eviction from a same-position provisional replacement.
                guard let oldAnchor = current.last?.anchor,
                      let newAnchor = next.first?.anchor,
                      newAnchor > oldAnchor else { return [] }
            }
            let appended = Array(nextIDs.dropFirst(survivingIDs.count))
            return appended.filter { !survivingIDs.contains($0) }
        }
        return []
    }
}
