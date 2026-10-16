import AppKit
import ServiceManagement
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
    /// Development aid: `CLAUDEX_PIN_EXPANDED=1` keeps the card open for screenshots.
    private let pinExpanded = ProcessInfo.processInfo.environment["CLAUDEX_PIN_EXPANDED"] == "1"

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
        enableLaunchAtLoginOnFirstRun()
        if pinExpanded { setExpanded(true) }
        if let path = ProcessInfo.processInfo.environment["CLAUDEX_SNAPSHOT"] { snapshot(to: path) }

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
        if pinExpanded { return }

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

    /// The first time Claudex runs from /Applications it adds itself to Login Items, so an
    /// installed copy starts with the Mac. Done once only: switching it off in the menu
    /// sticks.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didAutoEnableLaunchAtLogin"
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval { UserDefaults.standard.set(true, forKey: key) }
    }

    /// Development aid: renders the expanded card to a PNG a few seconds after launch
    /// (once data has loaded), then quits. Needs no screen-recording permission.
    private func snapshot(to path: String) {
        model.isExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [model] in
            MainActor.assumeIsolated {
                let size = model.layout.panelSize
                let view = RootView(model: model, onToggle: {})
                    .frame(width: size.width, height: size.height)
                    .background(Color(white: 0.16))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
