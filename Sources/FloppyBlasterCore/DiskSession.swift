import Foundation
import Darwin

/// One open floppy image: reading, changing and saving it.
///
/// Every change is written straight back to the image file. The new image
/// is written to a hidden temporary file beside it, flushed to the card,
/// then swapped in, so a removed card or a crash never leaves a half-written
/// image for the floppy emulator to load.
@MainActor
public final class DiskSession: ObservableObject {
    public let url: URL
    @Published public private(set) var disk: AkaiDisk
    @Published public private(set) var entries: [AkaiDisk.Entry]
    /// Sample rate and length, read lazily for the file list.
    @Published public private(set) var sampleInfo: [Int: (rate: Int, frames: Int)] = [:]

    public init(url: URL) throws {
        self.url = url
        let disk = try AkaiDisk(contentsOf: url)
        self.disk = disk
        self.entries = disk.entries
        readSampleInfo()
    }

    public var freeKB: Int { disk.freeBlocks }
    public var totalKB: Int { disk.usableBlocks }

    // MARK: Reading

    public func sample(_ entry: AkaiDisk.Entry) throws -> AkaiSample {
        try AkaiSample(file: disk.contents(of: entry), type: entry.type)
    }

    private func readSampleInfo() {
        var info: [Int: (rate: Int, frames: Int)] = [:]
        for entry in entries where entry.kind == .sample {
            if let s = try? sample(entry) { info[entry.index] = (s.sampleRate, s.frames.count) }
        }
        sampleInfo = info
    }

    /// The file name an entry gets when exported: WAV for samples, otherwise
    /// the raw file with an akaiutil-style extension (.p3, .s1, .x1…).
    public static func exportName(for entry: AkaiDisk.Entry, asWAV: Bool) -> String {
        let base = entry.name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let safe = base.isEmpty ? "UNNAMED" : base
        if asWAV && entry.kind == .sample { return safe + ".wav" }
        return safe + "." + rawExtension(for: entry.type)
    }

    public static func rawExtension(for type: UInt8) -> String {
        let scalar = UnicodeScalar(type & 0x7f)
        let letter = (65...122).contains(Int(type & 0x7f)) ? String(Character(scalar)).lowercased() : "bin"
        return letter == "bin" ? letter : letter + (type & 0x80 != 0 ? "3" : "1")
    }

    /// Writes the chosen files into `folder`. Samples become WAV files unless
    /// `samplesAsWAV` is false. Returns the files written.
    @discardableResult
    public func export(_ chosen: [AkaiDisk.Entry], to folder: URL, samplesAsWAV: Bool = true) throws -> [URL] {
        var written: [URL] = []
        var used = Set<String>()
        for entry in chosen {
            var name = Self.exportName(for: entry, asWAV: samplesAsWAV)
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var n = 2
            while used.contains(name.lowercased())
                    || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                name = "\(stem) \(n).\(ext)"
                n += 1
            }
            used.insert(name.lowercased())
            let data: Data
            if samplesAsWAV && entry.kind == .sample {
                data = try sample(entry).wavData()
            } else {
                data = try disk.contents(of: entry)
            }
            let destination = folder.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            written.append(destination)
        }
        return written
    }

    // MARK: Changing

    public struct ImportOptions: Equatable {
        public var sampleRate: Int
        public var channels: AudioImport.Channels
        public init(sampleRate: Int = 44_100, channels: AudioImport.Channels = .splitLeftRight) {
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public struct ImportResult: Equatable {
        public var added: [String] = []
        public var skipped: [String] = []
    }

    public enum RawImportError: LocalizedError {
        case wrongFamily(String, AkaiDisk.Layout)
        public var errorDescription: String? {
            switch self {
            case .wrongFamily(let name, let layout):
                return "\(name) was made for the other sampler family and can't go on an \(layout.displayName) disk."
            }
        }
    }

    /// Adds audio files (converted to Akai samples) and raw Akai files
    /// (.s1, .p3 and so on, copied as they are). All the new files are
    /// checked for room first; if they don't all fit, nothing is written.
    public func importFiles(_ urls: [URL], options: ImportOptions) throws -> ImportResult {
        var result = ImportResult()
        var pending: [(name: String, type: UInt8, data: Data)] = []
        var taken = Set(disk.entries.map(\.name))

        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if let type = Self.rawType(for: url) {
                    var data = try Data(contentsOf: url)
                    var fileType = type
                    let fileIsS3000 = type & 0x80 != 0
                    if fileIsS3000 != (disk.layout == .s3000) {
                        guard FileKind(type: type) == .sample else {
                            throw RawImportError.wrongFamily(url.lastPathComponent, disk.layout)
                        }
                        data = Self.convertSampleHeader(data, toS3000: disk.layout == .s3000)
                        fileType = AkaiSample.fileType(for: disk.layout)
                    }
                    let name = uniqueName(url.deletingPathExtension().lastPathComponent, taken: taken)
                    if FileKind(type: fileType) == .sample || FileKind(type: fileType) == .program, data.count >= 15 {
                        data.replaceSubrange(3..<15, with: AkaiCharset.encode(name))
                    }
                    taken.insert(name)
                    pending.append((name, fileType, data))
                } else {
                    var samples = try AudioImport.samples(from: url, sampleRate: options.sampleRate, channels: options.channels)
                    if samples.count == 2 {
                        let stem = uniquePairStem(String(samples[0].name.prefix(10)), taken: taken)
                        samples[0].name = stem + "-L"
                        samples[1].name = stem + "-R"
                    } else {
                        samples[0].name = uniqueName(samples[0].name, taken: taken)
                    }
                    for s in samples {
                        taken.insert(AkaiCharset.clean(s.name))
                        pending.append((s.name, AkaiSample.fileType(for: disk.layout), s.fileData(for: disk.layout)))
                    }
                }
            } catch {
                result.skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !pending.isEmpty else { return result }
        guard disk.entries.count + pending.count <= disk.layout.maxFiles else {
            throw AkaiDisk.DiskError.directoryFull(disk.layout.maxFiles)
        }
        let neededKB = pending.reduce(0) { $0 + max(1, ($1.data.count + 1023) / 1024) }
        guard disk.canFit(sizes: pending.map(\.data.count)) else {
            throw AkaiDisk.DiskError.diskFull(neededKB: neededKB, freeKB: disk.freeBlocks)
        }
        var updated = disk
        for file in pending {
            try updated.addFile(name: file.name, type: file.type, contents: file.data)
            result.added.append(AkaiCharset.clean(file.name))
        }
        try commit(updated)
        return result
    }

    // MARK: Programs

    /// Program numbers already used by programs on this disk.
    public var usedProgramNumbers: Set<Int> {
        var used = Set<Int>()
        for entry in entries where entry.kind == .program {
            if let data = try? disk.contents(of: entry), data.count > 15 { used.insert(Int(data[15])) }
        }
        return used
    }

    /// The lowest program number no program on the disk uses, so loading the
    /// whole disk doesn't stack the new program on top of another one.
    public var nextProgramNumber: Int {
        let used = usedProgramNumbers
        return (0...127).first { !used.contains($0) } ?? 0
    }

    public struct MadeProgram: Equatable {
        public var name: String
        public var keys: Int
        public var programNumber: Int
    }

    /// Writes a new program to the disk that plays `keys` one per key from C1
    /// up, each at its recorded pitch.
    @discardableResult
    public func makeProgram(named rawName: String, keys: [AkaiProgram.Key]) throws -> MadeProgram {
        let fallback = keys.first.map { String($0.label.prefix(8)) + " KIT" } ?? "NEW KIT"
        let cleaned = AkaiCharset.clean(rawName).isEmpty ? fallback : rawName
        let name = disk.uniqueName(cleaned)
        let number = nextProgramNumber
        let data = try AkaiProgram.fileData(name: name, programNumber: number, keys: keys, layout: disk.layout)
        var updated = disk
        try updated.addFile(name: name, type: AkaiProgram.fileType(for: disk.layout), contents: data)
        try commit(updated)
        return MadeProgram(name: name, keys: keys.count, programNumber: number)
    }

    public func delete(_ chosen: [AkaiDisk.Entry]) throws {
        var updated = disk
        // Highest index first, so earlier indexes stay valid as the directory closes up.
        for entry in chosen.sorted(by: { $0.index > $1.index }) {
            guard let current = updated.entries.first(where: { $0.index == entry.index }) else { continue }
            try updated.delete(current)
        }
        try commit(updated)
    }

    public func rename(_ entry: AkaiDisk.Entry, to name: String) throws {
        var updated = disk
        try updated.rename(entry, to: name)
        try commit(updated)
    }

    public func renameVolume(_ name: String) throws {
        var updated = disk
        updated.setVolumeName(name)
        try commit(updated)
    }

    /// Writes `updated` to the image file, then adopts it.
    private func commit(_ updated: AkaiDisk) throws {
        try Self.write(updated.data, to: url)
        disk = updated
        entries = updated.entries
        readSampleInfo()
    }

    // MARK: Helpers

    /// Writes beside the destination under a hidden name, flushes it to the
    /// device, then renames it over the original.
    public static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".FloppyBlaster-\(UUID().uuidString.prefix(8)).tmp")
        do {
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
            try handle.close()
            guard Darwin.rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// The Akai type byte for a raw file's extension (.s3 → 0xF3, .p1 → 0x70), or nil.
    static func rawType(for url: URL) -> UInt8? {
        let ext = url.pathExtension.lowercased()
        guard ext.count == 2, let letter = ext.first?.asciiValue, (97...122).contains(letter),
              let family = ext.last, family == "1" || family == "3" else { return nil }
        return family == "3" ? letter | 0x80 : letter
    }

    /// S1000 and S3000 sample headers share their first 150 bytes; S3000
    /// adds 42 more. Keeps loop points and tuning when moving between them.
    static func convertSampleHeader(_ data: Data, toS3000: Bool) -> Data {
        let bytes = [UInt8](data)
        if toS3000 {
            guard bytes.count >= 150 else { return data }
            return Data(bytes[0..<150] + [UInt8](repeating: 0, count: 42) + bytes[150...])
        } else {
            guard bytes.count >= 192 else { return data }
            return Data(bytes[0..<150] + bytes[192...])
        }
    }

    func uniqueName(_ name: String, taken: Set<String>) -> String {
        disk.uniqueName(name, extraTaken: taken)
    }

    /// A stem (10 characters, padded) for which both "-L" and "-R" names are free.
    func uniquePairStem(_ stem: String, taken: Set<String>) -> String {
        let all = taken.union(disk.entries.map(\.name))
        func pad(_ s: String) -> String { String(AkaiCharset.clean(s).prefix(10)).padding(toLength: 10, withPad: " ", startingAt: 0) }
        var candidate = pad(stem)
        var n = 2
        while all.contains(AkaiCharset.clean(candidate + "-L")) || all.contains(AkaiCharset.clean(candidate + "-R")) {
            let suffix = " \(n)"
            candidate = pad(String(AkaiCharset.clean(stem).prefix(10 - suffix.count)) + suffix)
            n += 1
        }
        return candidate
    }

    /// Creates a blank S3000-format disk image at `url`.
    public static func createBlank(at url: URL, layout: AkaiDisk.Layout = .s3000, volumeName: String? = nil) throws {
        var disk = AkaiDisk.blank(layout)
        if let volumeName, !volumeName.isEmpty { disk.setVolumeName(volumeName) }
        try write(disk.data, to: url)
    }

    /// The next free numbered name in `folder` (001.img, 002.img…), matching
    /// how FlashFloppy blank-disk folders are usually laid out.
    public static func nextBlankName(in folder: URL) -> String {
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        for n in 1...999 {
            let name = String(format: "%03d.img", n)
            if !existing.contains(name) { return name }
        }
        return "NEW.img"
    }
}
