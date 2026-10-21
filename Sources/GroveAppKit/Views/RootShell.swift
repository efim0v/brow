// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import AppKit
import GroveCore

/// The root scope (route .projects): the Projects list. In a window of its own it carries
/// its title and an "Add project" row; in the notch the panel's switch row has both (the
/// section's name, and + beside the search).
struct RootShell: View {
    @ObservedObject var state: AppState
    @Environment(\.groveHost) private var host
    @Environment(\.groveAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !host.isNotch {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                addRow
            }
            ProjectsTab(state: state)
                .padding(.horizontal, host.isNotch ? 0 : 12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var addRow: some View {
        HStack(spacing: 0) {
            Button { addProject() } label: {
                Label("Add project", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Add a project directory")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// The host's folder picker when it has one; an open panel of its own otherwise. Never
    /// reached offscreen: it sits behind a button.
    private func addProject() {
        if let addFolder = state.addFolder { addFolder(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            state.addProject(at: url.path)
        }
    }
}
