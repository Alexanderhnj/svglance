import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var state: SVGlanceAppState
    let openSVG: () -> Void
    let applyIcons: () -> Void
    let clearIcons: () -> Void
    let addDesktop: () -> Void
    let addDownloads: () -> Void
    let addFolder: () -> Void
    let rescanFolders: () -> Void
    let manageFolders: () -> Void
    let resetFolders: () -> Void
    let checkForUpdates: () -> Void
    let shareFeedback: () -> Void
    let showAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SVGlance")
                        .font(.headline)
                    Text("SVG viewer and Finder icon fixer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(state.statusText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button(action: openSVG) {
                    Label("Open SVG...", systemImage: "doc.viewfinder")
                        .frame(maxWidth: .infinity)
                }

                Button(action: applyIcons) {
                    Label("Apply Finder Icons...", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }

                Button(action: clearIcons) {
                    Label("Clear Finder Icons...", systemImage: "xmark.square")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Approved Folders")
                    .font(.headline)

                Text(state.approvedFolderSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("Approved folders are scanned and watched locally. SVGlance does not upload or collect file data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: addDesktop) {
                        Label("Desktop", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                    }

                    Button(action: addDownloads) {
                        Label("Downloads", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                }

                Button(action: addFolder) {
                    Label("Choose Folder...", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Button(action: rescanFolders) {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }

                    Button(action: manageFolders) {
                        Label("Manage...", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                }

                Button(action: resetFolders) {
                    Label("Forget All Approved Folders", systemImage: "lock.slash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Divider()

            HStack {
                Button("About SVGlance", action: showAbout)
                Button("Check for Updates", action: checkForUpdates)
                Button("Share Feedback", action: shareFeedback)

                Spacer()

                Button("Quit SVGlance") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}

struct AboutSVGlanceView: View {
    let version: String
    let build: String
    let projectURL: URL
    let privacyURL: URL
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 82, height: 82)
                .cornerRadius(18)

            VStack(spacing: 4) {
                Text("SVGlance")
                    .font(.title2.bold())
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("SVG viewer and Finder icon fixer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("SVGlance keeps SVG folder access local to your Mac. It does not collect analytics, upload files, or contact a server for rendering.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Link("GitHub", destination: projectURL)
                Link("Privacy", destination: privacyURL)
                Link("MIT License", destination: projectURL.appending(path: "blob/main/LICENSE"))
            }

            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct ApprovedFoldersView: View {
    @ObservedObject var state: SVGlanceAppState
    let addFolder: () -> Void
    let removeFolders: (Set<String>) -> Void
    let rescanFolders: () -> Void
    let close: () -> Void

    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approved Folders")
                        .font(.title3.bold())
                    Text("SVGlance watches these local folders and updates SVG Finder icons when files change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            List(state.approvedFolders, selection: $selection) { folder in
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.body)
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder...", systemImage: "folder.badge.plus")
                }

                Button {
                    removeFolders(selection)
                    selection.removeAll()
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .disabled(selection.isEmpty)

                Button {
                    rescanFolders()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }

                Spacer()

                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 390)
    }
}

#Preview {
    StatusPopoverView(
        state: SVGlanceAppState(),
        openSVG: {},
        applyIcons: {},
        clearIcons: {},
        addDesktop: {},
        addDownloads: {},
        addFolder: {},
        rescanFolders: {},
        manageFolders: {},
        resetFolders: {},
        checkForUpdates: {},
        shareFeedback: {},
        showAbout: {}
    )
}
