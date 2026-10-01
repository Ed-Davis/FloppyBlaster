import Foundation
import SwiftUI
import FloppyBlasterCore

/// A folder or floppy image in the sidebar.
struct LibraryNode: Identifiable, Hashable {
    let url: URL
    let isImage: Bool
    var children: [LibraryNode]?
    var id: URL { url }
    var name: String { isImage ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
}

/// The folder of floppy images being browsed (usually the Gotek's USB stick),
/// and the image that's open.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var nodes: [LibraryNode] = []
    @Published private(set) var imageCount = 0
    @Published var selection: URL? { didSet { if selection != oldValue { openSelection() } } }
    @Published private(set) var session: DiskSession?
    /// The open disk when it's an MPC2000XL (DOS) floppy rather than an Akai one.
    @Published private(set) var mpcSession: MPCFloppySession?
    /// Why the selected image couldn't be opened, if it couldn't.
    @Published private(set) var openError: String?
    @Published var message: String?
    @Published var alert: String?

    private static let rootKey = "libraryRoot"
    private static let skippedFolders: Set<String> = ["FW", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems"]

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.rootKey),
           FileManager.default.fileExists(atPath: saved) {
            setRoot(URL(fileURLWithPath: saved, isDirectory: true))
        } else if let found = Self.findFlashFloppyDrives().first {
            setRoot(found)
        }
    }

    /// Mounted drives that look like a FlashFloppy stick (they have FF.CFG).
    static func findFlashFloppyDrives() -> [URL] {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                             options: [.skipHiddenVolumes]) ?? []
        return volumes.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("FF.CFG").path)
        }
    }

    func setRoot(_ url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        rescan()
    }

    func rescan() {
        guard let root else { nodes = []; imageCount = 0; return }
        var count = 0
        nodes = Self.scan(root, depth: 0, count: &count)
        imageCount = count
        if let selection, !FileManager.default.fileExists(atPath: selection.path) {
            self.selection = nil
        }
    }

    private static func scan(_ folder: URL, depth: Int, count: inout Int) -> [LibraryNode] {
        guard depth < 8,
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var folders: [LibraryNode] = []
        var images: [LibraryNode] = []
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard !skippedFolders.contains(url.lastPathComponent) else { continue }
                let children = scan(url, depth: depth + 1, count: &count)
                if !children.isEmpty { folders.append(LibraryNode(url: url, isImage: false, children: children)) }
            } else if url.pathExtension.lowercased() == "img" {
                images.append(LibraryNode(url: url, isImage: true, children: nil))
                count += 1
            }
        }
        let byName: (LibraryNode, LibraryNode) -> Bool = {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        // Folders first, like FlashFloppy's sort-priority = folders.
        return folders.sorted(by: byName) + images.sorted(by: byName)
    }

    /// Opens a single image chosen or dropped from anywhere.
    func open(_ url: URL) {
        if let root, url.path.hasPrefix(root.path + "/") {
            selection = url
        } else {
            setRoot(url.deletingLastPathComponent())
            selection = url
        }
    }

    private func openSelection() {
        openError = nil
        session = nil
        mpcSession = nil
        guard let url = selection, url.pathExtension.lowercased() == "img" else { return }
        do {
            session = try DiskSession(url: url)
        } catch let akaiError {
            // Not an Akai disk: perhaps an MPC2000XL (DOS) floppy.
            do {
                mpcSession = try MPCFloppySession(url: url)
            } catch let dosError {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                openError = MPCFloppySession.floppySizes.contains(size)
                    ? dosError.localizedDescription
                    : akaiError.localizedDescription
            }
        }
    }

    /// The URL of whichever disk is open.
    var openDiskURL: URL? { session?.url ?? mpcSession?.url }

    /// The folder new disks go in: the selected folder, or the open image's folder, or the root.
    var targetFolder: URL? {
        guard let selection else { return root }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDir), isDir.boolValue { return selection }
        return selection.deletingLastPathComponent()
    }

    enum BlankKind: String, CaseIterable, Identifiable {
        case s3000, s1000, mpc2000xl
        var id: String { rawValue }
        var menuTitle: String {
            switch self {
            case .s3000: return "Akai S3000 Format (S2000, S2800, S3000, S3200)"
            case .s1000: return "Akai S1000 Format (S1000, S1100, S01)"
            case .mpc2000xl: return "MPC2000XL (1.44 MB DOS)"
            }
        }
        var description: String {
            switch self {
            case .s3000: return "a blank S3000-format disk"
            case .s1000: return "a blank S1000-format disk"
            case .mpc2000xl: return "a blank MPC2000XL (1.44 MB DOS) floppy"
            }
        }
    }

    func createBlankDisk(_ kind: BlankKind = .s3000) {
        guard let folder = targetFolder else { return }
        let url = folder.appendingPathComponent(DiskSession.nextBlankName(in: folder))
        do {
            switch kind {
            case .s3000: try DiskSession.createBlank(at: url, layout: .s3000)
            case .s1000: try DiskSession.createBlank(at: url, layout: .s1000)
            case .mpc2000xl: try MPCFloppySession.createBlank(at: url)
            }
            rescan()
            selection = url
            message = "Created \(url.lastPathComponent), \(kind.description)."
        } catch {
            alert = "Couldn't create a blank disk: \(error.localizedDescription)"
        }
    }
}
