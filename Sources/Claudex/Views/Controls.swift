import AppKit
import ServiceManagement
import SwiftUI

/// Refresh / Launch at Login / Quit, shared by the gear menu and the context menu.
struct ControlsMenuItems: View {
    let model: AppModel

    private var runningFromApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Button("Refresh") { model.refresh() }
        Toggle("Launch at Login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                if enable {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }))
            .disabled(!runningFromApp)
        Divider()
        Button("Quit Claudex") { NSApplication.shared.terminate(nil) }
    }
}

struct GearButton: View {
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        Menu {
            ControlsMenuItems(model: model)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The borderless menu label ignores foregroundStyle, so dim it with opacity.
        .opacity(hovering ? 0.9 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Claudex settings")
    }
}
