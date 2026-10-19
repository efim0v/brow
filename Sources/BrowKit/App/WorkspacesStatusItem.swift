// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit

/// Brow's menu-bar item while Workspaces is on: a click opens the notch panel pinned on
/// Projects, or closes it when it already shows them. A plain `NSStatusItem`, not SwiftUI's
/// `MenuBarExtra`, whose scene machinery quit the app at launch on macOS 26.4.
@MainActor
final class WorkspacesStatusItem: NSObject {
    private var item: NSStatusItem?
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init()
    }

    var isShown: Bool { item != nil }

    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(clicked)
            button.target = self
            let icon = BrowMark.templateImage()
            icon.isTemplate = true
            button.image = icon
            button.setAccessibilityLabel("Brow Projects")
            button.toolTip = "Brow Projects"
        }
        item.isVisible = true
        self.item = item
        BrowLog.workspaces.info("status item up")
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func clicked() { onClick() }
}
