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
        static let feedbackURL = URL(string: "https://svglance.vercel.app/#feedback")!
    }

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let appState = SVGlanceAppState()
    private var viewerWindows: [SVGViewerWindowController] = []
    private var approvedFoldersWindow: NSWindowController?
    private var aboutWindow: NSWindowController?
    private var folderWatchers: [String: SVGlanceFolderWatcher] = [:]
    private var pendingFolderScans: [String: DispatchWorkItem] = [:]
    private var currentIconScan: SVGlanceIconScanCancellation?
    private let iconProcessingQueue = DispatchQueue(label: "com.svglance.icon-processing", qos: .utility)

    private enum ScanLimit {
        static let maxEntriesPerFolder = 25_000
        static let maxSVGsPerFolder = 600
        static let maxManualSVGs = 1_000
        static let watcherDebounceSeconds = 2.0
    }

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
                shareFeedback: { [weak self] in self?.openFeedbackPage() },
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

        applyFinderIcons(from: panel.urls)
    }

    private func chooseSVGsForIconClearing() {
        let panel = svgOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose SVG files or a folder. SVGlance will remove custom Finder icons."

        guard panel.runModal() == .OK else {
            return
        }

        clearFinderIcons(from: panel.urls)
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
            rescanApprovedFolders(trigger: .approval)
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

    private func openFeedbackPage() {
        NSWorkspace.shared.open(ReleaseLinks.feedbackURL)
        appState.statusText = "Opened the SVGlance feedback form."
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

    private func applyFinderIcons(from urls: [URL]) {
        processSelectedSVGs(from: urls, actionName: "Applied") { url in
            SVGIconRenderer.applyIcon(to: url, size: 512)
        }
    }

    private func clearFinderIcons(from urls: [URL]) {
        processSelectedSVGs(from: urls, actionName: "Cleared") { url in
            SVGIconRenderer.clearIcon(for: url)
        }
    }

    private enum FolderScanTrigger {
        case approval
        case manual
        case watcher
    }

    private func rescanApprovedFolders(trigger: FolderScanTrigger) {
        let folders = approvedIconFolders()
        guard !folders.isEmpty else {
            if trigger == .manual {
                appState.statusText = "Approve a folder first."
            }
            return
        }

        let cancellation = startNewIconScan()
        let folderNames = folders.map(\.lastPathComponent).joined(separator: ", ")
        appState.statusText = "Scanning \(folderNames) in the background..."

        iconProcessingQueue.async { [weak self] in
            guard let self else {
                return
            }

            var totalFiles = 0
            var totalSuccesses = 0
            var didHitLimit = false

            for folder in folders {
                if cancellation.isCancelled {
                    return
                }

                SVGlanceViewerFolderAccess.performWithAccess(to: folder) {
                    let scan = self.svgFiles(
                        in: folder,
                        maxEntries: ScanLimit.maxEntriesPerFolder,
                        maxSVGs: ScanLimit.maxSVGsPerFolder,
                        cancellation: cancellation
                    )
                    totalFiles += scan.urls.count
                    didHitLimit = didHitLimit || scan.didHitEntryLimit || scan.didHitFileLimit

                    for url in scan.urls {
                        if cancellation.isCancelled {
                            return
                        }

                        autoreleasepool {
                            if SVGIconRenderer.applyIcon(to: url, size: 512) {
                                totalSuccesses += 1
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentIconScan === cancellation, !cancellation.isCancelled else {
                    return
                }

                self.currentIconScan = nil
                self.refreshApprovedFolderStatus()

                if totalFiles == 0 {
                    self.appState.statusText = "No SVG files found in approved folders."
                    return
                }

                let limitNote = didHitLimit ? " Scan was capped to keep SVGlance responsive; choose a more specific folder if some SVGs were skipped." : ""
                self.appState.statusText = "Updated \(totalSuccesses) of \(totalFiles) SVG Finder icon\(totalFiles == 1 ? "" : "s").\(limitNote)"
            }
        }
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
                let scan = svgFiles(
                    in: url,
                    maxEntries: ScanLimit.maxEntriesPerFolder,
                    maxSVGs: ScanLimit.maxManualSVGs
                )
                results.append(contentsOf: scan.urls)
            } else if url.pathExtension.lowercased() == "svg" {
                results.append(url)
            }
        }

        return Array(Set(results)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func withSecurityScopedAccess<T>(to urls: [URL], operation: () -> T) -> T {
        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return operation()
    }

    private func processSelectedSVGs(from urls: [URL], actionName: String, operation: @escaping (URL) -> Bool) {
        let cancellation = startNewIconScan()
        appState.statusText = "\(actionName) SVG icons in the background..."

        iconProcessingQueue.async { [weak self] in
            guard let self else {
                return
            }

            let files: [URL] = withSecurityScopedAccess(to: urls) {
                self.collectSVGFiles(from: urls)
            }

            guard !files.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    guard self?.currentIconScan === cancellation else {
                        return
                    }
                    self?.currentIconScan = nil
                    self?.appState.statusText = "No SVG files were selected."
                }
                return
            }

            var successes = 0
            var failures = 0

            for url in files {
                if cancellation.isCancelled {
                    return
                }

                let didAccess = url.startAccessingSecurityScopedResource()
                autoreleasepool {
                    if operation(url) {
                        successes += 1
                    } else {
                        failures += 1
                    }
                }
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentIconScan === cancellation, !cancellation.isCancelled else {
                    return
                }

                self.currentIconScan = nil
                self.appState.statusText = failures == 0
                    ? "\(actionName) visible Finder icons for \(successes) SVG file\(successes == 1 ? "" : "s")."
                    : "\(actionName) \(successes) icon\(successes == 1 ? "" : "s"); \(failures) failed."
            }
        }
    }

    private func startNewIconScan() -> SVGlanceIconScanCancellation {
        currentIconScan?.cancel()
        let cancellation = SVGlanceIconScanCancellation()
        currentIconScan = cancellation
        return cancellation
    }

    private struct SVGFolderScan {
        let urls: [URL]
        let didHitEntryLimit: Bool
        let didHitFileLimit: Bool
    }

    private func svgFiles(
        in folder: URL,
        maxEntries: Int = .max,
        maxSVGs: Int = .max,
        cancellation: SVGlanceIconScanCancellation? = nil
    ) -> SVGFolderScan {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return SVGFolderScan(urls: [], didHitEntryLimit: false, didHitFileLimit: false)
        }

        var results: [URL] = []
        var scannedEntries = 0
        var didHitEntryLimit = false
        var didHitFileLimit = false

        for item in enumerator {
            if cancellation?.isCancelled == true {
                break
            }

            scannedEntries += 1
            if scannedEntries > maxEntries {
                didHitEntryLimit = true
                break
            }

            guard let url = item as? URL else {
                continue
            }

            if let values = try? url.resourceValues(forKeys: [.isPackageKey]),
               values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }

            guard url.pathExtension.lowercased() == "svg" else {
                continue
            }

            results.append(url)
            if results.count >= maxSVGs {
                didHitFileLimit = true
                break
            }
        }

        let sorted = Array(Set(results)).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return SVGFolderScan(urls: sorted, didHitEntryLimit: didHitEntryLimit, didHitFileLimit: didHitFileLimit)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + ScanLimit.watcherDebounceSeconds, execute: workItem)
    }

    private func refreshIcons(in folder: URL) {
        let path = folder.standardizedFileURL.path
        pendingFolderScans[path] = nil

        rescanApprovedFolders(trigger: .watcher)
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

private final class SVGlanceIconScanCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
