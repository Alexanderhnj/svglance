import AppKit

final class SVGViewerWindowController: NSWindowController {
    private var currentURL: URL
    private var folderSVGs: [URL] = []

    private let canvasView = SVGCanvasView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let metadataText = NSTextField(wrappingLabelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let rotationLabel = NSTextField(labelWithString: "0 deg")

    init(url: URL) {
        currentURL = url

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent

        super.init(window: window)
        window.contentView = makeContentView()
        window.center()

        reloadFolderList()
        load(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContentView() -> NSView {
        let toolbar = makeToolbar()

        let sidebar = makeSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(toolbar)
        container.addSubview(sidebar)
        container.addSubview(canvasView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 46),

            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 280),

            canvasView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvasView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func makeToolbar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(button(title: "−", toolTip: "Zoom out", action: #selector(zoomOut)))
        stack.addArrangedSubview(zoomLabel)
        stack.addArrangedSubview(button(title: "+", toolTip: "Zoom in", action: #selector(zoomIn)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button(title: "↺", toolTip: "Rotate left", action: #selector(rotateLeft)))
        stack.addArrangedSubview(rotationLabel)
        stack.addArrangedSubview(button(title: "↻", toolTip: "Rotate right", action: #selector(rotateRight)))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button(title: "Reset", toolTip: "Reset zoom and rotation", action: #selector(resetView)))
        stack.addArrangedSubview(button(title: "Save PNG...", toolTip: "Save the current visual view as a PNG", action: #selector(savePNG)))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        rotationLabel.alignment = .center
        rotationLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        return stack
    }

    private func makeSidebar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Folder SVGs")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedSVG)
        tableView.usesAlternatingRowBackgroundColors = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        stack.addArrangedSubview(scrollView)

        let metadataTitle = NSTextField(labelWithString: "Metadata")
        metadataTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(metadataTitle)

        metadataText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadataText.textColor = .secondaryLabelColor
        stack.addArrangedSubview(metadataText)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func button(title: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = toolTip
        return button
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func reloadFolderList() {
        let folder = currentURL.deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            folderSVGs = [currentURL]
            tableView.reloadData()
            return
        }

        folderSVGs = enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "svg" else {
                return nil
            }
            return url
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        tableView.reloadData()
        if let selectedIndex = folderSVGs.firstIndex(of: currentURL) {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    private func load(_ url: URL) {
        currentURL = url
        window?.title = url.lastPathComponent

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let document = SVGlanceViewerFolderAccess.performWithSavedAccess(containing: url) {
            SVGlanceSVGRenderer.svgData(forFileAt: url)
        }

        if let message = document.fallbackMessage {
            canvasView.renderState = .message(message)
            updateMetadata(for: url, image: nil)
            return
        }

        guard let data = document.data, let image = NSImage(data: data) else {
            canvasView.renderState = .message("Could not render SVG")
            updateMetadata(for: url, image: nil)
            return
        }

        canvasView.renderState = .image(image)
        updateMetadata(for: url, image: image)
        updateControlLabels()
    }

    private func updateMetadata(for url: URL, image: NSImage?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let sizeText = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unknown"
        let imageSize = image.map { "\(Int($0.size.width)) × \(Int($0.size.height)) pt" } ?? "Unknown"

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let modified = values?.contentModificationDate.map { formatter.string(from: $0) } ?? "Unknown"
        let created = values?.creationDate.map { formatter.string(from: $0) } ?? "Unknown"

        metadataText.stringValue = """
        Name: \(url.lastPathComponent)
        Size: \(sizeText)
        Image: \(imageSize)
        Created: \(created)
        Modified: \(modified)
        """
    }

    private func updateControlLabels() {
        zoomLabel.stringValue = "\(Int((canvasView.zoom * 100).rounded()))%"
        rotationLabel.stringValue = "\(Int(canvasView.rotationDegrees.rounded())) deg"
    }

    @objc private func openSelectedSVG() {
        let row = tableView.selectedRow
        guard row >= 0, row < folderSVGs.count else {
            return
        }

        let selectedURL = folderSVGs[row]
        if selectedURL != currentURL && !SVGlanceViewerFolderAccess.hasSavedAccess(containing: selectedURL) {
            guard requestFolderAccess(for: selectedURL) else {
                canvasView.renderState = .message("Allow folder access to preview other SVGs in this folder")
                updateMetadata(for: selectedURL, image: nil)
                return
            }
        }

        canvasView.resetTransform()
        load(selectedURL)
    }

    private func requestFolderAccess(for url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.nameFieldStringValue = folder.lastPathComponent
        panel.message = "Allow SVGlance to read this folder so the sidebar can preview every SVG inside it."
        panel.prompt = "Allow Folder"

        guard panel.runModal() == .OK, let selectedFolder = panel.url else {
            return false
        }

        let requestedPath = folder.standardizedFileURL.path
        let selectedPath = selectedFolder.standardizedFileURL.path
        guard requestedPath == selectedPath || requestedPath.hasPrefix(selectedPath + "/") else {
            return false
        }

        guard SVGlanceViewerFolderAccess.saveAccess(to: selectedFolder),
              SVGlanceViewerFolderAccess.canRead(fileURL: url) else {
            return false
        }

        return true
    }

    @objc private func zoomIn() {
        canvasView.zoom = min(8, canvasView.zoom * 1.25)
        updateControlLabels()
    }

    @objc private func zoomOut() {
        canvasView.zoom = max(0.1, canvasView.zoom / 1.25)
        updateControlLabels()
    }

    @objc private func rotateLeft() {
        canvasView.rotationDegrees -= 90
        updateControlLabels()
    }

    @objc private func rotateRight() {
        canvasView.rotationDegrees += 90
        updateControlLabels()
    }

    @objc private func resetView() {
        canvasView.resetTransform()
        updateControlLabels()
    }

    @objc private func savePNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = currentURL.deletingPathExtension().lastPathComponent + ".png"

        guard panel.runModal() == .OK, let outputURL = panel.url else {
            return
        }

        guard let png = canvasView.transparentPNGData() else {
            return
        }

        try? png.write(to: outputURL)
    }
}

extension SVGViewerWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        folderSVGs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < folderSVGs.count else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("SVGCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        if cell.textField == nil {
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = folderSVGs[row].lastPathComponent
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openSelectedSVG()
    }
}

private final class SVGCanvasView: NSView {
    enum RenderState {
        case image(NSImage)
        case message(String)
    }

    var renderState: RenderState = .message("Loading SVG") {
        didSet {
            needsDisplay = true
        }
    }

    var zoom: CGFloat = 1 {
        didSet {
            needsDisplay = true
        }
    }

    var rotationDegrees: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func resetTransform() {
        zoom = 1
        rotationDegrees = 0
    }

    func transparentPNGData() -> Data? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(NSRect(origin: .zero, size: bounds.size))

        if case .image(let image) = renderState {
            draw(image: image, in: NSRect(origin: .zero, size: bounds.size))
        }

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawCheckerboard(in: bounds)

        switch renderState {
        case .image(let image):
            draw(image: image, in: bounds)
        case .message(let message):
            draw(message: message, in: bounds)
        }
    }

    private func draw(image: NSImage, in rect: NSRect) {
        let target = aspectFitRect(for: image.size, in: rect)

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x: rect.midX, y: rect.midY)
        context?.rotate(by: rotationDegrees * .pi / 180)
        context?.scaleBy(x: zoom, y: zoom)

        let transformedTarget = NSRect(
            x: -target.width / 2,
            y: -target.height / 2,
            width: target.width,
            height: target.height
        )

        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 12
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.34)
        shadow.set()
        image.draw(in: transformedTarget, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(message: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
            .paragraphStyle: paragraph
        ]

        let textSize = NSString(string: message).boundingRect(
            with: NSSize(width: rect.width * 0.7, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        ).size

        let textRect = NSRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        NSString(string: message).draw(in: textRect, withAttributes: attributes)
    }

    private func aspectFitRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        let fallbackSide = max(1, min(rect.width, rect.height))
        let source = NSSize(
            width: imageSize.width > 0 ? imageSize.width : fallbackSide,
            height: imageSize.height > 0 ? imageSize.height : fallbackSide
        )
        let padding = max(24, min(rect.width, rect.height) * 0.06)
        let available = NSSize(width: max(1, rect.width - padding * 2), height: max(1, rect.height - padding * 2))
        let scale = min(available.width / source.width, available.height / source.height)
        let target = NSSize(width: source.width * scale, height: source.height * scale)

        return NSRect(
            x: rect.midX - target.width / 2,
            y: rect.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
    }

    private func drawCheckerboard(in rect: NSRect) {
        NSColor(calibratedRed: 0.784, green: 0.784, blue: 0.784, alpha: 1).setFill()
        rect.fill()

        NSColor(calibratedRed: 0.627, green: 0.627, blue: 0.627, alpha: 1).setFill()
        let tile: CGFloat = 20
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

enum SVGlanceViewerFolderAccess {
    static let didChangeNotification = Notification.Name("SVGlanceViewerFolderAccessDidChange")
    private static let defaultsKey = "SVGlanceViewerFolderAccessBookmarks"

    static func hasSavedAccess(containing fileURL: URL) -> Bool {
        canRead(fileURL: fileURL)
    }

    static func saveAccess(to folderURL: URL) -> Bool {
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmark = try folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            var bookmarks = storedBookmarks()
            bookmarks[folderURL.standardizedFileURL.path] = bookmark
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    static func savedFolderURLs() -> [URL] {
        storedBookmarks().compactMap { bookmarkPath, bookmark in
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    removeBookmark(path: bookmarkPath)
                    return nil
                }

                return url
            } catch {
                removeBookmark(path: bookmarkPath)
                return nil
            }
        }
    }

    static func removeAccess(to folderURL: URL) {
        removeBookmark(path: folderURL.standardizedFileURL.path)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func removeAllAccess() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func canRead(fileURL: URL) -> Bool {
        performWithSavedAccess(containing: fileURL) {
            FileManager.default.isReadableFile(atPath: fileURL.path)
        }
    }

    static func performWithSavedAccess<T>(containing fileURL: URL, operation: () -> T) -> T {
        guard let folderURL = accessURL(containing: fileURL) else {
            return operation()
        }

        return performWithAccess(to: folderURL, operation: operation)
    }

    static func performWithAccess<T>(to folderURL: URL, operation: () -> T) -> T {
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        return operation()
    }

    private static func accessURL(containing fileURL: URL) -> URL? {
        let filePath = fileURL.standardizedFileURL.path

        for (bookmarkPath, bookmark) in storedBookmarks().sorted(by: { $0.key.count > $1.key.count }) {
            guard filePath.hasPrefix(bookmarkPath + "/") else {
                continue
            }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    removeBookmark(path: bookmarkPath)
                    continue
                }

                return url
            } catch {
                removeBookmark(path: bookmarkPath)
            }
        }

        return nil
    }

    private static func storedBookmarks() -> [String: Data] {
        let rawBookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        return rawBookmarks.compactMapValues { $0 as? Data }
    }

    private static func removeBookmark(path: String) {
        var bookmarks = storedBookmarks()
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
