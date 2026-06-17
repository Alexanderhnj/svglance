import Foundation

struct SVGlanceRenderDocument {
    let html: String
    let fallbackMessage: String?
}

struct SVGlanceSVGDataDocument {
    let data: Data?
    let fallbackMessage: String?
}

private enum SVGlanceNormalizedSVGMarkup {
    case success(String)
    case failure(String)
}

enum SVGlanceSVGRenderer {
    static let maxFileSize = 10 * 1024 * 1024

    static func document(forFileAt url: URL) -> SVGlanceRenderDocument {
        switch normalizedSVGMarkup(forFileAt: url) {
        case .success(let normalized):
            return SVGlanceRenderDocument(html: htmlDocument(svgData: Data(normalized.utf8)), fallbackMessage: nil)
        case .failure(let message):
            return messageDocument(message)
        }
    }

    static func svgData(forFileAt url: URL) -> SVGlanceSVGDataDocument {
        switch normalizedSVGMarkup(forFileAt: url) {
        case .success(let normalized):
            return SVGlanceSVGDataDocument(data: Data(normalized.utf8), fallbackMessage: nil)
        case .failure(let message):
            return SVGlanceSVGDataDocument(data: nil, fallbackMessage: message)
        }
    }

    static func messageDocument(_ message: String) -> SVGlanceRenderDocument {
        SVGlanceRenderDocument(html: messageHTML(message), fallbackMessage: message)
    }

    static func ensureSVGHasViewBox(_ svg: String) -> String {
        guard let rootRange = svg.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            return svg
        }

        let rootTag = String(svg[rootRange])
        guard rootTag.range(of: #"\bviewBox\s*="#, options: [.regularExpression, .caseInsensitive]) == nil,
              let width = numericAttribute("width", in: rootTag),
              let height = numericAttribute("height", in: rootTag),
              width > 0,
              height > 0 else {
            return svg
        }

        let viewBox = String(format: #" viewBox="0 0 %.12g %.12g""#, width, height)
        let updatedRoot = rootTag.replacingOccurrences(of: ">", with: "\(viewBox)>")
        return svg.replacingCharacters(in: rootRange, with: updatedRoot)
    }

    private static func normalizedSVGMarkup(forFileAt url: URL) -> SVGlanceNormalizedSVGMarkup {
        do {
            if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               fileSize > maxFileSize {
                return .failure("File too large to preview")
            }

            let data = try Data(contentsOf: url)
            guard data.count <= maxFileSize else {
                return .failure("File too large to preview")
            }

            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return .failure("Could not render SVG")
            }

            let sanitized = stripScripts(from: decoded)
            guard containsSVGRoot(sanitized), isWellFormedXML(sanitized) else {
                return .failure("Could not render SVG")
            }

            return .success(normalizeRootSVGAttributes(ensureSVGHasViewBox(sanitized)))
        } catch {
            return .failure("Could not render SVG")
        }
    }

    private static func stripScripts(from svg: String) -> String {
        let blockPattern = #"(?is)<script\b[^>]*>.*?</script\s*>"#
        let selfClosingPattern = #"(?is)<script\b[^>]*/\s*>"#
        return svg
            .replacingOccurrences(of: blockPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: selfClosingPattern, with: "", options: .regularExpression)
    }

    private static func normalizeRootSVGAttributes(_ svg: String) -> String {
        guard let rootRange = svg.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            return svg
        }

        var rootTag = String(svg[rootRange])
        rootTag = rootTag.replacingOccurrences(
            of: #"\s+preserveAspectRatio\s*=\s*(['"]).*?\1"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let replacement = rootTag.replacingOccurrences(of: ">", with: #" preserveAspectRatio="xMidYMid meet">"#)
        return svg.replacingCharacters(in: rootRange, with: replacement)
    }

    private static func containsSVGRoot(_ svg: String) -> Bool {
        svg.range(of: #"<svg\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isWellFormedXML(_ svg: String) -> Bool {
        let data = Data(svg.utf8)
        let parser = XMLParser(data: data)
        let delegate = SVGlanceXMLParserDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !delegate.didFail
    }

    private static func numericAttribute(_ name: String, in rootTag: String) -> Double? {
        let pattern = #"\b\#(name)\s*=\s*(['"])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(rootTag.startIndex..<rootTag.endIndex, in: rootTag)
        guard let match = regex.firstMatch(in: rootTag, range: range),
              match.numberOfRanges >= 4,
              let valueRange = Range(match.range(at: 3), in: rootTag) else {
            return nil
        }

        let value = String(rootTag[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numberMatch = value.range(of: #"^[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else {
            return nil
        }

        return Double(value[numberMatch])
    }

    private static func htmlDocument(svgData: Data) -> String {
        let base64 = svgData.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
        <style>
        html, body {
            width: 100%;
            height: 100%;
            margin: 0;
            overflow: hidden;
        }
        body {
            display: grid;
            place-items: center;
            background-color: #c8c8c8;
            background-image:
                linear-gradient(45deg, #a0a0a0 25%, transparent 25%),
                linear-gradient(-45deg, #a0a0a0 25%, transparent 25%),
                linear-gradient(45deg, transparent 75%, #a0a0a0 75%),
                linear-gradient(-45deg, transparent 75%, #a0a0a0 75%);
            background-size: 20px 20px;
            background-position: 0 0, 0 10px, 10px -10px, -10px 0;
        }
        .svg-stage {
            width: 90vw;
            height: 90vh;
            display: grid;
            place-items: center;
        }
        .svg-image {
            display: block;
            width: 100%;
            height: 100%;
            object-fit: contain;
            filter: drop-shadow(0px 2px 8px rgba(0,0,0,0.3));
        }
        </style>
        </head>
        <body>
        <div class="svg-stage">
        <img class="svg-image" src="data:image/svg+xml;base64,\(base64)" alt="">
        </div>
        </body>
        </html>
        """
    }

    private static func messageHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html, body {
            width: 100%;
            height: 100%;
            margin: 0;
            overflow: hidden;
        }
        body {
            display: grid;
            place-items: center;
            font: -apple-system-body;
            color: #111827;
            background-color: #c8c8c8;
            background-image:
                linear-gradient(45deg, #a0a0a0 25%, transparent 25%),
                linear-gradient(-45deg, #a0a0a0 25%, transparent 25%),
                linear-gradient(45deg, transparent 75%, #a0a0a0 75%),
                linear-gradient(-45deg, transparent 75%, #a0a0a0 75%);
            background-size: 20px 20px;
            background-position: 0 0, 0 10px, 10px -10px, -10px 0;
        }
        .message {
            padding: 10px 14px;
            border-radius: 8px;
            background: rgba(255,255,255,0.84);
            box-shadow: 0 2px 8px rgba(0,0,0,0.18);
        }
        </style>
        </head>
        <body>
        <div class="message">\(escapeHTML(message))</div>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class SVGlanceXMLParserDelegate: NSObject, XMLParserDelegate {
    var didFail = false

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        didFail = true
    }
}
