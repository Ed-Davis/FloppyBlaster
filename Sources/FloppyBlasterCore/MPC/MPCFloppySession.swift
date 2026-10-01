import Foundation
import AVFoundation

/// One open MPC2000XL floppy image (a 1.44 MB DOS disk, FAT12): browsing,
/// auditioning, adding and exporting files, and making programs (.PGM) and
/// "all programs and sounds" files (.APS).
///
/// Like `DiskSession`, every change is made to a copy of the image in memory
/// and then the whole image is saved at once (temporary file, flush, swap).
/// If anything goes wrong part way, the copy is thrown away and the image
/// file is left exactly as it was.
@MainActor
public final class MPCFloppySession: ObservableObject {
    public let url: URL
    private var image: ImageFile
    private var volume: FATVolume

    /// Folders from the top of the disk down to the one being shown.
    @Published public private(set) var path: [FATEntry] = []
    @Published public private(set) var items: [FATEntry] = []
    /// macOS clutter (.DS_Store, ._ files) in the current folder, hidden from `items`.
    @Published public private(set) var clutter: [FATEntry] = []
    @Published public private(set) var freeBytes: Int64 = 0
    /// Rate, length and channels of the sounds in the current folder, by entry id.
    @Published public private(set) var soundInfo: [String: SoundInfo] = [:]

    public struct SoundInfo: Equatable {
        public var sampleRate: Int
        public var seconds: Double
        public var stereo: Bool
    }

    /// Sizes of DOS floppy images (720 KB, 1.44 MB, 2.88 MB). The MPC2000XL
    /// uses 1.44 MB; the others are accepted in case they turn up.
    public static let floppySizes: Set<Int> = [737_280, 1_474_560, 2_949_120]
    public static let floppySize = 1_474_560

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1_048_576 else {
            throw FATError.unsupported("This is too big to be a floppy image. Use MPC Blaster for MPC hard disk and card images.")
        }
        image = ImageFile(bytes: [UInt8](data))
        volume = try FATVolume(image: image, offset: 0)
        refresh()
    }

    public var label: String { volume.label }
    public var totalBytes: Int64 { volume.totalBytes }
    public var formatName: String { volume.kind.rawValue }
    public var currentDirectory: FATDirectory { path.last?.asDirectory ?? .root }
    public var displayPath: String { "/" + path.map { $0.name + "/" }.joined() }

    // MARK: Browsing

    public func refresh() {
        do {
            let all = try volume.list(currentDirectory)
            clutter = all.filter(\.isMacClutter)
            items = all.filter { !$0.isMacClutter }.sorted {
                ($0.isDirectory ? 0 : 1, $0.name.uppercased()) < ($1.isDirectory ? 0 : 1, $1.name.uppercased())
            }
        } catch {
            items = []
            clutter = []
        }
        freeBytes = volume.freeBytes
        var info: [String: SoundInfo] = [:]
        for item in items where Self.isSound(item) {
            if item.pathExtension.uppercased() == "SND", let data = try? volume.read(item),
               let sound = try? MPCSound(data: data) {
                info[item.id] = SoundInfo(sampleRate: Int(sound.sampleRate), seconds: sound.duration, stereo: sound.isStereo)
            }
        }
        soundInfo = info
    }

    public func open(_ folder: FATEntry) {
        guard folder.isDirectory else { return }
        path.append(folder)
        refresh()
    }

    public func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        refresh()
    }

    // MARK: Reading

    public func contents(of item: FATEntry) throws -> Data { try volume.read(item) }

    /// The audio of a .SND, WAV or AIFF on the disk, ready to play.
    public func audioBuffer(for item: FATEntry) throws -> AVAudioPCMBuffer {
        let data = try volume.read(item)
        if item.pathExtension.uppercased() == "SND" {
            guard let buffer = try MPCSound(data: data).pcmBuffer() else { throw MPCSound.ParseError.notAnMPCSample }
            return buffer
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + item.pathExtension.lowercased())
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try AVAudioFile(forReading: temp)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        return buffer
    }

    /// Copies files and folders from the disk into a Mac folder, as they are.
    @discardableResult
    public func export(_ chosen: [FATEntry], to folder: URL) throws -> [URL] {
        try chosen.map { try export($0, to: folder) }
    }

    private func export(_ item: FATEntry, to folder: URL) throws -> URL {
        var destination = folder.appendingPathComponent(item.name)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        if item.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try volume.list(item.asDirectory) where !child.isMacClutter {
                _ = try export(child, to: destination)
            }
        } else {
            try volume.read(item).write(to: destination, options: .atomic)
        }
        return destination
    }

    // MARK: Changing

    public struct ImportResult: Equatable {
        public var added: [String] = []
        public var skipped: [String] = []
    }

    /// Adds files to the current folder. Audio (WAV, AIFF, MP3…) is
    /// converted to MPC .SND sounds (16-bit, 44.1 kHz, mono or stereo as it
    /// was); anything else (.PGM, .SND, .APS…) is copied as it is. If they
    /// don't all fit, nothing is added.
    @discardableResult
    public func importFiles(_ urls: [URL]) throws -> ImportResult {
        var result = ImportResult()
        let dir = currentDirectory
        try change { volume in
            var taken = try volume.names(in: dir)
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file: String
                let data: Data
                do {
                    if AudioPrep.isConvertibleAudio(url) {
                        let channels = try Self.convertToMPC(url)
                        file = AudioPrep.uniqueName(baseName: url.deletingPathExtension().lastPathComponent,
                                                    extension: "SND", taken: taken)
                        data = MPCSound.fileData(name: (file as NSString).deletingPathExtension, channels: channels)
                    } else {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            result.skipped.append("\(url.lastPathComponent): folders can't be added; add the files inside it.")
                            continue
                        }
                        let ext = url.pathExtension.isEmpty ? "BIN" : String(url.pathExtension.prefix(3))
                        file = AudioPrep.uniqueName(baseName: url.deletingPathExtension().lastPathComponent,
                                                    extension: ext, taken: taken)
                        data = try Data(contentsOf: url)
                    }
                } catch {
                    result.skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                // Space problems stop everything (and nothing is saved).
                try volume.createFile(in: dir, name: file, contents: data)
                taken.insert(file.uppercased())
                result.added.append(file)
            }
        }
        return result
    }

    public func delete(_ chosen: [FATEntry]) throws {
        // Slots are reused once deleted, so delete from the last slot backwards.
        let ordered = chosen.sorted { ($0.slots.last ?? 0) > ($1.slots.last ?? 0) }
        try change { volume in
            for entry in ordered { try Self.deleteRecursively(entry, on: volume) }
        }
    }

    nonisolated private static func deleteRecursively(_ entry: FATEntry, on volume: FATVolume) throws {
        if entry.isDirectory {
            let children = try volume.list(entry.asDirectory).sorted { ($0.slots.last ?? 0) > ($1.slots.last ?? 0) }
            for child in children { try deleteRecursively(child, on: volume) }
        }
        try volume.delete(entry)
    }

    public func removeClutter() throws {
        try delete(clutter)
    }

    public enum RenameError: LocalizedError, Equatable {
        case extensionChange(String)
        public var errorDescription: String? {
            switch self {
            case .extensionChange(let ext):
                return "The MPC knows what a file is by its extension, so it stays .\(ext)."
            }
        }
    }

    /// Renames to an 8.3 name, keeping the extension. Returns the new name.
    @discardableResult
    public func rename(_ item: FATEntry, to rawNewName: String) throws -> String {
        let ext = item.pathExtension
        let proposedExt = (rawNewName as NSString).pathExtension
        if !item.isDirectory, !proposedExt.isEmpty, proposedExt.uppercased() != ext.uppercased() {
            throw RenameError.extensionChange(ext.uppercased())
        }
        var taken = try volume.names(in: item.parent)
        taken.remove(item.shortName.uppercased())
        let base = proposedExt.isEmpty ? rawNewName : (rawNewName as NSString).deletingPathExtension
        let newName = item.isDirectory || ext.isEmpty
            ? AudioPrep.uniqueFolderName(base, taken: taken)
            : AudioPrep.uniqueName(baseName: base, extension: ext, taken: taken)
        guard newName.uppercased() != item.shortName.uppercased() else { return newName }
        try change { try $0.rename(item, to: newName) }
        return newName
    }

    public func newFolder(named raw: String) throws {
        let dir = currentDirectory
        let name = AudioPrep.uniqueFolderName(raw, taken: try volume.names(in: dir))
        try change { _ = try $0.createDirectory(in: dir, name: name) }
    }

    /// Makes the change on the in-memory image, then saves it. On any error
    /// the in-memory image goes back to how it was and nothing is saved.
    func change(_ body: (FATVolume) throws -> Void) throws {
        let before = image.bytes
        do {
            try body(volume)
            try DiskSession.write(Data(image.bytes), to: url)
        } catch {
            image = ImageFile(bytes: before)
            if let restored = try? FATVolume(image: image, offset: 0) { volume = restored }
            refresh()
            throw error
        }
        refresh()
    }

    // MARK: Programs

    nonisolated public static func isSound(_ item: FATEntry) -> Bool {
        !item.isDirectory && (item.pathExtension.uppercased() == "SND"
                              || AudioPrep.isConvertibleAudio(URL(fileURLWithPath: item.shortName)))
    }

    nonisolated public static func isProgram(_ item: FATEntry) -> Bool {
        !item.isDirectory && item.pathExtension.uppercased() == "PGM"
    }

    /// The name a sound has inside programs: its file name without the extension.
    nonisolated public static func soundName(_ item: FATEntry) -> String {
        (item.shortName as NSString).deletingPathExtension
    }

    /// MPC sound memory an item takes (exact for .SND; for other audio, its
    /// 16-bit data after conversion, roughly).
    nonisolated public static func estimatedMemory(_ item: FATEntry) -> Int {
        if item.pathExtension.uppercased() == "SND" { return MPCSound.memoryBytes(fileSize: Int(item.size)) }
        return max(0, Int(item.size) - 44)
    }

    nonisolated public static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    public struct MadeProgram: Equatable {
        public var file: String
        public var sounds: Int
        public var lastPad: String
        public var memory: Int
        public var converted: Int
    }

    public enum ProgramError: LocalizedError, Equatable {
        case noSounds
        case tooBig(needed: Int, memory: MPCMemory)
        case noPrograms
        case unreadable([String])
        case tooManyPrograms
        case missingSounds([String])

        public var errorDescription: String? {
            switch self {
            case .noSounds: return "Choose some sounds (.SND or audio files) first."
            case .tooBig(let needed, let memory):
                return "The sounds need \(MPCFloppySession.mb(needed)) and an MPC with \(memory.label) has about \(MPCFloppySession.mb(memory.usableBytes)) for sounds. Choose fewer or shorter sounds, or a bigger memory size."
            case .noPrograms: return "Choose some programs (.PGM) first."
            case .unreadable(let names): return "\(names.joined(separator: ", ")) couldn't be read as MPC2000XL programs."
            case .tooManyPrograms: return "An APS holds at most 24 programs."
            case .missingSounds(let names):
                return "These sounds aren't in this folder, so the MPC couldn't load them: \(names.joined(separator: ", "))."
            }
        }
    }

    /// Writes NAME.PGM in the current folder, playing `sounds` on pads A01,
    /// A02 … in order (first 64). Audio that isn't already a .SND is converted
    /// to one beside it. Nothing is written unless it all fits in `memory`
    /// and on the disk.
    @discardableResult
    public func makeProgram(named rawName: String, sounds chosen: [FATEntry], memory: MPCMemory) throws -> MadeProgram {
        let sounds = Array(chosen.filter(Self.isSound).prefix(MPCProgram.maxSounds))
        guard !sounds.isEmpty else { throw ProgramError.noSounds }
        let dir = currentDirectory
        var taken = try volume.names(in: dir)
        var soundNames: [String] = []
        var newFiles: [(name: String, data: Data)] = []
        var total = 0
        for item in sounds {
            if item.pathExtension.uppercased() == "SND" {
                soundNames.append(Self.soundName(item))
                total += MPCSound.memoryBytes(fileSize: Int(item.size))
                continue
            }
            let channels = try Self.convertToMPC(volume.read(item), name: item.shortName)
            let file = AudioPrep.uniqueName(baseName: Self.soundName(item), extension: "SND", taken: taken)
            taken.insert(file.uppercased())
            let base = (file as NSString).deletingPathExtension
            let data = MPCSound.fileData(name: base, channels: channels)
            newFiles.append((file, data))
            soundNames.append(base)
            total += MPCSound.memoryBytes(fileSize: data.count)
        }
        guard total <= memory.usableBytes else { throw ProgramError.tooBig(needed: total, memory: memory) }

        let file = AudioPrep.uniqueName(baseName: rawName, extension: "PGM", taken: taken)
        let program = try MPCProgram(name: Self.displayName(rawName, fallback: (file as NSString).deletingPathExtension),
                                     sounds: soundNames)
        try change { volume in
            for w in newFiles + [(name: file, data: program.data)] { try volume.createFile(in: dir, name: w.name, contents: w.data) }
        }
        return MadeProgram(file: file, sounds: soundNames.count, lastPad: MPCProgram.padNames[soundNames.count - 1],
                           memory: total, converted: newFiles.count)
    }

    public struct APSPlan: Equatable {
        public var programs: [MPCProgram] = []
        public var unreadable: [String] = []
        public var sounds: [String] = []
        public var missing: [String] = []
        public var memory = 0
        public init() {}
    }

    /// What an APS of these programs would hold, and whether every sound
    /// they use is in the current folder.
    public func apsPlan(_ chosen: [FATEntry]) -> APSPlan {
        var plan = APSPlan()
        for item in chosen where Self.isProgram(item) {
            if let data = try? volume.read(item), let program = try? MPCProgram(data: data) {
                plan.programs.append(program)
            } else {
                plan.unreadable.append(item.name)
            }
        }
        let files = (try? volume.list(currentDirectory)) ?? []
        for program in plan.programs {
            for s in program.soundNames where !plan.sounds.contains(where: { $0.uppercased() == s.uppercased() }) {
                plan.sounds.append(s)
                if let snd = files.first(where: { $0.shortName.uppercased() == s.uppercased() + ".SND" }) {
                    plan.memory += MPCSound.memoryBytes(fileSize: Int(snd.size))
                } else {
                    plan.missing.append(s)
                }
            }
        }
        return plan
    }

    /// Writes NAME.APS in the current folder from the chosen programs.
    /// Returns the file name.
    @discardableResult
    public func makeAPS(named rawName: String, programs chosen: [FATEntry], memory: MPCMemory) throws -> String {
        let plan = apsPlan(chosen)
        guard !plan.programs.isEmpty || !plan.unreadable.isEmpty else { throw ProgramError.noPrograms }
        guard plan.unreadable.isEmpty else { throw ProgramError.unreadable(plan.unreadable) }
        guard plan.programs.count <= MPCAllProgramsFile.maxPrograms else { throw ProgramError.tooManyPrograms }
        guard plan.missing.isEmpty else { throw ProgramError.missingSounds(plan.missing) }
        guard plan.memory <= memory.usableBytes else { throw ProgramError.tooBig(needed: plan.memory, memory: memory) }
        let dir = currentDirectory
        let file = AudioPrep.uniqueName(baseName: rawName, extension: "APS", taken: try volume.names(in: dir))
        let data = try MPCAllProgramsFile.data(name: Self.displayName(rawName, fallback: (file as NSString).deletingPathExtension),
                                               programs: plan.programs)
        try change { _ = try $0.createFile(in: dir, name: file, contents: data) }
        return file
    }

    // MARK: New disks

    /// Creates a blank 1.44 MB DOS floppy image, as the MPC2000XL formats them.
    public static func createBlank(at url: URL, label: String = "") throws {
        try DiskSession.write(Data(blankImage(label: label)), to: url)
    }

    nonisolated static func blankImage(label rawLabel: String = "") -> [UInt8] {
        var b = [UInt8](repeating: 0, count: floppySize)
        let label = String(AudioPrep.baseName(rawLabel, fallback: "NO NAME").prefix(11))
        let labelBytes = Array(label.utf8) + [UInt8](repeating: 0x20, count: 11 - label.utf8.count)
        func put16(_ o: Int, _ v: Int) { b[o] = UInt8(v & 0xff); b[o + 1] = UInt8(v >> 8) }
        b.replaceSubrange(0..<3, with: [0xEB, 0x3C, 0x90])
        b.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
        put16(11, 512)          // bytes per sector
        b[13] = 1               // sectors per cluster
        put16(14, 1)            // reserved sectors
        b[16] = 2               // FATs
        put16(17, 224)          // root entries
        put16(19, 2880)         // sectors
        b[21] = 0xF0            // media: 3.5" floppy
        put16(22, 9)            // sectors per FAT
        put16(24, 18)           // sectors per track
        put16(26, 2)            // heads
        b[38] = 0x29
        let serial = UInt32.random(in: 0...UInt32.max)
        for i in 0..<4 { b[39 + i] = UInt8(serial >> (8 * i) & 0xff) }
        b.replaceSubrange(43..<54, with: labelBytes)
        b.replaceSubrange(54..<62, with: Array("FAT12   ".utf8))
        b[510] = 0x55
        b[511] = 0xAA
        for fat in 0..<2 {
            let o = (1 + fat * 9) * 512
            b.replaceSubrange(o..<o + 3, with: [0xF0, 0xFF, 0xFF])
        }
        if !rawLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            let root = 19 * 512
            b.replaceSubrange(root..<root + 11, with: labelBytes)
            b[root + 11] = 0x08
        }
        return b
    }

    // MARK: Helpers

    /// The name shown on the MPC: up to 16 plain characters.
    nonisolated static func displayName(_ raw: String, fallback: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value < 127 }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(16))
    }

    /// Converts audio data to 16-bit 44.1 kHz and splits it into channels for a .SND.
    nonisolated static func convertToMPC(_ source: Data, name: String) throws -> [[Int16]] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent(name)
        try source.write(to: input)
        return try convertToMPC(input)
    }

    nonisolated static func convertToMPC(_ input: URL) throws -> [[Int16]] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try AudioPrep.writeMPCWav(from: input, to: output)
        return try pcmChannels(fromWAV: Data(contentsOf: output))
    }

    /// The 16-bit PCM in a WAV file, one array per channel (first two kept).
    nonisolated static func pcmChannels(fromWAV wav: Data) throws -> [[Int16]] {
        let b = [UInt8](wav)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF" else { throw MPCFormatError.truncated }
        var o = 12
        var channelCount = 1
        while o + 8 <= b.count {
            let id = String(decoding: b[o..<o + 4], as: UTF8.self)
            let size = u32(o + 4)
            if id == "fmt " { channelCount = max(1, u16(o + 10)) }
            if id == "data" {
                let end = min(b.count, o + 8 + size)
                let frames = (end - o - 8) / (2 * channelCount)
                var out = Array(repeating: [Int16](repeating: 0, count: frames), count: min(channelCount, 2))
                for f in 0..<frames {
                    for c in out.indices {
                        let p = o + 8 + (f * channelCount + c) * 2
                        out[c][f] = Int16(bitPattern: UInt16(b[p]) | UInt16(b[p + 1]) << 8)
                    }
                }
                return out
            }
            o += 8 + size + (size & 1)
        }
        throw MPCFormatError.truncated
    }
}
