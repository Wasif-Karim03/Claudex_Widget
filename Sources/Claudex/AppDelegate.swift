import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panel: NotchPanel?
    private var screenFrame: CGRect = .zero
    private var trackingTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var expandedAt: Date?
    private var hitLines = HitLinesTracker()
    /// Set after a click collapses the card while the mouse is still over the pill, so
    /// hover does not instantly re-open it; cleared once the mouse leaves.
    private var suppressHoverExpand = false

    static let collapseDelay: TimeInterval = 0.6

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NotchPanel(contentRect: .zero)
        let root = RootView(model: model, onToggle: { [weak self] in self?.toggleFromClick() })
        let host = ClickThroughHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel

        layoutPanel()
        panel.orderFrontRegardless()
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func layoutPanel() {
        guard let panel, let screen = NotchGeometry.targetScreen() else { return }
        let layout = NotchGeometry.layout(for: screen)
        model.layout = layout
        screenFrame = screen.frame
        panel.setFrame(NotchGeometry.panelFrame(for: layout, on: screen), display: true)
    }

    // MARK: - Hover and click-through

    private func trackMouse() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let region = HitRegion.current(isExpanded: model.isExpanded, expandedAt: expandedAt, now: now)
        let liveLines = hitLines.update(target: model.liveLines, now: now)
        let inside = HitRegion.contains(mouse, region: region, layout: model.layout, liveLines: liveLines, screenFrame: screenFrame)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        let inPill = HitRegion.contains(mouse, region: .pill, layout: model.layout, liveLines: model.liveLines, screenFrame: screenFrame)
        if suppressHoverExpand {
            if !inPill { suppressHoverExpand = false }
            return
        }

        if model.isExpanded {
            let inCard = HitRegion.contains(mouse, region: .card, layout: model.layout, liveLines: liveLines, screenFrame: screenFrame)
            if inCard || inPill {
                cancelCollapse()
            } else if collapseWork == nil {
                scheduleCollapse()
            }
        } else if inPill {
            setExpanded(true)
        }
    }

    private func scheduleCollapse() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func toggleFromClick() {
        let expand = !model.isExpanded
        setExpanded(expand)
        if !expand { suppressHoverExpand = true }
    }

    private func setExpanded(_ expanded: Bool) {
        cancelCollapse()
        guard model.isExpanded != expanded else { return }
        expandedAt = expanded ? Date() : nil
        withAnimation(Theme.morphAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            model.isExpanded = expanded
        }
    }
}
