import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

enum SVGlanceScanState {
    case idle
    case scanning(folderName: String, processed: Int, totalKnown: Int?)
    case finished(successes: Int, total: Int, folderName: String, didHitLimit: Bool)
    case failed(folderName: String, message: String)

    var isScanning: Bool {
        if case .scanning = self {
            return true
        }

        return false
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .scanning(let folderName, let processed, _):
            return "Indexing \(folderName)... \(processed) SVG\(processed == 1 ? "" : "s") updated so far."
        case .finished(let successes, let total, let folderName, let didHitLimit):
            if total == 0 {
                return "No SVG files found in \(folderName)."
            }

            let base = successes == total
                ? "Updated \(successes) SVG icon\(successes == 1 ? "" : "s") in \(folderName)."
                : "Updated \(successes) of \(total) SVG icons in \(folderName)."

            return didHitLimit
                ? "\(base) Some subfolders were skipped to keep SVGlance fast."
                : base
        case .failed(let folderName, let message):
            return "Could not index \(folderName): \(message)"
        }
    }
}

final class SVGlanceAppState: ObservableObject {
    @Published var statusText = "Approve a folder to update SVG Finder icons automatically."
    @Published var scanState: SVGlanceScanState = .idle
    @Published var approvedFolders: [SVGlanceApprovedFolder] = []

    var isScanning: Bool {
        scanState.isScanning
    }

    var visibleStatusText: String {
        scanState.message ?? statusText
    }

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

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private enum DefaultsKey {
        static let automaticIconFolderBookmark = "SVGlanceAutomaticIconFolderBookmark"
        static let didShowFolderOnboarding = "SVGlanceDidShowFolderOnboarding"
        static let lastUpdateCheck = "SVGlanceLastUpdateCheck"
    }

    private enum ReleaseLinks {
        static let projectURL = URL(string: "https://github.com/Alexanderhnj/svglance")!
        static let privacyURL = URL(string: "https://github.com/Alexanderhnj/svglance/blob/main/PRIVACY.md")!
        static let feedbackURL = URL(string: "mailto:alexanderhnj2001@gmail.com?subject=SVGlance%20feedback")!
        static let latestReleaseURL = URL(string: "https://github.com/Alexanderhnj/svglance/releases/latest")!
        static let latestDMGURL = URL(string: "https://github.com/Alexanderhnj/svglance/releases/latest/download/SVGlance.dmg")!
        static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/Alexanderhnj/svglance/releases/latest")!
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
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
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
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 280)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                state: appState,
                addFolder: { [weak self] in self?.chooseFolderToApprove() },
                setDefaultViewer: { [weak self] in self?.setAsDefaultSVGViewer() },
                manageFolders: { [weak self] in self?.showApprovedFoldersWindow() },
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
            self?.checkForUpdatesIfNeeded()
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
            startPopoverMonitoring()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverMonitoring()
    }

    private func startPopoverMonitoring() {
        stopPopoverMonitoring()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown {
                guard event.keyCode == 53 else {
                    return event
                }

                self.popover.performClose(nil)
                return nil
            }

            if event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.statusItem?.button?.window {
                self.popover.performClose(nil)
            }

            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopPopoverMonitoring() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
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
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            chooseFolderToApprove()
        default:
            setStatus("You can approve folders from the SVGlance menu bar icon anytime.")
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
            setStatus("Could not find that folder.")
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
        var approvedURLs: [URL] = []

        for url in urls {
            if SVGlanceViewerFolderAccess.saveAccess(to: url) {
                approvedCount += 1
                approvedURLs.append(url)
            } else {
                failedCount += 1
            }
        }

        refreshApprovedFolderStatus()
        refreshWatchedFolders()

        if scanImmediately, !approvedURLs.isEmpty {
            rescanApprovedFolders(approvedURLs, trigger: .approval)
        } else if approvedCount > 0 {
            setStatus("Approved \(approvedCount) folder\(approvedCount == 1 ? "" : "s").")
        }

        if failedCount > 0, approvedURLs.isEmpty {
            setStatus("Approved \(approvedCount) folder\(approvedCount == 1 ? "" : "s"); \(failedCount) failed.")
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
        setStatus("Opened an email draft for SVGlance feedback.")
    }

    private func setAsDefaultSVGViewer() {
        if registerSVGViewerHandlers() {
            setStatus("SVGlance is set to open SVG files.")
        } else {
            setStatus("Could not set SVGlance as the default SVG viewer.")
        }
    }

    private func setStatus(_ text: String) {
        appState.scanState = .idle
        appState.statusText = text
    }

    private func checkForUpdatesIfNeeded() {
        let lastCheck = UserDefaults.standard.object(forKey: DefaultsKey.lastUpdateCheck) as? Date
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }

        checkForUpdates(userInitiated: false)
    }

    private func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            setStatus("Checking for SVGlance updates...")
        }

        var request = URLRequest(url: ReleaseLinks.latestReleaseAPIURL)
        request.setValue("SVGlance", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    if userInitiated {
                        self.showUpdateCheckFailed(message: error.localizedDescription)
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let data else {
                    if userInitiated {
                        self.showUpdateCheckFailed(message: "GitHub did not return release information.")
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    UserDefaults.standard.set(Date(), forKey: DefaultsKey.lastUpdateCheck)
                    self.handleLatestRelease(release, userInitiated: userInitiated)
                } catch {
                    if userInitiated {
                        self.showUpdateCheckFailed(message: error.localizedDescription)
                    }
                }
            }
        }.resume()
    }

    private func handleLatestRelease(_ release: GitHubRelease, userInitiated: Bool) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        guard compareVersions(latestVersion, currentVersion) == .orderedDescending else {
            if userInitiated {
                setStatus("SVGlance is up to date.")
                let alert = NSAlert()
                alert.messageText = "SVGlance is up to date"
                alert.informativeText = "You are running version \(currentVersion)."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        setStatus("SVGlance \(latestVersion) is available.")

        let alert = NSAlert()
        alert.messageText = "SVGlance \(latestVersion) is available"
        alert.informativeText = "You are running version \(currentVersion). Download the latest DMG from GitHub and replace the app in Applications."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "View Release Notes")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(ReleaseLinks.latestDMGURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func showUpdateCheckFailed(message: String) {
        setStatus("Could not check for updates.")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = "\(message)\n\nYou can still check GitHub manually."
        alert.addButton(withTitle: "Open GitHub Releases")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(ReleaseLinks.latestReleaseURL)
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = lhs.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let rightParts = rhs.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let left = index < leftParts.count ? leftParts[index] : 0
            let right = index < rightParts.count ? rightParts[index] : 0

            if left < right {
                return .orderedAscending
            }
            if left > right {
                return .orderedDescending
            }
        }

        return .orderedSame
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
        setStatus("Forgot all approved folders. You can approve folders again anytime.")
    }

    private func removeApprovedFolders(withIDs ids: Set<String>) {
        let folders = SVGlanceViewerFolderAccess.savedFolderURLs()
        for folder in folders where ids.contains(folder.standardizedFileURL.path) {
            SVGlanceViewerFolderAccess.removeAccess(to: folder)
        }

        refreshApprovedFolderStatus()
        refreshWatchedFolders()
        setStatus(ids.isEmpty ? "No approved folders selected." : "Removed \(ids.count) approved folder\(ids.count == 1 ? "" : "s").")
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
        setStatus("Opened \(url.lastPathComponent) in SVGlance.")
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
                setStatus("Approve a folder first.")
            }
            return
        }

        rescanApprovedFolders(folders, trigger: trigger)
    }

    private func rescanApprovedFolders(_ folders: [URL], trigger: FolderScanTrigger) {
        let cancellation = startNewIconScan()
        let folderName = scanDisplayName(for: folders)
        appState.scanState = .scanning(folderName: folderName, processed: 0, totalKnown: nil)

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

                let currentFolderName = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
                SVGlanceViewerFolderAccess.performWithAccess(to: folder) {
                    let topLevelScan = self.topLevelSVGFiles(in: folder, maxSVGs: ScanLimit.maxSVGsPerFolder)
                    let topLevelFiles = topLevelScan.urls
                    totalFiles += topLevelFiles.count
                    didHitLimit = didHitLimit || topLevelScan.didHitFileLimit
                    self.publishScanProgress(
                        cancellation: cancellation,
                        folderName: currentFolderName,
                        processed: totalSuccesses,
                        totalKnown: topLevelFiles.isEmpty ? nil : totalFiles
                    )

                    for url in topLevelFiles {
                        if cancellation.isCancelled {
                            return
                        }

                        autoreleasepool {
                            if SVGIconRenderer.applyIcon(to: url, size: 512) {
                                totalSuccesses += 1
                            }
                        }

                        self.publishScanProgress(
                            cancellation: cancellation,
                            folderName: currentFolderName,
                            processed: totalSuccesses,
                            totalKnown: totalFiles
                        )
                    }

                    let remainingBudget = max(0, ScanLimit.maxSVGsPerFolder - topLevelFiles.count)
                    guard remainingBudget > 0 else {
                        didHitLimit = didHitLimit || !topLevelFiles.isEmpty
                        return
                    }

                    let scan = self.svgFiles(
                        in: folder,
                        skippingTopLevelIn: folder,
                        maxEntries: ScanLimit.maxEntriesPerFolder,
                        maxSVGs: remainingBudget,
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

                        self.publishScanProgress(
                            cancellation: cancellation,
                            folderName: currentFolderName,
                            processed: totalSuccesses,
                            totalKnown: nil
                        )
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentIconScan === cancellation, !cancellation.isCancelled else {
                    return
                }

                self.currentIconScan = nil
                self.refreshApprovedFolderStatus()
                self.refreshFinderIcons(in: folders)

                self.appState.scanState = .finished(
                    successes: totalSuccesses,
                    total: totalFiles,
                    folderName: folderName,
                    didHitLimit: didHitLimit
                )
            }
        }
    }

    private func publishScanProgress(
        cancellation: SVGlanceIconScanCancellation,
        folderName: String,
        processed: Int,
        totalKnown: Int?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentIconScan === cancellation, !cancellation.isCancelled else {
                return
            }

            self.appState.scanState = .scanning(folderName: folderName, processed: processed, totalKnown: totalKnown)
        }
    }

    private func scanDisplayName(for folders: [URL]) -> String {
        if folders.count == 1, let folder = folders.first {
            return folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        }

        return "\(folders.count) folders"
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
        setStatus("\(actionName) SVG icons in the background...")

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
                    self?.setStatus("No SVG files were selected.")
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
                self.setStatus(failures == 0
                    ? "\(actionName) visible Finder icons for \(successes) SVG file\(successes == 1 ? "" : "s")."
                    : "\(actionName) \(successes) icon\(successes == 1 ? "" : "s"); \(failures) failed.")
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

    private func topLevelSVGFiles(in folder: URL, maxSVGs: Int) -> SVGFolderScan {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SVGFolderScan(urls: [], didHitEntryLimit: false, didHitFileLimit: false)
        }

        let svgFiles = urls.filter { url in
            guard url.pathExtension.lowercased() == "svg" else {
                return false
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile ?? true
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return SVGFolderScan(
            urls: Array(svgFiles.prefix(maxSVGs)),
            didHitEntryLimit: false,
            didHitFileLimit: svgFiles.count > maxSVGs
        )
    }

    private func svgFiles(
        in folder: URL,
        skippingTopLevelIn topLevelFolder: URL? = nil,
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

            if let topLevelFolder,
               url.deletingLastPathComponent().standardizedFileURL.path == topLevelFolder.standardizedFileURL.path {
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

    @discardableResult
    private func registerSVGViewerHandlers() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier as CFString? else {
            return false
        }

        let contentTypes: [CFString] = [
            "com.svglance.svg" as CFString,
            "public.svg-image" as CFString
        ]

        var didRegister = true
        for contentType in contentTypes {
            didRegister = LSSetDefaultRoleHandlerForContentType(contentType, .viewer, bundleIdentifier) == noErr && didRegister
        }

        return didRegister
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

        rescanApprovedFolders([folder], trigger: .watcher)
    }

    private func refreshFinderIcons(in folders: [URL]) {
        for folder in folders {
            NSWorkspace.shared.noteFileSystemChanged(folder.path)
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
