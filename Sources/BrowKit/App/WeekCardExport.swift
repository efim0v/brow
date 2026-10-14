import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "my week" card as a PNG: on the clipboard from the panel's footer, or in a file
/// from Settings. Drawn on this Mac; nothing is sent anywhere.
@MainActor
enum WeekCardExport {
    /// The card for what the panel shows right now, in the shape Settings picked.
    static func png(store: LimitsStore, now: Date) -> Data? {
        let shape = store.settings.cardShape
        return png(WeekCardModel.make(rows: store.rows, aggregate: store.aggregate, settings: store.settings,
                                      shape: shape, now: now),
                   shape: shape)
    }

    /// 1200 × 630 or 1080 × 1080: the card's points at scale 2.
    static func png(_ model: WeekCardModel, shape: CardShape) -> Data? {
        let size = shape.points
        let renderer = ImageRenderer(content: WeekCardView(model: model, shape: shape)
            .frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            BrowLog.panel.error("week card: nothing rendered for the \(shape.rawValue, privacy: .public) shape")
            return nil
        }
        return data
    }

    /// One pasteboard item carrying both PNG and TIFF: chats and browsers take the
    /// PNG, older AppKit apps only read TIFF. Works from the non-activating panel.
    static func copy(_ png: Data) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// From Settings only: that window can become key, which a save panel needs and
    /// the non-activating notch panel cannot give it.
    static func save(_ png: Data, now: Date = Date()) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName(now: now)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic) }
            catch { BrowLog.panel.error("week card: save failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// "Claude Code usage 2026-10-15.png".
    static func fileName(now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return "Claude Code usage \(f.string(from: now)).png"
    }
}
