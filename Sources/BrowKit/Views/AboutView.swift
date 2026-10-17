import AppKit
import GroveCore
import SwiftUI

/// Settings › About: what Brow is, its version and licence, and whose work it builds on.
struct AboutView: View {
    static let credits: [(name: String, url: String, what: String)] = [
        ("boring.notch", "https://github.com/TheBoredTeam/boring.notch",
         "GPL-3.0. The notch outline's constants, and the idea of drawing in a SkyLight space of its own so the panel stays put through Spaces changes."),
        ("NotchNook", "https://lo.cafe/notchnook", "The same way of keeping a notch panel still across Spaces."),
        ("cmux", "https://cmux.dev", "The terminal Workspaces opens sessions in, through its socket and AppleScript."),
        ("Grove", "https://github.com/efim0v/grove",
         "Brow's companion app until 0.4: its Workspaces engine is now part of Brow, merged with its history."),
    ]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Brow").font(.title2.weight(.semibold))
                        Text("Version \(BrowVersion.current)").foregroundStyle(.secondary)
                        Text("Claude Code usage limits in the notch, and workspaces for parallel sessions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Licence") {
                    Link("GNU GPL v3", destination: URL(string: "https://github.com/efim0v/brow/blob/main/LICENSE")!)
                }
                LabeledContent("Source") {
                    Link("github.com/efim0v/brow", destination: URL(string: "https://github.com/efim0v/brow")!)
                }
            } footer: {
                Text("Coming from Grove? Grove is now part of Brow: your projects, accounts and settings come along, and Grove.app can go.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Built with and on") {
                ForEach(Self.credits, id: \.name) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Link(credit.name, destination: URL(string: credit.url)!)
                        Text(credit.what).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                Text("An independent tool, not affiliated with or endorsed by Anthropic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
