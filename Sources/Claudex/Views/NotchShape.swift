import SwiftUI

/// The notch silhouette: square top edge flush with the screen, small concave "ears"
/// that flare into the menu bar, and rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    init(expanded: Bool) {
        self.init(topRadius: expanded ? Self.expandedTop : Self.collapsedTop,
                  bottomRadius: expanded ? Self.expandedBottom : Self.collapsedBottom)
    }

    static let collapsedTop: CGFloat = 6
    static let collapsedBottom: CGFloat = 10
    static let expandedTop: CGFloat = 12
    static let expandedBottom: CGFloat = 22

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left ear: concave flare from the screen edge into the body.
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Right ear.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
