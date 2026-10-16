import ClaudexCore
import SwiftUI

/// Today's estimated water use. Each mascot stands in its own tub, and the water rises up
/// its legs with that tool's litres. Drops fall into the tub of a tool that is working.
struct WaterBand: View {
    struct Side {
        var litres: Double
        var mood: Mood
        var activity: Activity
    }

    let water: TokenTally.Today
    let claude: Side
    let codex: Side
    /// False while collapsed: the mascots and water hold still.
    let animated: Bool

    static let height: CGFloat = 62

    var body: some View {
        let litres = water.litres
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(WaterFormatter.litres(litres))
                        .font(Theme.font(18, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText(value: litres))
                        .animation(.snappy(duration: 0.5), value: litres)
                    Text("L").font(Theme.font(12, .medium)).foregroundStyle(Theme.secondaryText)
                }
                Text("water today · est.")
                    .font(Theme.font(10.5))
                    .foregroundStyle(Theme.secondaryText)
                Text(WaterFormatter.comparison(litres))
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 2)
            }
            .fixedSize()
            .padding(.leading, 12)
            Spacer(minLength: 8)
            Tub(kind: .claude, side: claude, animated: animated)
            Tub(kind: .codex, side: codex, animated: animated)
                .padding(.leading, 14)
                .padding(.trailing, 8)
        }
        .frame(height: Self.height)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("A rough estimate from today's tokens: about 0.4 J per input-equivalent token "
            + "(output counts 5×, cache reads 0.1×) and 3.6 L of water per kWh, for data-centre "
            + "cooling plus generating the power. Providers don't publish real figures.")
        .accessibilityElement(children: .combine)
    }
}

/// One mascot wading in its tub, with its litres beside it.
private struct Tub: View {
    let kind: ProviderKind
    let side: WaterBand.Side
    let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 64
    /// Height of the tub's floor above the band's bottom edge.
    static let floor: CGFloat = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ZStack(alignment: .bottom) {
                PixelMascot(kind: kind, pixel: kind == .claude ? 2 : 1.5,
                            mood: side.mood, activity: side.activity, animated: animated)
                    .padding(.bottom, Self.floor)
                TubWater(litres: side.litres, working: side.activity == .working,
                         live: animated && !reduceMotion, phase: kind == .claude ? 0 : 3.7)
            }
            .frame(width: Self.width, height: WaterBand.height)
            Text("\(WaterFormatter.litres(side.litres)) L")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .contentTransition(.numericText(value: side.litres))
                .animation(.snappy(duration: 0.5), value: side.litres)
                .fixedSize()
                .padding(.bottom, Self.floor + 2)
        }
    }
}

/// The tub's water, drawn over the mascot in 2 pt blocks to match it. Two waves (a faint
/// one behind) roll across, and the depth climbs from a puddle to waist height.
private struct TubWater: View {
    let litres: Double
    let working: Bool
    let live: Bool
    /// Offsets the waves so the two tubs don't move in step.
    let phase: Double

    private static let pixel: CGFloat = 2
    private static let surface = Color(hex: 0x8FD3FF)
    private static let body = Color(hex: 0x2E7BD6)

    var body: some View {
        TimelineView(PixelSchedule(live: live, fps: working ? 8 : 4)) { context in
            let t = live ? context.date.timeIntervalSinceReferenceDate + phase : phase
            Canvas { gc, size in draw(in: &gc, size: size, t: t) }
        }
        .accessibilityHidden(true)
    }

    /// Water depth in pixel rows: a 1-row puddle with nothing burned, approaching 6.
    private var level: Double { 1 + 5 * (1 - exp(-litres / 6)) }

    private func draw(in gc: inout GraphicsContext, size: CGSize, t: Double) {
        let p = Self.pixel
        let columns = Int(size.width / p)
        let floor = Int(((size.height - Tub.floor) / p).rounded())
        func top(_ x: Int, back: Bool) -> Int {
            let fx = Double(x)
            let wave = back
                ? 0.9 * sin(fx * 0.18 - t * 1.3) + 0.5 * sin(fx * 0.41 + t * 1.9)
                : 0.8 * sin(fx * 0.22 + t * 1.8) + 0.4 * sin(fx * 0.5 - t * 2.6)
            return floor - Int((level + wave + (back ? 1 : 0)).rounded())
        }

        var backPath = Path(), bodyPath = Path(), surfacePath = Path()
        for x in 0..<columns {
            let front = min(top(x, back: false), floor - 1), behind = top(x, back: true)
            let fx = CGFloat(x) * p
            if behind < front {
                backPath.addRect(CGRect(x: fx, y: CGFloat(behind) * p, width: p, height: CGFloat(front - behind) * p))
            }
            surfacePath.addRect(CGRect(x: fx, y: CGFloat(front) * p, width: p, height: p))
            bodyPath.addRect(CGRect(x: fx, y: CGFloat(front + 1) * p, width: p, height: CGFloat(floor - front - 1) * p))
        }
        gc.fill(backPath, with: .color(Self.surface.opacity(0.18)))
        gc.fill(bodyPath, with: .color(Self.body.opacity(0.38)))
        gc.fill(surfacePath, with: .color(Self.surface.opacity(0.75)))
        // The tub's floor.
        gc.fill(Path(CGRect(x: 0, y: CGFloat(floor) * p, width: size.width, height: 0.75)),
                with: .color(.white.opacity(0.22)))

        guard working, live else { return }
        drops(in: &gc, columns: columns, top: { top($0, back: false) }, t: t)
    }

    /// Two drops on staggered 1.6 s cycles: a fall that speeds up, then a small splash.
    private func drops(in gc: inout GraphicsContext, columns: Int, top: (Int) -> Int, t: Double) {
        let p = Self.pixel
        let period = 1.6, fall = 0.9, splash = 0.35
        func block(_ x: Int, _ y: Int, _ opacity: Double) {
            gc.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)),
                    with: .color(Self.surface.opacity(opacity)))
        }
        for i in 0..<2 {
            let local = t + Double(i) * period / 2
            let cycle = Int(floor(local / period))
            let phase = local - Double(cycle) * period
            // Land beside the mascot rather than on its head.
            let x = Self.hash(cycle * 2 + i) % 2 == 0 ? 2 + Self.hash(cycle + i) % 4 : columns - 6 + Self.hash(cycle + i) % 4
            let surface = top(x)
            if phase < fall {
                let progress = phase / fall
                let y = Int(Double(surface - 1) * progress * progress)
                block(x, y - 1, 0.45)
                block(x, y, 0.9)
            } else if phase < fall + splash {
                let fade = 1 - (phase - fall) / splash
                let spread = phase - fall < splash / 2 ? 1 : 2
                block(x - spread, surface - spread, 0.8 * fade)
                block(x + spread, surface - spread, 0.8 * fade)
                block(x, surface - 1, 0.5 * fade)
            }
        }
    }

    /// Cheap deterministic scramble, so drop positions look random but repeat exactly.
    private static func hash(_ n: Int) -> Int {
        var v = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
        v ^= v >> 29
        return Int(v % 10_007)
    }
}
