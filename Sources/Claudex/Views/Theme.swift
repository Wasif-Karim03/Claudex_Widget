import ClaudexCore
import SwiftUI

enum Theme {
    static let background = Color.black

    static let claudeStart = Color(hex: 0xD97757)
    static let claudeEnd = Color(hex: 0xF0A27A)
    static let codexStart = Color(hex: 0x5ED6B4)
    static let codexEnd = Color(hex: 0x3BB3C9)

    static let worried = Color(hex: 0xFF5A3C)
    static let active = Color(hex: 0x5BD08A)
    static let idle = Color.white.opacity(0.28)

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.56)
    static let tertiaryText = Color.white.opacity(0.34)
    static let track = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.08)

    static func gradient(_ kind: ProviderKind) -> LinearGradient {
        LinearGradient(colors: colors(kind), startPoint: .leading, endPoint: .trailing)
    }

    static func colors(_ kind: ProviderKind) -> [Color] {
        switch kind {
        case .claude: [claudeStart, claudeEnd]
        case .codex: [codexStart, codexEnd]
        }
    }

    static func tint(_ kind: ProviderKind) -> Color { colors(kind)[0] }

    /// The tint 45% of the way to white: the inner (longer) window's ring.
    static func innerTint(_ kind: ProviderKind) -> Color {
        switch kind {
        case .claude: Color(hex: 0xEAB4A3)
        case .codex: Color(hex: 0xA6E8D6)
        }
    }

    /// SF Pro for words.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Mono for machine-ish detail: model ids, plans, countdowns.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let morphSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    static func morphAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : morphSpring
    }

    /// Reduce Motion policy for every other animation: a short crossfade replaces it.
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
