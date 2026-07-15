import AppKit

/// Draws the menu bar status-item label into a single `NSImage`. `MenuBarExtra`
/// clips multi-line SwiftUI labels to the bar height, so we render the icon plus
/// a two-line up/down speed readout ourselves and hand the status item one image.
///
/// The result is a template image (drawn in black + alpha) so the menu bar tints
/// it correctly in light and dark appearances.
enum MenuBarRenderer {

    /// Point size chosen to fit within the ~22pt menu bar with a little padding.
    /// `labelImage` and `iconImage` share `iconPointSize` so the shield doesn't
    /// shrink when speed monitoring turns on.
    private static let height: CGFloat = 20
    private static let iconPointSize: CGFloat = 18
    private static let fontSize: CGFloat = 9
    private static let gap: CGFloat = 3

    /// The blink's dim opacity. A template image ignores per-pixel alpha (the
    /// menu bar repaints it a solid tint), so a dimmed image is rendered as a
    /// NON-template image tinted with the menu bar's current text color at this
    /// alpha — that's what makes the fade actually visible.
    private static let dimAlpha: CGFloat = 0.28

    static func labelImage(symbol: String, up: String, down: String, dimmed: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let arrowUp = "↑"
        let arrowDown = "↓"

        // Fixed text-column width so the menu bar item doesn't jitter as the
        // numbers change. Sized to the widest realistic value — at most three
        // digits plus a decimal point ("9.99MB/s") — plus the arrow and a hair
        // of spacing (`arrowGap`) between them; monospaced digits keep every
        // value within the column.
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineMetrics = (arrowUp as NSString).size(withAttributes: attrs)
        let arrowWidth = ceil((arrowDown as NSString).size(withAttributes: attrs).width)
        let arrowGap: CGFloat = 1
        let textWidth = arrowWidth + arrowGap + ceil(("9.99MB/s" as NSString).size(withAttributes: attrs).width)

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
        let lineHeight = ceil(lineMetrics.height)
        // Center the two-line block vertically.
        let blockHeight = lineHeight * 2
        let topY = height - (height - blockHeight) / 2 - lineHeight
        // Arrows sit flush-left in the text column, right after the shield; the
        // numeric value is right-aligned within the column so the arrows line up
        // under each other and the numbers hug the right edge without jitter as
        // values change. The column is only as wide as the widest value plus the
        // arrow, so even at that width the number stays close to its arrow.
        let columnRight = textX + textWidth
        let upValSize = (up as NSString).size(withAttributes: attrs)
        let downValSize = (down as NSString).size(withAttributes: attrs)
        let upY = topY
        let downY = topY - lineHeight + 1
        (arrowUp as NSString).draw(at: NSPoint(x: textX, y: upY), withAttributes: textAttrs)
        (arrowDown as NSString).draw(at: NSPoint(x: textX, y: downY), withAttributes: textAttrs)
        (up as NSString).draw(at: NSPoint(x: columnRight - ceil(upValSize.width), y: upY), withAttributes: textAttrs)
        (down as NSString).draw(at: NSPoint(x: columnRight - ceil(downValSize.width), y: downY), withAttributes: textAttrs)

        image.unlockFocus()
        image.isTemplate = true   // menu bar tints it for light/dark appearance
        return dimmed ? dim(image) : image
    }

    /// A standalone icon (no speed text), sized to match `labelImage`'s shield so
    /// the icon doesn't change size when speed is toggled. `dimmed` fades it for
    /// the connecting/reconnecting blink.
    static func iconImage(symbol: String, dimmed: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tunnel Proxy")?
            .withSymbolConfiguration(config) ?? NSImage()
        base.isTemplate = true
        return dimmed ? dim(base) : base
    }

    /// Re-render a template image as a non-template image tinted with the menu
    /// bar's text color at `dimAlpha`. Template images ignore alpha, so this is
    /// the only way to make the icon look faded.
    private static func dim(_ template: NSImage) -> NSImage {
        let size = template.size
        let out = NSImage(size: size)
        out.lockFocus()
        // `textColor` follows the active light/dark appearance; the fresh focus
        // context adopts the app's effective appearance so the tint matches.
        NSColor.textColor.withAlphaComponent(dimAlpha).set()
        let rect = NSRect(origin: .zero, size: size)
        rect.fill()
        // Keep only where the template has coverage, tinting it.
        template.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)
        out.unlockFocus()
        out.isTemplate = false   // preserve our alpha; don't let the bar recolor it
        return out
    }
}
