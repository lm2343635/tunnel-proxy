import AppKit

/// Draws the menu bar status-item label into a single `NSImage`. `MenuBarExtra`
/// clips multi-line SwiftUI labels to the bar height, so we render the icon plus
/// a two-line up/down speed readout ourselves and hand the status item one image.
///
/// The result is a template image (drawn in black + alpha) so the menu bar tints
/// it correctly in light and dark appearances.
enum MenuBarRenderer {

    /// Point size chosen to fit within the ~22pt menu bar with a little padding.
    private static let height: CGFloat = 18
    private static let iconPointSize: CGFloat = 16
    private static let fontSize: CGFloat = 9
    private static let gap: CGFloat = 4

    static func labelImage(symbol: String, up: String, down: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let upStr = "↑ \(up)"
        let downStr = "↓ \(down)"

        // Fixed text-column width so the menu bar item doesn't jitter as the
        // numbers change. Sized to the widest realistic rate ("99.9 MB/s");
        // monospaced digits keep every value within it.
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let upSize = (upStr as NSString).size(withAttributes: attrs)
        let textWidth = ceil(("↓ 99.9 MB/s" as NSString).size(withAttributes: attrs).width)

        let iconWidth = iconPointSize
        let totalWidth = iconWidth + gap + textWidth
        let size = NSSize(width: totalWidth, height: height)

        let image = NSImage(size: size)
        image.lockFocus()

        // Draw the shield symbol on the left, vertically centered.
        if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .regular)) {
            let iconRect = NSRect(
                x: 0,
                y: (height - iconPointSize) / 2,
                width: iconWidth,
                height: iconPointSize)
            symbolImage.draw(in: iconRect)
        }

        // Draw the two speed lines, upload on top, download on bottom.
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textX = iconWidth + gap
        let lineHeight = ceil(upSize.height)
        // Center the two-line block vertically.
        let blockHeight = lineHeight * 2
        let topY = height - (height - blockHeight) / 2 - lineHeight
        (upStr as NSString).draw(at: NSPoint(x: textX, y: topY), withAttributes: textAttrs)
        (downStr as NSString).draw(at: NSPoint(x: textX, y: topY - lineHeight + 1), withAttributes: textAttrs)

        image.unlockFocus()
        image.isTemplate = true   // menu bar tints it for light/dark appearance
        return image
    }
}
