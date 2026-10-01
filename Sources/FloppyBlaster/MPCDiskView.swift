import SwiftUI
import AppKit
import FloppyBlasterCore

/// An MPC2000XL floppy (1.44 MB DOS disk): files, sounds, programs and APS files.
struct MPCDiskView: View {
    @ObservedObject var session: MPCFloppySession
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: SamplePlayer

    @State private var selection = Set<String>()
    @State private var dropTargeted = false
    @State private var confirmDelete = false
    @State private var renameTarget: FATEntry?
    @State private var renameText = ""
    @State private var newFolderShown = false
    @State private var newFolderText = ""
    @State private var programSounds: [FATEntry]?
    @State private var apsPrograms: [FATEntry]?

    private var selectedItems: [FATEntry] { session.items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .onChange(of: session.items) { _, items in
            selection = selection.filter { id in items.contains { $0.id == id } }
        }
        .confirmationDialog("Delete \(selectedItems.count) item\(selectedItems.count == 1 ? "" : "s") from \(session.url.lastPathComponent)?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    run { let new = try session.rename(target, to: renameText); library.message = "Renamed \(target.name) to \(new)." }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MPC names are up to 8 characters (A–Z, 0–9, _ and -). The extension stays the same.")
        }
        .alert("New Folder", isPresented: $newFolderShown) {
            TextField("Name", text: $newFolderText)
            Button("Create") { run { try session.newFolder(named: newFolderText) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { programSounds != nil }, set: { if !$0 { programSounds = nil } })) {
            MPCProgramSheet(session: session, initialSounds: programSounds ?? [])
        }
        .sheet(isPresented: Binding(get: { apsPrograms != nil }, set: { if !$0 { apsPrograms = nil } })) {
            MPCAPSSheet(session: session, programs: apsPrograms ?? [])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.4x3.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.url.deletingPathExtension().lastPathComponent).font(.headline)
                    if !session.label.isEmpty {
                        Text("“\(session.label)”").foregroundStyle(.secondary)
                    }
                }
                Text("MPC2000XL floppy (\(session.formatName)) · \(session.displayPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !session.path.isEmpty {
                Button { session.goUp() } label: { Label("Up", systemImage: "chevron.up") }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(session.totalBytes - session.freeBytes), total: Double(max(session.totalBytes, 1)))
                    .frame(width: 180)
                Text("\(session.freeBytes / 1024) KB free of \(session.totalBytes / 1024) KB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: File list

    private var table: some View {
        Table(session.items, selection: $selection) {
            TableColumn("") { item in
                if MPCFloppySession.isSound(item) {
                    let playing = player.isPlaying(item, on: session.url)
                    Button { report(player.toggle(item, in: session)) } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .foregroundStyle(playing ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop" : "Play")
                } else if item.isDirectory {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
            }
            .width(22)
            TableColumn("Name") { item in
                Text(item.name).font(.body.monospaced())
            }
            .width(min: 140, ideal: 180)
            TableColumn("Type") { item in
                Text(kind(item)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Length") { item in
                if let info = session.soundInfo[item.id] {
                    Text(String(format: "%.2f s", info.seconds) + (info.stereo ? " st" : ""))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(80)
            TableColumn("Size") { item in
                if !item.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = session.items.filter { ids.contains($0.id) }
            if chosen.count == 1, let item = chosen.first, MPCFloppySession.isSound(item) {
                Button(player.isPlaying(item, on: session.url) ? "Stop" : "Play") { report(player.toggle(item, in: session)) }
                Divider()
            }
            if chosen.contains(where: MPCFloppySession.isSound) {
                Button("Make Program…") { programSounds = chosen.filter(MPCFloppySession.isSound) }
            }
            if chosen.contains(where: MPCFloppySession.isProgram) {
                Button("Make APS…") { apsPrograms = chosen.filter(MPCFloppySession.isProgram) }
            }
            Button("Export…") { export(chosen) }
            if chosen.count == 1, let item = chosen.first {
                Button("Rename…") { renameText = item.name; renameTarget = item }
            }
            Divider()
            Button("Delete…", role: .destructive) { selection = Set(ids); confirmDelete = true }
        } primaryAction: { ids in
            guard let item = session.items.first(where: { ids.contains($0.id) }) else { return }
            if item.isDirectory {
                player.stop()
                session.open(item)
            } else if MPCFloppySession.isSound(item) {
                report(player.toggle(item, in: session))
            }
        }
        .onKeyPress(.space) {
            guard let item = selectedItems.first(where: MPCFloppySession.isSound) else {
                if player.playing != nil { player.stop(); return .handled }
                return .ignored
            }
            report(player.toggle(item, in: session))
            return .handled
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
        .overlay {
            if session.items.isEmpty {
                Text("This floppy is empty. Drop audio files here to add them as MPC sounds.")
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
            Button("Export…") { export(selectedItems.isEmpty ? session.items : selectedItems) }
                .help("Copy the selected files (or all of them) to a folder on your Mac, as they are.")
                .disabled(session.items.isEmpty)
            Button("Delete…") { confirmDelete = true }
                .disabled(selection.isEmpty)
            Divider().frame(height: 18)
            Button("Make Program…") {
                let chosen = selectedItems.filter(MPCFloppySession.isSound)
                programSounds = chosen.isEmpty ? session.items.filter(MPCFloppySession.isSound) : chosen
            }
            .help("Put the selected sounds (or all of them) on pads A01–D16 of a new .PGM")
            .disabled(!session.items.contains(where: MPCFloppySession.isSound))
            Button("Make APS…") {
                let chosen = selectedItems.filter(MPCFloppySession.isProgram)
                apsPrograms = chosen.isEmpty ? session.items.filter(MPCFloppySession.isProgram) : chosen
            }
            .help("Bundle the selected programs (or all of them) and their sounds into one .APS")
            .disabled(!session.items.contains(where: MPCFloppySession.isProgram))
            Menu {
                Button("New Folder…") { newFolderText = ""; newFolderShown = true }
                if !session.clutter.isEmpty {
                    Button("Remove \(session.clutter.count) Mac System File\(session.clutter.count == 1 ? "" : "s")") {
                        run { try session.removeClutter() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
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

    private func kind(_ item: FATEntry) -> String {
        if item.isDirectory { return "Folder" }
        switch item.pathExtension.uppercased() {
        case "SND": return "Sound"
        case "PGM": return "Program"
        case "APS": return "All programs"
        case "ALL": return "All sequences"
        case "MID": return "MIDI file"
        case "SEQ": return "Sequence"
        case "WAV": return "WAV audio"
        default: return item.pathExtension.isEmpty ? "File" : item.pathExtension.uppercased() + " file"
        }
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
        panel.message = "Choose audio files (they become MPC .SND sounds), or MPC files (.SND, .PGM, .APS…), to add to \(session.url.lastPathComponent)"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        player.stop()
        do {
            let result = try session.importFiles(urls)
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

    private func export(_ chosen: [FATEntry]) {
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the files"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let written = try session.export(chosen, to: folder)
            library.message = "Exported \(written.count) item\(written.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
        } catch {
            library.alert = "Export failed: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() {
        player.stop()
        let chosen = selectedItems
        run { try session.delete(chosen) }
        selection = []
        library.message = "Deleted \(chosen.count) item\(chosen.count == 1 ? "" : "s")."
    }
}
