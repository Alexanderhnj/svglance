import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

final class SVGlanceAppState: ObservableObject {
    @Published var statusText = "Ready. Use Open SVG for a correct preview, or apply Finder icons to make white SVGs visible on the Desktop."
    @Published var approvedFolders: [SVGlanceApprovedFolder] = []

    var approvedFolderSummary: String {
        switch approvedFolders.count {
        case 0:
            return "No approved folders"
        case 1:
            return "Watching \(approvedFolders[0].name)"
        default:
            return "Watching \(approvedFolders.count) folders"
        }
    }
}

struct SVGlanceApprovedFolder: Identifiable, Hashable {
    let url: URL

    var id: String {
        url.standardizedFileURL.path
    }

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var path: String {
        url.path
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let automaticIconFolderBookmark = "SVGlanceAutomaticIconFolderBookmark"
        static let didShowFolderOnboarding = "SVGlanceDidShowFolderOnboarding"
    }

    private enum ReleaseLinks {
        static let projectURL = URL(string: "https://github.com/Alexanderhnj/svglance")!
        static let privacyURL = URL(string: "https://github.com/Alexanderhnj/svglance/blob/main/PRIVACY.md")!
    }

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let appState = SVGlanceAppState()
    private var viewerWindows: [SVGViewerWindowController] = []
    private var approvedFoldersWindow: NSWindowController?
    private var aboutWindow: NSWindowController?
    private var folderWatchers: [String: SVGlanceFolderWatcher] = [:]
    private var pendingFolderScans: [String: DispatchWorkItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerSVGViewerHandlers()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                state: appState,
                openSVG: { [weak self] in self?.chooseSVGToOpen() },
                applyIcons: { [weak self] in self?.chooseSVGsForIconApplication() },
                clearIcons: { [weak self] in self?.chooseSVGsForIconClearing() },
                addDesktop: { [weak self] in self?.approveStandardFolder(.desktopDirectory) },
                addDownloads: { [weak self] in self?.approveStandardFolder(.downloadsDirectory) },
                addFolder: { [weak self] in self?.chooseFolderToApprove() },
                rescanFolders: { [weak self] in self?.rescanApprovedFolders(trigger: .manual) },
                manageFolders: { [weak self] in self?.showApprovedFoldersWindow() },
                resetFolders: { [weak self] in self?.confirmResetApprovedFolders() },
                showAbout: { [weak self] in self?.showAboutWindow() }
            )
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "SVGlance")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        migrateLegacyAutomaticFolderIfNeeded()
        refreshApprovedFolderStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshWatchedFolders),
            name: SVGlanceViewerFolderAccess.didChangeNotification,
            object: nil
        )
        DispatchQueue.main.async { [weak self] in
            self?.showFirstRunFolderOnboardingIfNeeded()
            self?.rescanApprovedFolders(trigger: .launch)
            self?.refreshWatchedFolders()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "svg" {
            openSVGViewer(for: url)
        }
    }

    private func chooseSVGToOpen() {
        let panel = svgOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an SVG to preview with SVGlance."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        openSVGViewer(for: url)
    }

    private func chooseSVGsForIconApplication() {
        let panel = svgOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose SVG files or a folder. SVGlance will apply visible Finder icons."

        guard panel.runModal() == .OK else {
            return
        }

        withSecurityScopedAccess(to: panel.urls) {
            applyFinderIcons(to: collectSVGFiles(from: panel.urls))
        }
    }

    private func chooseSVGsForIconClearing() {
        let panel = svgOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose SVG files or a folder. SVGlance will remove custom Finder icons."

        guard panel.runModal() == .OK else {
            return
        }

        withSecurityScopedAccess(to: panel.urls) {
            clearFinderIcons(for: collectSVGFiles(from: panel.urls))
        }
    }

    private func showFirstRunFolderOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.didShowFolderOnboarding),
              approvedIconFolders().isEmpty else {
            return
        }

        UserDefaults.standard.set(true, forKey: DefaultsKey.didShowFolderOnboarding)

        let alert = NSAlert()
        alert.messageText = "Choose folders for SVG icons"
        alert.informativeText = "SVGlance can update existing SVGs and watch for new ones in folders you approve. Folder access stays local to this Mac; SVGlance does not collect or upload your files."
        alert.addButton(withTitle: "Choose Folder...")
        alert.addButton(withTitle: "Desktop")
        alert.addButton(withTitle: "Downloads")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            chooseFolderToApprove()
        case .alertSecondButtonReturn:
            approveStandardFolder(.desktopDirectory)
        case .alertThirdButtonReturn:
            approveStandardFolder(.downloadsDirectory)
        default:
            appState.statusText = "You can approve folders from the SVGlance menu bar icon anytime."
        }
    }

    private func chooseFolderToApprove(
        startingAt initialURL: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
        message: String = "Choose folders SVGlance may scan and watch for SVG files."
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = initialURL
        panel.message = message
        panel.prompt = "Approve Folder"

        guard panel.runModal() == .OK else {
            return
        }

        approveFolders(panel.urls, scanImmediately: true)
    }

    private func approveStandardFolder(_ directory: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            appState.statusText = "Could not find that folder."
            return
        }

        chooseFolderToApprove(
            startingAt: url.deletingLastPathComponent(),
            message: "Select \(url.lastPathComponent) to let SVGlance scan it now and watch it for new SVG files."
        )
    }

    private func approveFolders(_ urls: [URL], scanImmediately: Bool) {
        var approvedCount = 0
        var failedCount = 0

        for url in urls {
            if SVGlanceViewerFolderAccess.saveAccess(to: url) {
                approvedCount += 1
            } else {
                failedCount += 1
            }
        }

        refreshApprovedFolderStatus()
        refreshWatchedFolders()

        if scanImmediately {
            rescanApprovedFolders(trigger: .manual)
        } else if approvedCount > 0 {
            appState.statusText = "Approved \(approvedCount) folder\(approvedCount == 1 ? "" : "s")."
        }

        if failedCount > 0 {
            appState.statusText = "Approved \(approvedCount) folder\(approvedCount == 1 ? "" : "s"); \(failedCount) failed."
        }
    }

    private func showApprovedFoldersWindow() {
        if let window = approvedFoldersWindow?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSWindowController(
            window: NSWindow(
                contentViewController: NSHostingController(
                    rootView: ApprovedFoldersView(
                        state: appState,
                        addFolder: { [weak self] in self?.chooseFolderToApprove() },
                        removeFolders: { [weak self] ids in self?.removeApprovedFolders(withIDs: ids) },
                        rescanFolders: { [weak self] in self?.rescanApprovedFolders(trigger: .manual) },
                        close: { [weak self] in self?.approvedFoldersWindow?.close() }
                    )
                )
            )
        )

        controller.window?.title = "Approved Folders"
        controller.window?.styleMask = [.titled, .closable, .miniaturizable]
        controller.window?.isReleasedWhenClosed = false
        approvedFoldersWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAboutWindow() {
        if let window = aboutWindow?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let controller = NSWindowController(
            window: NSWindow(
                contentViewController: NSHostingController(
                    rootView: AboutSVGlanceView(
                        version: version,
                        build: build,
                        projectURL: ReleaseLinks.projectURL,
                        privacyURL: ReleaseLinks.privacyURL,
                        close: { [weak self] in self?.aboutWindow?.close() }
                    )
                )
            )
        )

        controller.window?.title = "About SVGlance"
        controller.window?.styleMask = [.titled, .closable]
        controller.window?.isReleasedWhenClosed = false
        aboutWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func confirmResetApprovedFolders() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all approved folders?"
        alert.informativeText = "SVGlance will stop watching approved folders. Existing custom Finder icons are not removed."
        alert.addButton(withTitle: "Forget Folders")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        resetApprovedFolders()
    }

    private func resetApprovedFolders() {
        for watcher in folderWatchers.values {
            watcher.stop()
        }
        folderWatchers.removeAll()
        pendingFolderScans.values.forEach { $0.cancel() }
        pendingFolderScans.removeAll()
        SVGlanceViewerFolderAccess.removeAllAccess()
        UserDefaults.standard.removeObject(forKey: DefaultsKey.automaticIconFolderBookmark)
        refreshApprovedFolderStatus()
        appState.statusText = "Forgot all approved folders. You can approve folders again anytime."
    }

    private func removeApprovedFolders(withIDs ids: Set<String>) {
        let folders = SVGlanceViewerFolderAccess.savedFolderURLs()
        for folder in folders where ids.contains(folder.standardizedFileURL.path) {
            SVGlanceViewerFolderAccess.removeAccess(to: folder)
        }

        refreshApprovedFolderStatus()
        refreshWatchedFolders()
        appState.statusText = ids.isEmpty ? "No approved folders selected." : "Removed \(ids.count) approved folder\(ids.count == 1 ? "" : "s")."
    }

    private func openSVGViewer(for url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        let controller = SVGViewerWindowController(url: url)
        if didAccess {
            url.stopAccessingSecurityScopedResource()
        }
        viewerWindows.append(controller)
        controller.window?.delegate = self
        controller.show()
        appState.statusText = "Opened \(url.lastPathComponent) in SVGlance."
    }

    private func applyFinderIcons(to urls: [URL]) {
        guard !urls.isEmpty else {
            appState.statusText = "No SVG files were selected."
            return
        }

        var successes = 0
        var failures = 0
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            if SVGIconRenderer.applyIcon(to: url) {
                successes += 1
            } else {
                failures += 1
            }
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        appState.statusText = failures == 0
            ? "Applied visible Finder icons to \(successes) SVG file\(successes == 1 ? "" : "s")."
            : "Applied \(successes) icon\(successes == 1 ? "" : "s"); \(failures) failed."
    }

    private func clearFinderIcons(for urls: [URL]) {
        guard !urls.isEmpty else {
            appState.statusText = "No SVG files were selected."
            return
        }

        var successes = 0
        var failures = 0
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            if SVGIconRenderer.clearIcon(for: url) {
                successes += 1
            } else {
                failures += 1
            }
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        appState.statusText = failures == 0
            ? "Cleared custom Finder icons from \(successes) SVG file\(successes == 1 ? "" : "s")."
            : "Cleared \(successes) icon\(successes == 1 ? "" : "s"); \(failures) failed."
    }

    private enum FolderScanTrigger {
        case launch
        case manual
    }

    private func rescanApprovedFolders(trigger: FolderScanTrigger) {
        let folders = approvedIconFolders()
        guard !folders.isEmpty else {
            if trigger == .manual {
                appState.statusText = "Approve a folder first."
            }
            return
        }

        var totalFiles = 0
        var totalSuccesses = 0

        for folder in folders {
            SVGlanceViewerFolderAccess.performWithAccess(to: folder) {
                let files = svgFiles(in: folder)
                totalFiles += files.count

                for url in files where SVGIconRenderer.applyIcon(to: url) {
                    totalSuccesses += 1
                }
            }
        }

        refreshApprovedFolderStatus()

        if totalFiles == 0 {
            appState.statusText = "No SVG files found in approved folders."
            return
        }

        appState.statusText = "Updated \(totalSuccesses) of \(totalFiles) SVG Finder icon\(totalFiles == 1 ? "" : "s")."
    }

    private func refreshApprovedFolderStatus() {
        appState.approvedFolders = approvedIconFolders().map(SVGlanceApprovedFolder.init(url:))
    }

    private func migrateLegacyAutomaticFolderIfNeeded() {
        guard let bookmark = UserDefaults.standard.data(forKey: DefaultsKey.automaticIconFolderBookmark) else {
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if !isStale {
                _ = SVGlanceViewerFolderAccess.saveAccess(to: url)
            }
        } catch {
            // Ignore invalid old bookmarks; the user can approve the folder again.
        }

        UserDefaults.standard.removeObject(forKey: DefaultsKey.automaticIconFolderBookmark)
    }

    private func svgOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if let svgType = UTType("public.svg-image") ?? UTType(filenameExtension: "svg") {
            panel.allowedContentTypes = [svgType]
        }
        return panel
    }

    private func collectSVGFiles(from urls: [URL]) -> [URL] {
        var results: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                results.append(contentsOf: svgFiles(in: url))
            } else if url.pathExtension.lowercased() == "svg" {
                results.append(url)
            }
        }

        return Array(Set(results)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func withSecurityScopedAccess(to urls: [URL], operation: () -> Void) {
        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        operation()
    }

    private func svgFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "svg" else {
                return nil
            }
            return url
        }
    }

    private func registerSVGViewerHandlers() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier as CFString? else {
            return
        }

        let contentTypes: [CFString] = [
            "com.svglance.svg" as CFString,
            "public.svg-image" as CFString
        ]

        for contentType in contentTypes {
            LSSetDefaultRoleHandlerForContentType(contentType, .viewer, bundleIdentifier)
        }
    }

    @objc private func refreshWatchedFolders() {
        refreshApprovedFolderStatus()
        let watchedFolders = approvedIconFolders()
        let watchedPaths = Set(watchedFolders.map { $0.standardizedFileURL.path })

        for path in folderWatchers.keys where !watchedPaths.contains(path) {
            folderWatchers[path]?.stop()
            folderWatchers[path] = nil
            pendingFolderScans[path]?.cancel()
            pendingFolderScans[path] = nil
        }

        for folder in watchedFolders {
            let path = folder.standardizedFileURL.path
            guard folderWatchers[path] == nil else {
                continue
            }

            let watcher = SVGlanceFolderWatcher(folderURL: folder) { [weak self] changedFolder in
                self?.scheduleIconRefresh(for: changedFolder)
            }

            if watcher.start() {
                folderWatchers[path] = watcher
                scheduleIconRefresh(for: folder)
            }
        }
    }

    private func approvedIconFolders() -> [URL] {
        var seenPaths = Set<String>()
        return SVGlanceViewerFolderAccess.savedFolderURLs().filter { folder in
            let path = folder.standardizedFileURL.path
            guard !seenPaths.contains(path) else {
                return false
            }

            seenPaths.insert(path)
            return true
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scheduleIconRefresh(for folder: URL) {
        let path = folder.standardizedFileURL.path
        pendingFolderScans[path]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshIcons(in: folder)
        }
        pendingFolderScans[path] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func refreshIcons(in folder: URL) {
        let path = folder.standardizedFileURL.path
        pendingFolderScans[path] = nil

        SVGlanceViewerFolderAccess.performWithAccess(to: folder) {
            let files = svgFiles(in: folder)
            guard !files.isEmpty else {
                return
            }

            var successes = 0
            for url in files where SVGIconRenderer.applyIcon(to: url) {
                successes += 1
            }

            if successes > 0 {
                appState.statusText = "Updated visible Finder icons in \(folder.lastPathComponent)."
            }
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else {
            return
        }
        viewerWindows.removeAll { $0.window === closedWindow }
    }
}

private final class SVGlanceFolderWatcher {
    private let folderURL: URL
    private let onChange: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var didAccess = false

    init(folderURL: URL, onChange: @escaping (URL) -> Void) {
        self.folderURL = folderURL
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard source == nil else {
            return true
        }

        didAccess = folderURL.startAccessingSecurityScopedResource()
        fileDescriptor = open(folderURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
                didAccess = false
            }
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            onChange(folderURL)
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }

            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
                didAccess = false
            }
        }

        self.source = source
        source.resume()
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
