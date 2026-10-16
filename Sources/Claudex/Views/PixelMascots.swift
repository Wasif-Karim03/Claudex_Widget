import ClaudexCore
import SwiftUI

// Pixel-art mascots drawn as blocks on a Canvas. Each frame is a pure function of the
// mascot's state and the clock, so the animation is deterministic and pauses cleanly.

struct Pixel {
    var x: Int
    var y: Int
    var color: Color
    var opacity: Double = 1
}

/// Everything a mascot frame depends on.
struct MascotPose {
    var mood: Mood
    var activity: Activity
    /// Seconds since an arbitrary epoch; 0 for a still frame.
    var t: Double
    var live: Bool

    /// 8 fps step counter for the chunky pixel animations.
    var step: Int { Int(t * 8) }
    var worried: Bool { mood == .worried }
    var working: Bool { live && activity == .working }

    /// Blinks for 0.12s on a slightly irregular 3-6s rhythm.
    func blinking(seed: Double) -> Bool {
        guard live, activity != .sleepy else { return false }
        let periods = [3.4, 5.6, 4.1, 2.9, 6.0]
        let total = periods.reduce(0, +)
        var phase = (t + seed).truncatingRemainder(dividingBy: total)
        for period in periods {
            if phase < period { return phase > period - 0.12 }
            phase -= period
        }
        return false
    }
}

/// Grid geometry shared by both mascots: a body grid plus a margin for sparkles and z's.
struct PixelGrid {
    static let marginX = 2
    static let marginTop = 4
    let bodyWidth: Int
    let bodyHeight: Int
    var width: Int { bodyWidth + 2 * Self.marginX }
    var height: Int { bodyHeight + Self.marginTop }
}

// MARK: - Palettes

private enum Palette {
    static let claude = Color(hex: 0xD97757)
    static let claudeLight = Color(hex: 0xEE9A78)
    static let claudeWorried = Color(hex: 0xE5603F)
    static let eye = Color(hex: 0x1B1311)

    static let codexTop = Color(hex: 0x5ED6B4)
    static let codexBottom = Color(hex: 0x3BB3C9)
    static let codexWorried = Color(hex: 0x9FC7A0)
    static let screen = Color(hex: 0x082A2E)
    static let face = Color(hex: 0x8CFFD9)
    static let lightOn = Color(hex: 0xFFE27A)
    static let lightDim = Color(hex: 0x6B7F6A)

    static let sweat = Color(hex: 0x8FD3FF)
    static let sparkle = Color(hex: 0xFFF3B0)
}

// MARK: - Shared overlays

private func sparkles(_ pose: MascotPose, grid: PixelGrid) -> [Pixel] {
    guard pose.working else { return [] }
    // Little "typing" twinkles that pop around the head, three at a time.
    let spots = [(-2, 1), (grid.bodyWidth + 1, 0), (1, -3), (grid.bodyWidth - 2, -3), (-1, -2), (grid.bodyWidth, 2)]
    var out: [Pixel] = []
    for i in 0..<3 {
        let index = (pose.step / 3 + i * 2) % spots.count
        let life = (pose.step + i) % 3
        let (x, y) = spots[index]
        out.append(Pixel(x: x, y: y, color: Palette.sparkle, opacity: life == 2 ? 0.45 : 1))
        if life == 1 {
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                out.append(Pixel(x: x + dx, y: y + dy, color: Palette.sparkle, opacity: 0.5))
            }
        }
    }
    return out
}

private func sweatDrop(atX x: Int, y: Int) -> [Pixel] {
    [Pixel(x: x + 1, y: y, color: Palette.sweat),
     Pixel(x: x, y: y + 1, color: Palette.sweat), Pixel(x: x + 1, y: y + 1, color: Palette.sweat),
     Pixel(x: x, y: y + 2, color: Palette.sweat), Pixel(x: x + 1, y: y + 2, color: Palette.sweat, opacity: 0.7)]
}

// MARK: - Claude: the blocky orange critter

enum ClaudePixels {
    static let grid = PixelGrid(bodyWidth: 16, bodyHeight: 10)

    static func frame(_ pose: MascotPose) -> [Pixel] {
        var px: [Pixel] = []
        let body = pose.worried ? Palette.claudeWorried : Palette.claude
        let bounce = pose.working && pose.step % 2 == 1 ? -1 : 0
        func add(_ x: Int, _ y: Int, _ c: Color, _ o: Double = 1) { px.append(Pixel(x: x, y: y + bounce, color: c, opacity: o)) }

        // Head and torso (rows 0-7), a lighter top row for a bit of volume.
        for y in 0...7 where y != 4 && y != 5 {
            for x in 2...13 { add(x, y, y == 0 ? Palette.claudeLight : body) }
        }
        // Arm row: full width, with arms that type while working.
        for x in 2...13 { add(x, 4, body); add(x, 5, body) }
        let leftUp = pose.working && pose.step % 2 == 0
        let rightUp = pose.working && pose.step % 2 == 1
        for x in 0...1 { add(x, leftUp ? 3 : 4, body); add(x, leftUp ? 4 : 5, body) }
        for x in 14...15 { add(x, rightUp ? 3 : 4, body); add(x, rightUp ? 4 : 5, body) }

        // Eyes: 1x2 slits; a blink or sleep closes them to the lower pixel.
        let closed = pose.activity == .sleepy || pose.blinking(seed: 0)
        for x in [4, 11] {
            if !closed { add(x, 2, Palette.eye) }
            add(x, 3, Palette.eye)
        }
        if pose.worried && !closed {
            // Anxious brows: a dark pixel tilted toward the middle.
            add(5, 1, Palette.eye, 0.55)
            add(10, 1, Palette.eye, 0.55)
        }

        // Legs step in pairs while working; they don't bounce with the body.
        let liftA = pose.working && pose.step % 2 == 0
        for (i, x) in [3, 5, 10, 12].enumerated() {
            let lifted = (i % 2 == 0) == liftA && pose.working
            px.append(Pixel(x: x, y: 8, color: body))
            if !lifted { px.append(Pixel(x: x, y: 9, color: body)) }
        }

        if pose.worried { px += sweatDrop(atX: 14, y: -1 + bounce) }
        px += sparkles(pose, grid: grid)
        return px
    }
}

// MARK: - Codex: a little terminal robot

enum CodexPixels {
    static let grid = PixelGrid(bodyWidth: 15, bodyHeight: 14)

    static func frame(_ pose: MascotPose) -> [Pixel] {
        var px: [Pixel] = []
        let bounce = pose.working && pose.step % 2 == 1 ? -1 : 0
        func shade(_ y: Int) -> Color {
            if pose.worried { return y < 8 ? Palette.codexWorried : Palette.codexBottom }
            return y < 8 ? Palette.codexTop : Palette.codexBottom
        }
        func add(_ x: Int, _ y: Int, _ c: Color, _ o: Double = 1) { px.append(Pixel(x: x, y: y + bounce, color: c, opacity: o)) }

        // Antenna: a light that blinks while working, glows softly idle, is off asleep.
        let light: Color
        var lightOpacity = 1.0
        switch pose.activity {
        case .working where pose.live: light = (pose.step / 2) % 2 == 0 ? Palette.lightOn : Palette.lightDim
        case .working, .idle: light = Palette.lightOn; lightOpacity = pose.live ? 0.55 + 0.35 * sin(pose.t * 2) : 0.8
        case .sleepy: light = Palette.lightDim
        }
        add(7, 0, light, lightOpacity)
        for x in 6...8 { add(x, 1, light, lightOpacity) }
        add(7, 2, Palette.codexBottom)
        add(7, 3, Palette.codexBottom)

        // Head/body with clipped corners.
        for y in 4...11 {
            for x in 1...13 where !((y == 4 || y == 11) && (x == 1 || x == 13)) { add(x, y, shade(y)) }
        }
        // Arms that tap while working.
        let tap = pose.working && pose.step % 2 == 0
        add(0, tap ? 6 : 7, shade(7)); add(0, tap ? 7 : 8, shade(8))
        add(14, tap ? 8 : 7, shade(7)); add(14, tap ? 9 : 8, shade(8))

        // Screen.
        for y in 5...9 { for x in 3...11 { add(x, y, Palette.screen) } }

        // Face: `>_`. A blink flattens `>` to `-`; asleep it's a dim `- -`; the cursor
        // blinks fast while working and slowly when idle.
        let face = Palette.face
        if pose.activity == .sleepy {
            for x in [4, 5, 8, 9] { add(x, 8, face, 0.45) }
        } else {
            if pose.blinking(seed: 1.7) {
                add(4, 7, face); add(5, 7, face)
            } else if pose.worried {
                // A wobbly `>` that leans back.
                add(5, 6, face); add(4, 7, face); add(5, 8, face)
            } else {
                add(4, 6, face); add(5, 7, face); add(4, 8, face)
            }
            let cursorOn = !pose.live || (pose.working ? pose.step % 4 < 2 : Int(pose.t * 1.2) % 2 == 0)
            if cursorOn { for x in 7...9 { add(x, 8, face) } }
        }

        // Legs.
        let liftLeft = pose.working && pose.step % 2 == 0
        for (i, xs) in [[3, 4], [10, 11]].enumerated() {
            let lifted = pose.working && ((i == 0) == liftLeft)
            for x in xs {
                px.append(Pixel(x: x, y: 12, color: Palette.codexBottom))
                if !lifted { px.append(Pixel(x: x, y: 13, color: Palette.codexBottom)) }
            }
        }

        if pose.worried { px += sweatDrop(atX: 11, y: 1 + bounce) }
        px += sparkles(pose, grid: grid)
        return px
    }
}

// MARK: - View

struct PixelMascot: View {
    let kind: ProviderKind
    /// Side of one pixel block in points.
    var pixel: CGFloat
    var mood: Mood = .happy
    var activity: Activity = .idle
    /// False pauses all motion (e.g. while hidden).
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var grid: PixelGrid { kind == .claude ? ClaudePixels.grid : CodexPixels.grid }
    private var live: Bool { animated && !reduceMotion }

    var body: some View {
        TimelineView(PixelSchedule(live: live, fps: PixelSchedule.fps(for: activity))) { context in
            let t = live ? context.date.timeIntervalSinceReferenceDate : 0
            let pose = MascotPose(mood: mood, activity: activity, t: t, live: live)
            Canvas { gc, _ in
                draw(pose, in: &gc)
            }
            .frame(width: CGFloat(grid.width) * pixel, height: CGFloat(grid.height) * pixel)
            .scaleEffect(x: 1, y: breath(pose), anchor: .bottom)
            .offset(x: shake(pose))
            .overlay(alignment: .topTrailing) {
                if activity == .sleepy { sleepyZs(pose) }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ pose: MascotPose, in gc: inout GraphicsContext) {
        let pixels = kind == .claude ? ClaudePixels.frame(pose) : CodexPixels.frame(pose)
        // Slight overlap hides hairline seams between neighbouring blocks.
        let overlap: CGFloat = 0.25
        for p in pixels {
            let rect = CGRect(x: CGFloat(p.x + PixelGrid.marginX) * pixel,
                              y: CGFloat(p.y + PixelGrid.marginTop) * pixel,
                              width: pixel + overlap, height: pixel + overlap)
            gc.fill(Path(rect), with: .color(p.color.opacity(p.opacity)))
        }
    }

    /// Slow breathing while idle or asleep.
    private func breath(_ pose: MascotPose) -> CGFloat {
        guard pose.live, pose.activity != .working else { return 1 }
        let period = pose.activity == .sleepy ? 4.5 : 3.0
        let amount = pose.activity == .sleepy ? 0.05 : 0.03
        return 1 + amount * CGFloat((sin(pose.t * 2 * .pi / period) + 1) / 2)
    }

    /// A short nervous jitter every few seconds when worried.
    private func shake(_ pose: MascotPose) -> CGFloat {
        guard pose.live, pose.worried else { return 0 }
        let phase = pose.t.truncatingRemainder(dividingBy: 5)
        guard phase < 0.4 else { return 0 }
        return (Int(phase * 20) % 2 == 0 ? 1 : -1) * pixel * 0.6
    }

    /// Three z's drifting up and fading, staggered.
    private func sleepyZs(_ pose: MascotPose) -> some View {
        let size = max(6, pixel * 4)
        return ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { i in
                let phase = pose.live ? ((pose.t / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)) : Double(i) / 3
                Text("z")
                    .font(.system(size: size * (0.7 + 0.5 * phase), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85 * (1 - phase) * (phase < 0.1 ? phase * 10 : 1)))
                    .offset(x: size * 1.2 * phase, y: -size * 1.6 * phase)
            }
        }
        .frame(width: size * 1.6, height: size * 2, alignment: .bottomLeading)
        .offset(x: size * 0.6, y: -size * 0.2)
        .allowsHitTesting(false)
    }
}

/// Ticks `fps` times a second while live; a single entry when paused.
/// Ticks fall on a grid anchored to the reference date, and every rate divides 8, so all
/// mascots on screen update in the same frames: one SwiftUI graph update per tick rather
/// than one per mascot. That shared update is most of an always-on widget's CPU cost.
struct PixelSchedule: TimelineSchedule {
    let live: Bool
    let fps: Double

    /// 8 fps matches the pixel step rate while working; idle breathing and blinks read
    /// fine at 4, and sleep's slow drift at 2.
    static func fps(for activity: Activity) -> Double {
        switch activity {
        case .working: 8
        case .idle: 4
        case .sleepy: 2
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard live, mode != .lowFrequency else {
            var done = false
            return AnyIterator { defer { done = true }; return done ? nil : startDate }
        }
        let interval = 1.0 / fps
        var tick = (startDate.timeIntervalSinceReferenceDate / interval).rounded(.up)
        var first = true
        return AnyIterator {
            if first {
                first = false
                return startDate
            }
            defer { tick += 1 }
            return Date(timeIntervalSinceReferenceDate: tick * interval)
        }
    }
}
