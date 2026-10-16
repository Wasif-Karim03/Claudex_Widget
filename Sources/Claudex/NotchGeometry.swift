import AppKit

/// Sizes of the panel, the collapsed pill and the expanded card, derived from the notch.
struct NotchLayout: Equatable, Sendable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let wingWidth: CGFloat = 64
    static let cardWidth: CGFloat = 500
    /// Card body height with a single line in the "Live now" lists.
    static let cardBaseHeight: CGFloat = 206
    static let liveRowHeight: CGFloat = 21
    static let moreRowHeight: CGFloat = 17
    /// Tallest list: three sessions plus "+N more".
    static let maxLiveLines = 4

    static let fallback = NotchLayout(notchWidth: 180, notchHeight: 32, hasNotch: false)

    var panelSize: CGSize {
        CGSize(width: max(notchWidth + 160, Self.cardWidth), height: cardSize(liveLines: Self.maxLiveLines).height + 10)
    }

    var pillSize: CGSize {
        CGSize(width: notchWidth + 2 * Self.wingWidth, height: notchHeight)
    }

    /// `liveLines` counts session rows plus a "+N more" line (see `liveLines(for:)`).
    func cardSize(liveLines: Int) -> CGSize {
        let lines = max(1, min(liveLines, Self.maxLiveLines))
        let sessionRows = min(lines, 3)
        let extra = CGFloat(sessionRows - 1) * Self.liveRowHeight + (lines > 3 ? Self.moreRowHeight : 0)
        return CGSize(width: Self.cardWidth, height: notchHeight + Self.cardBaseHeight + extra)
    }

    /// Lines the taller of the two "Live now" lists needs.
    static func liveLines(for sessionCounts: [Int]) -> Int {
        sessionCounts.map { min($0, 3) + ($0 > 3 ? 1 : 0) }.max() ?? 1
    }

    func shapeSize(expanded: Bool, liveLines: Int) -> CGSize {
        expanded ? cardSize(liveLines: liveLines) : pillSize
    }
}

enum NotchGeometry {
    /// The built-in display with a camera housing if there is one, else the main screen.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen) -> NotchLayout {
        let top = screen.safeAreaInsets.top
        if top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            var width = screen.frame.width - left - right
            if left == 0 || right == 0 || width <= 0 { width = 180 }
            return NotchLayout(notchWidth: width, notchHeight: top, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchLayout(notchWidth: 180, notchHeight: menuBar > 0 ? menuBar : 32, hasNotch: false)
    }

    /// Panel frame: top-centred, flush with the top of the screen.
    static func panelFrame(for layout: NotchLayout, on screen: NSScreen) -> NSRect {
        let size = layout.panelSize
        return NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                      y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

/// Which outline currently accepts the mouse.
enum HitRegion: Equatable {
    case pill, card

    /// Seconds the expand spring needs before the larger card outline accepts the mouse.
    static let settleDelay: TimeInterval = 0.45

    /// During expansion the hit region stays the pill until the spring settles; on
    /// collapse it switches back to the pill immediately.
    static func current(isExpanded: Bool, expandedAt: Date?, now: Date) -> HitRegion {
        guard isExpanded, let expandedAt else { return .pill }
        return now.timeIntervalSince(expandedAt) >= settleDelay ? .card : .pill
    }

    /// Whether a screen-space point (AppKit, bottom-left origin) falls inside the rendered
    /// NotchShape for `region`, which is top-centred on `screenFrame`.
    static func contains(_ point: CGPoint, region: HitRegion, layout: NotchLayout, liveLines: Int,
                         screenFrame: CGRect) -> Bool {
        let expanded = region == .card
        let size = layout.shapeSize(expanded: expanded, liveLines: liveLines)
        let local = CGPoint(x: point.x - (screenFrame.midX - size.width / 2),
                            y: screenFrame.maxY - point.y)
        guard local.x >= 0, local.y >= 0, local.x <= size.width, local.y <= size.height else { return false }
        let shape = NotchShape(expanded: expanded)
        return shape.path(in: CGRect(origin: .zero, size: size)).cgPath.contains(local)
    }
}

/// The live-list line count the hit path uses. The card's height animates, so when the
/// list grows the hit path keeps the previous (smaller) size until the spring settles;
/// when it shrinks the hit path follows immediately. The hit path is therefore never
/// larger than the visible card.
struct HitLinesTracker {
    private(set) var lines: Int
    private var pending: (lines: Int, since: Date)?

    init(lines: Int = 0) { self.lines = lines }

    mutating func update(target: Int, now: Date) -> Int {
        if target <= lines {
            lines = target
            pending = nil
        } else if let pending, pending.lines == target {
            if now.timeIntervalSince(pending.since) >= HitRegion.settleDelay {
                lines = target
                self.pending = nil
            }
        } else {
            pending = (target, now)
        }
        return lines
    }
}
