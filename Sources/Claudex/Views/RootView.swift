import ClaudexCore
import SwiftUI

struct RootView: View {
    let model: AppModel
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { model.isExpanded }
    private var layout: NotchLayout { model.layout }

    var body: some View {
        let shape = NotchShape(expanded: expanded)
        let size = layout.shapeSize(expanded: expanded, liveLines: model.liveLines)
        let card = layout.cardSize(liveLines: model.liveLines)

        ZStack(alignment: .top) {
            collapsedContent
                .frame(width: layout.pillSize.width, height: layout.pillSize.height)
                .opacity(expanded ? 0 : 1)
                .scaleEffect(expanded && !reduceMotion ? 0.8 : 1, anchor: .top)
                .animation(expanded ? .easeOut(duration: 0.12) : morph.delay(0.12), value: expanded)
                .allowsHitTesting(!expanded)

            expandedContent
                .frame(width: card.width, height: card.height, alignment: .top)
                .allowsHitTesting(expanded)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Theme.background))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: onToggle)
        .contextMenu { ControlsMenuItems(model: model) }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .top)
        .animation(expanded ? morph : nil, value: model.liveLines)
        .environment(\.colorScheme, .dark)
    }

    private var morph: Animation { Theme.morphAnimation(reduceMotion: reduceMotion) }

    // MARK: Collapsed pill

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                PixelMascot(kind: .claude, pixel: 1.5, mood: model.claude.mood,
                            activity: model.claude.activity(now: model.now), animated: !expanded)
                MiniRing(kind: .claude, leftPercent: model.claude.indicatorLeftPercent, dimmed: model.claude.isStale)
            }
            Spacer(minLength: layout.notchWidth)
            HStack(spacing: 5) {
                MiniRing(kind: .codex, leftPercent: model.codex.indicatorLeftPercent, dimmed: model.codex.isStale)
                PixelMascot(kind: .codex, pixel: 1.0, mood: model.codex.mood,
                            activity: model.codex.activity(now: model.now), animated: !expanded)
            }
        }
        .padding(.horizontal, NotchShape.collapsedTop + 4)
    }

    // MARK: Expanded card

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // The band beside the camera housing.
            HStack(alignment: .center) {
                Text("claudex")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                GearButton(model: model)
            }
            .padding(.horizontal, NotchShape.expandedTop + 12)
            .frame(height: layout.notchHeight)
            .opacity(expanded ? 1 : 0)
            .animation(expanded ? morph.delay(0.2) : .easeOut(duration: 0.1), value: expanded)

            HStack(alignment: .top, spacing: 0) {
                stagger(ProviderCard(snapshot: model.claude, now: model.now, revealed: expanded), delay: 0.06)
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                    .padding(.vertical, 6)
                    .opacity(expanded ? 1 : 0)
                    .animation(expanded ? morph.delay(0.1) : .easeOut(duration: 0.1), value: expanded)
                stagger(ProviderCard(snapshot: model.codex, now: model.now, revealed: expanded), delay: 0.12)
            }
            .padding(.horizontal, NotchShape.expandedTop)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private func stagger(_ card: ProviderCard, delay: Double) -> some View {
        card
            .opacity(expanded ? 1 : 0)
            // Reduce Motion: fade only, no scale or slide.
            .scaleEffect(expanded || reduceMotion ? 1 : 0.9, anchor: .top)
            .offset(y: expanded || reduceMotion ? 0 : -10)
            .animation(expanded ? morph.delay(delay) : .easeOut(duration: 0.12), value: expanded)
    }
}
