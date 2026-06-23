import AppKit

enum SVGIconRenderer {
    static func icon(forFileAt url: URL, size: CGFloat = 1024) -> NSImage? {
        let document = SVGlanceSVGRenderer.svgData(forFileAt: url)

        if let message = document.fallbackMessage {
            return fallbackIcon(message: message, size: size)
        }

        guard let data = document.data, let image = NSImage(data: data) else {
            return fallbackIcon(message: "Could not render SVG", size: size)
        }

        return drawIcon(size: size) { rect in
            drawCheckerboard(in: rect, tile: size / 12)
            draw(image: image, in: rect)
        }
    }

    static func applyIcon(to url: URL, size: CGFloat = 1024) -> Bool {
        guard let icon = icon(forFileAt: url, size: size) else {
            return false
        }

        let didSetIcon = NSWorkspace.shared.setIcon(icon, forFile: url.path, options: [])
        if didSetIcon {
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        }

        return didSetIcon
    }

    static func clearIcon(for url: URL) -> Bool {
        let didClearIcon = NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
        if didClearIcon {
            NSWorkspace.shared.noteFileSystemChanged(url.path)
        }

        return didClearIcon
    }

    private static func fallbackIcon(message: String, size: CGFloat) -> NSImage {
        drawIcon(size: size) { rect in
            drawCheckerboard(in: rect, tile: size / 12)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 54, weight: .semibold),
                .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
                .paragraphStyle: paragraph
            ]

            NSString(string: message).draw(in: rect.insetBy(dx: 96, dy: 360), withAttributes: attributes)
        }
    }

    private static func drawIcon(size: CGFloat, drawing: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        drawing(NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        return image
    }

    private static func draw(image: NSImage, in rect: NSRect) {
        let target = aspectFitRect(for: image.size, in: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 38
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.34)
        shadow.set()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func aspectFitRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        let fallbackSide = max(1, min(rect.width, rect.height))
        let source = NSSize(
            width: imageSize.width > 0 ? imageSize.width : fallbackSide,
            height: imageSize.height > 0 ? imageSize.height : fallbackSide
        )
        let padding = min(rect.width, rect.height) * 0.12
        let available = NSSize(width: rect.width - padding * 2, height: rect.height - padding * 2)
        let scale = min(available.width / source.width, available.height / source.height)
        let target = NSSize(width: source.width * scale, height: source.height * scale)

        return NSRect(
            x: rect.midX - target.width / 2,
            y: rect.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
    }

    private static func drawCheckerboard(in rect: NSRect, tile: CGFloat) {
        NSColor(calibratedRed: 0.784, green: 0.784, blue: 0.784, alpha: 1).setFill()
        rect.fill()

        NSColor(calibratedRed: 0.627, green: 0.627, blue: 0.627, alpha: 1).setFill()
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : tile)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile * 2
            }
            row += 1
            y += tile
        }
    }
}
