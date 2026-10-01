import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FloppyBlasterCore

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: SamplePlayer

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            Group {
                if let session = library.session {
                    DiskView(session: session)
                        .id(session.url)
                } else if let error = library.openError {
                    Placeholder(symbol: "exclamationmark.triangle", title: "Can't open this disk", detail: error)
                } else if library.root == nil {
                    Placeholder(symbol: "externaldrive", title: "Choose your floppy images",
                                detail: "Plug in the Gotek's USB stick, or click Choose Folder… and pick a folder of .img disk images.")
                } else {
                    Placeholder(symbol: "opticaldiscdrive", title: "Pick a disk on the left",
                                detail: "\(library.imageCount) disk image\(library.imageCount == 1 ? "" : "s") in \(library.root?.lastPathComponent ?? "this folder").")
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Dropping an .img anywhere outside the file list opens it.
                guard library.session == nil else { return false }
                Task {
                    if let url = await loadURLs(providers).first(where: { $0.pathExtension.lowercased() == "img" }) {
                        library.open(url)
                    }
                }
                return true
            }
        }
        .onChange(of: library.selection) { _, _ in player.stop() }
        .alert("Floppy Blaster", isPresented: Binding(get: { library.alert != nil },
                                                      set: { if !$0 { library.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.alert ?? "")
        }
    }
}

struct Placeholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        VStack(spacing: 0) {
            List(library.nodes, children: \.children, selection: $library.selection) { node in
                Label(node.name, systemImage: node.isImage ? "opticaldiscdrive" : "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.url.lastPathComponent)
                    .tag(node.url)
            }
            .listStyle(.sidebar)
            .overlay {
                if library.nodes.isEmpty && library.root != nil {
                    Text("No .img disk images in this folder.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Choose Folder…") { chooseFolder() }
                Button { library.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for new disk images")
                    .disabled(library.root == nil)
                Spacer()
                Button { library.createBlankDisk() } label: { Image(systemName: "plus") }
                    .help("New blank disk (S3000 format) in the selected folder")
                    .disabled(library.root == nil)
            }
            .padding(8)
            if let root = library.root {
                Text(root.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Gotek's USB stick, or any folder of Akai floppy images"
        panel.directoryURL = Library.findFlashFloppyDrives().first ?? library.root
        if panel.runModal() == .OK, let url = panel.url { library.setRoot(url) }
    }
}

// MARK: - One disk

struct DiskView: View {
    @ObservedObject var session: DiskSession
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: SamplePlayer

    @State private var selection = Set<Int>()
    @State private var dropTargeted = false
    @State private var confirmDelete = false
    @State private var renameTarget: AkaiDisk.Entry?
    @State private var renameText = ""
    @State private var renamingVolume = false
    @State private var volumeText = ""
    @AppStorage("importRate") private var importRate = 44_100
    @AppStorage("importChannels") private var importChannels = AudioImport.Channels.splitLeftRight.rawValue

    private var selectedEntries: [AkaiDisk.Entry] {
        session.entries.filter { selection.contains($0.index) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .onChange(of: session.entries) { _, entries in
            selection = selection.filter { i in entries.contains { $0.index == i } }
        }
        .confirmationDialog("Delete \(selectedEntries.count) file\(selectedEntries.count == 1 ? "" : "s") from \(session.url.lastPathComponent)?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let target = renameTarget { run { try session.rename(target, to: renameText) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Up to 12 characters: A–Z, 0–9, space and # + - .")
        }
        .alert("Disk Name", isPresented: $renamingVolume) {
            TextField("Name", text: $volumeText)
            Button("Rename") { run { try session.renameVolume(volumeText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name the sampler shows for this disk. Up to 12 characters.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldiscdrive.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.url.deletingPathExtension().lastPathComponent).font(.headline)
                    Button {
                        volumeText = session.disk.volumeName
                        renamingVolume = true
                    } label: {
                        Text("“\(session.disk.volumeName)”").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("The disk's name on the sampler. Click to change it.")
                }
                Text("\(session.disk.layout.displayName) · \(session.entries.count) of \(session.disk.layout.maxFiles) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(session.totalKB - session.freeKB), total: Double(max(session.totalKB, 1)))
                    .frame(width: 180)
                Text("\(session.freeKB) KB free of \(session.totalKB) KB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: File list

    private var table: some View {
        Table(session.entries, selection: $selection) {
            TableColumn("") { entry in
                if entry.kind == .sample {
                    let playing = player.isPlaying(entry, on: session.url)
                    Button { report(player.toggle(entry, in: session)) } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .foregroundStyle(playing ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop" : "Play")
                }
            }
            .width(22)
            TableColumn("Name") { entry in
                Text(entry.name).font(.body.monospaced())
            }
            .width(min: 140, ideal: 180)
            TableColumn("Type") { entry in
                Text(entry.kind.label).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Rate") { entry in
                if let info = session.sampleInfo[entry.index] {
                    Text(rateLabel(info.rate)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(70)
            TableColumn("Length") { entry in
                if let info = session.sampleInfo[entry.index] {
                    Text(String(format: "%.2f s", Double(info.frames) / Double(max(info.rate, 1))))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(70)
            TableColumn("Size") { entry in
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: Int.self) { indexes in
            let chosen = session.entries.filter { indexes.contains($0.index) }
            if chosen.count == 1, let entry = chosen.first, entry.kind == .sample {
                Button(player.isPlaying(entry, on: session.url) ? "Stop" : "Play") { report(player.toggle(entry, in: session)) }
                Divider()
            }
            Button("Export…") { export(chosen, raw: NSEvent.modifierFlags.contains(.option)) }
            if chosen.count == 1, let entry = chosen.first {
                Button("Rename…") { renameText = entry.name; renameTarget = entry }
            }
            Divider()
            Button("Delete…", role: .destructive) { selection = Set(indexes); confirmDelete = true }
        } primaryAction: { indexes in
            if let entry = session.entries.first(where: { indexes.contains($0.index) }), entry.kind == .sample {
                report(player.toggle(entry, in: session))
            }
        }
        .onKeyPress(.space) {
            guard let entry = selectedEntries.first(where: { $0.kind == .sample }) else {
                if player.playing != nil { player.stop(); return .handled }
                return .ignored
            }
            report(player.toggle(entry, in: session))
            return .handled
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
        .overlay {
            if session.entries.isEmpty {
                Text("This disk is empty. Drop audio files here to add them.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(3)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { importFiles(await loadURLs(providers)) }
            return true
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { chooseFilesToAdd() } label: { Label("Add Files…", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            Button("Export…") { export(selectedEntries.isEmpty ? session.entries : selectedEntries,
                                       raw: NSEvent.modifierFlags.contains(.option)) }
                .help("Save the selected files (or all of them) to a folder. Samples become WAV files; hold Option for raw Akai files.")
                .disabled(session.entries.isEmpty)
            Button("Delete…") { confirmDelete = true }
                .disabled(selection.isEmpty)
            Divider().frame(height: 18)
            Text("New samples:").foregroundStyle(.secondary)
            Picker("Rate", selection: $importRate) {
                Text("44.1 kHz").tag(44_100)
                Text("22.05 kHz").tag(22_050)
            }
            .labelsHidden()
            .fixedSize()
            .help("22.05 kHz fits twice as much on a disk")
            Picker("Stereo", selection: $importChannels) {
                ForEach(AudioImport.Channels.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let message = library.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
        }
        .padding(10)
    }

    // MARK: Actions

    private func rateLabel(_ rate: Int) -> String {
        let khz = Double(rate) / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.2f kHz", khz)
    }

    private func report(_ error: String?) {
        if let error { library.message = error }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { library.alert = error.localizedDescription }
    }

    private func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose audio files, or raw Akai files (.s1, .s3, .p1…), to add to \(session.url.lastPathComponent)"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        player.stop()
        let options = DiskSession.ImportOptions(sampleRate: importRate,
                                                channels: AudioImport.Channels(rawValue: importChannels) ?? .splitLeftRight)
        do {
            let result = try session.importFiles(urls, options: options)
            if !result.added.isEmpty {
                library.message = "Added \(result.added.count) file\(result.added.count == 1 ? "" : "s"): \(result.added.joined(separator: ", "))."
            }
            if !result.skipped.isEmpty {
                library.alert = "Some files weren't added:\n\n" + result.skipped.joined(separator: "\n")
            }
        } catch {
            library.alert = "Nothing was added. \(error.localizedDescription)"
        }
    }

    private func export(_ chosen: [AkaiDisk.Entry], raw: Bool) {
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = raw ? "Choose where to save the raw Akai files" : "Choose where to save the files (samples as WAV)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let written = try session.export(chosen, to: folder, samplesAsWAV: !raw)
            library.message = "Exported \(written.count) file\(written.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
        } catch {
            library.alert = "Export failed: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() {
        player.stop()
        let chosen = selectedEntries
        run { try session.delete(chosen) }
        selection = []
        library.message = "Deleted \(chosen.count) file\(chosen.count == 1 ? "" : "s")."
    }
}

func loadURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        if let url { urls.append(url) }
    }
    return urls
}
