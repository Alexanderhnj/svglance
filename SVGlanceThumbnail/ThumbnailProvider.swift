import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let document = SVGlanceSVGRenderer.svgData(forFileAt: request.fileURL)
        let contextSize = normalizedSize(request.maximumSize)

        if let message = document.fallbackMessage {
            handler(fallbackReply(size: contextSize, message: message), nil)
            return
        }

        guard let data = document.data, let image = NSImage(data: data) else {
            handler(fallbackReply(size: contextSize, message: "Could not render SVG"), nil)
            return
        }

        handler(QLThumbnailReply(contextSize: contextSize, currentContextDrawing: {
            SVGlanceThumbnailDrawing.draw(image: image, in: NSRect(origin: .zero, size: contextSize))
            return true
        }), nil)
    }

    private func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    private func fallbackReply(size: CGSize, message: String) -> QLThumbnailReply {
        QLThumbnailReply(contextSize: size, currentContextDrawing: {
            SVGlanceThumbnailDrawing.draw(in: NSRect(origin: .zero, size: size), message: message)
            return true
        })
    }
}

private enum SVGlanceThumbnailDrawing {
    static func draw(image: NSImage, in rect: NSRect) {
        drawCheckerboard(in: rect)

        let targetRect = aspectFitRect(for: image.size, in: rect)
        NSGraphicsContext.saveGraphicsState()

        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.3)
        shadow.set()

        image.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func draw(in rect: NSRect, message: String) {
        drawCheckerboard(in: rect)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(14, rect.width / 10)), weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
            .paragraphStyle: paragraph
        ]

        let inset = max(8, min(rect.width, rect.height) * 0.12)
        let textRect = rect.insetBy(dx: inset, dy: inset)
        NSString(string: message).draw(in: textRect, withAttributes: attributes)
    }

    private static func aspectFitRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        let fallbackSide = max(1, min(rect.width, rect.height))
        let sourceSize = NSSize(
            width: imageSize.width > 0 ? imageSize.width : fallbackSide,
            height: imageSize.height > 0 ? imageSize.height : fallbackSide
        )
        let padding = max(4, min(rect.width, rect.height) * 0.10)
        let available = NSSize(width: max(1, rect.width - padding * 2), height: max(1, rect.height - padding * 2))
        let scale = min(available.width / sourceSize.width, available.height / sourceSize.height)
        let targetSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return NSRect(
            x: rect.midX - targetSize.width / 2,
            y: rect.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    private static func drawCheckerboard(in rect: NSRect) {
        NSColor(calibratedRed: 0.784, green: 0.784, blue: 0.784, alpha: 1).setFill()
        rect.fill()

        NSColor(calibratedRed: 0.627, green: 0.627, blue: 0.627, alpha: 1).setFill()
        let tile: CGFloat = 10
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
