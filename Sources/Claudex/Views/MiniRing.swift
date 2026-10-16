import ClaudexCore
import SwiftUI

/// Tiny progress ring showing % left in the primary window.
struct MiniRing: View {
    let kind: ProviderKind
    let leftPercent: Double?
    var size: CGFloat = 13
    var lineWidth: CGFloat = 2
    /// Stale data: drawn at reduced opacity.
    var dimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { max(0, min(1, (leftPercent ?? 0) / 100)) }
    private var low: Bool { (leftPercent ?? 100) < 20 }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: leftPercent == nil ? 0 : max(0.02, fraction))
                .stroke(
                    low ? AnyShapeStyle(Theme.worried) : AnyShapeStyle(AngularGradient(
                        colors: Theme.colors(kind) + [Theme.colors(kind)[0]], center: .center)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.motion(.spring(response: 0.6, dampingFraction: 0.85), reduceMotion: reduceMotion),
                           value: fraction)
        }
        .opacity(dimmed ? 0.4 : 1)
        .frame(width: size, height: size)
        .accessibilityLabel("\(kind.displayName) \(Int(leftPercent ?? 0)) percent left")
    }
}
