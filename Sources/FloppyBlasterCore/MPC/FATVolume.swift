import Foundation

// FAT12/16 reading and writing, from MPC Blaster 3. Floppy Blaster uses it
// for MPC2000XL floppy images: 1.44 MB DOS disks, FAT12, no partition table.

public enum FATError: LocalizedError, Equatable {
    case notFAT
    case unsupported(String)
    case diskFull(needed: Int64, free: Int64)
    case directoryFull(String)
    case nameTaken(String)
    case invalidName(String)
    case corrupt(String)
    case readOnly
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFAT:
            return "This doesn't look like an MPC disk image: no FAT filesystem was found in it."
        case .unsupported(let why):
            return why
        case .diskFull(let needed, let free):
            let f = ByteCountFormatter()
            return "Not enough space on the disk image: that needs \(f.string(fromByteCount: needed)) and \(f.string(fromByteCount: free)) is free."
        case .directoryFull(let name):
            return "\(name) is full. The top level of a floppy holds 224 entries at most."
        case .nameTaken(let name):
            return "There's already something called \(name) here."
        case .invalidName(let name):
            return "\(name) isn't a valid MPC (8.3) name."
        case .corrupt(let what):
            return "The disk image looks damaged (\(what)). Nothing was changed."
        case .readOnly:
            return "This disk image is read-only."
        case .io(let what):
            return what
        }
    }
}

// MARK: - The image file

/// The image's bytes, held in memory. Floppy Blaster edits a copy and
/// saves the whole image at once (see `MPCFloppySession`), so a removed
/// card or a crash never leaves a half-written floppy.
final class ImageFile: @unchecked Sendable {
    private(set) var bytes: [UInt8]
    let isWritable = true
    var size: UInt64 { UInt64(bytes.count) }

    init(bytes: [UInt8]) { self.bytes = bytes }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let lo = Int(offset)
        guard lo < bytes.count else { return out }
        let hi = min(bytes.count, lo + count)
        out.replaceSubrange(0..<(hi - lo), with: bytes[lo..<hi])
        return out
    }

    func write(_ chunk: [UInt8], at offset: UInt64) throws {
        let lo = Int(offset)
        guard lo + chunk.count <= bytes.count else { throw FATError.io("Write past the end of the disk image.") }
        bytes.replaceSubrange(lo..<lo + chunk.count, with: chunk)
    }

    /// Nothing to do: the session saves the whole image after each change.
    func flush() {}
}

// MARK: - Directory entries

/// Where a directory's entries live: the fixed root area, or a cluster chain.
public enum FATDirectory: Hashable, Sendable {
    case root
    case cluster(UInt32)
}

/// A file or folder in a directory.
public struct FATEntry: Hashable, Identifiable, Sendable {
    /// What to show: the long name if the entry has one (written by a Mac or
    /// PC), otherwise the 8.3 name. The MPC itself only ever sees `shortName`.
    public let name: String
    /// "NAME.EXT" (or "NAME"), uppercase, as the MPC shows it.
    public let shortName: String
    public let isDirectory: Bool
    public let size: UInt32
    public let firstCluster: UInt32
    public let modified: Date?
    /// FAT attribute bits (0x02 hidden, 0x04 system, 0x10 folder…).
    public let attributes: UInt8
    /// The directory holding this entry.
    public let parent: FATDirectory
    /// Slot numbers in the parent: any long-name slots, then the 8.3 slot.
    public let slots: [Int]

    public var id: String { "\(parent)#\(slots.last ?? -1)" }
    public var pathExtension: String { (shortName as NSString).pathExtension }
    public var asDirectory: FATDirectory { firstCluster == 0 ? .root : .cluster(firstCluster) }
    /// Files macOS leaves behind (.DS_Store, ._ resource forks, .fseventsd…).
    /// The MPC lists them as clutter, so they're hidden and can be removed.
    public var isMacClutter: Bool {
        name.hasPrefix(".")
    }
}

// MARK: - A FAT12/16 filesystem

@inline(__always) func le16(_ b: [UInt8], _ i: Int) -> Int {
    Int(b[i]) | (Int(b[i + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ i: Int) -> Int {
    let lo: Int = le16(b, i)
    let hi: Int = le16(b, i + 2)
    return lo | (hi << 16)
}

final class FATVolume: @unchecked Sendable {
    enum Kind: String { case fat12 = "FAT12", fat16 = "FAT16" }

    let image: ImageFile
    /// Byte offset of the volume in the image.
    let offset: UInt64
    let kind: Kind
    let label: String

    let bytesPerSector: Int
    let sectorsPerCluster: Int
    let reservedSectors: Int
    let fatCount: Int
    let rootEntryCount: Int
    let totalSectors: Int
    let fatSectors: Int
    let clusterCount: Int

    var clusterBytes: Int { bytesPerSector * sectorsPerCluster }
    private var rootDirSectors: Int { (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector }
    private var firstRootSector: Int { reservedSectors + fatCount * fatSectors }
    private var firstDataSector: Int { firstRootSector + rootDirSectors }
    private var endOfChain: UInt32 { kind == .fat16 ? 0xFFFF : 0xFFF }
    private var endMarkerFloor: UInt32 { kind == .fat16 ? 0xFFF8 : 0xFF8 }
    private var badCluster: UInt32 { kind == .fat16 ? 0xFFF7 : 0xFF7 }

    /// The allocation table, one value per cluster (0 and 1 are reserved).
    private var fat: [UInt32]
    /// What's on disk, to write back only the sectors that changed.
    private var fatOnDisk: [UInt8]

    /// Reads the boot sector at `offset`. Throws `notFAT` if there isn't one.
    init(image: ImageFile, offset: UInt64) throws {
        self.image = image
        self.offset = offset
        let b = try image.read(at: offset, count: 512)
        let bps = le16(b, 11)
        let spc = Int(b[13])
        let reserved = le16(b, 14)
        let fats = Int(b[16])
        let rootEntries = le16(b, 17)
        let total16 = le16(b, 19)
        let fatSize16 = le16(b, 22)
        let total32 = le32(b, 32)
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, spc & (spc - 1) == 0,
              reserved >= 1, (1...2).contains(fats) else { throw FATError.notFAT }
        guard fatSize16 > 0, rootEntries > 0 else {
            throw FATError.unsupported("This disk image uses FAT32, which the MPC2000XL can't read. Make a new image with New Image….")
        }
        let total = total16 != 0 ? total16 : total32
        bytesPerSector = bps
        sectorsPerCluster = spc
        reservedSectors = reserved
        fatCount = fats
        rootEntryCount = rootEntries
        totalSectors = total
        fatSectors = fatSize16
        let rootSectors = (rootEntries * 32 + bps - 1) / bps
        let dataSectors = total - (reserved + fats * fatSize16 + rootSectors)
        guard dataSectors > 0, total > 0,
              offset + UInt64(total) * UInt64(bps) <= image.size + UInt64(bps) else { throw FATError.notFAT }
        clusterCount = dataSectors / spc
        // The FAT type is decided by cluster count, not by the label in the boot sector.
        if clusterCount < 4085 {
            kind = .fat12
        } else if clusterCount < 65525 {
            kind = .fat16
        } else {
            throw FATError.unsupported("This disk image uses FAT32, which the MPC2000XL can't read.")
        }

        let raw = try image.read(at: offset + UInt64(reserved * bps), count: fatSize16 * bps)
        fatOnDisk = raw
        var table = [UInt32](repeating: 0, count: clusterCount + 2)
        for n in 0..<(clusterCount + 2) {
            table[n] = Self.decode(raw, n, kind)
        }
        fat = table

        // Volume label: from the root directory if there is one, else the boot sector.
        var name = b[38] == 0x29 ? String(decoding: b[43..<54], as: UTF8.self).trimmingCharacters(in: .whitespaces) : ""
        let rootOffset = offset + UInt64((reserved + fats * fatSize16) * bps)
        let rootBytes = try image.read(at: rootOffset, count: rootSectors * bps)
        for slot in 0..<rootEntries {
            let e = Array(rootBytes[slot * 32..<slot * 32 + 32])
            if e[0] == 0 { break }
            if e[0] != 0xE5 && e[11] & 0x0F == 0x08 {
                name = String(decoding: e[0..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        label = name == "NO NAME" ? "" : name
    }

    // MARK: Space

    var totalBytes: Int64 { Int64(clusterCount) * Int64(clusterBytes) }

    var freeBytes: Int64 {
        Int64(fat[2...].filter { $0 == 0 }.count) * Int64(clusterBytes)
    }

    func bytesNeeded(forFileOfSize size: Int) -> Int64 {
        Int64(max(1, (size + clusterBytes - 1) / clusterBytes)) * Int64(clusterBytes)
    }

    // MARK: Reading

    func list(_ dir: FATDirectory) throws -> [FATEntry] {
        let bytes = try directoryBytes(dir)
        var out: [FATEntry] = []
        var longParts: [Int: String] = [:]
        var longSlots: [Int] = []
        var longChecksum: UInt8?
        for slot in 0..<(bytes.count / 32) {
            let e = Array(bytes[slot * 32..<slot * 32 + 32])
            if e[0] == 0 { break }
            if e[0] == 0xE5 { longParts = [:]; longSlots = []; longChecksum = nil; continue }
            if e[11] == 0x0F {
                if e[0] & 0x40 != 0 { longParts = [:]; longSlots = [] }
                longParts[Int(e[0] & 0x1F)] = Self.longNamePart(e)
                longSlots.append(slot)
                longChecksum = e[13]
                continue
            }
            defer { longParts = [:]; longSlots = []; longChecksum = nil }
            if e[11] & 0x08 != 0 { continue }            // volume label
            if e[0] == 0x2E { continue }                 // "." and ".."
            let short = Self.shortName(e)
            var display = short.display
            if !longParts.isEmpty, longChecksum == Self.checksum(Array(e[0..<11])) {
                display = longParts.keys.sorted().compactMap { longParts[$0] }.joined()
            }
            let cluster = UInt32(le16(e, 26))
            let size = UInt32(le32(e, 28))
            let modified = Self.date(le16(e, 24), le16(e, 22))
            out.append(FATEntry(name: display, shortName: short.plain,
                                isDirectory: e[11] & 0x10 != 0,
                                size: size,
                                firstCluster: cluster,
                                modified: modified,
                                attributes: e[11],
                                parent: dir, slots: longSlots + [slot]))
        }
        return out
    }

    func read(_ entry: FATEntry) throws -> Data {
        guard !entry.isDirectory else { throw FATError.io("\(entry.name) is a folder.") }
        var out = Data()
        out.reserveCapacity(Int(entry.size))
        if entry.size == 0 { return out }
        for cluster in try chain(from: entry.firstCluster) {
            let want = min(clusterBytes, Int(entry.size) - out.count)
            out.append(contentsOf: try image.read(at: clusterOffset(cluster), count: want))
            if out.count >= Int(entry.size) { break }
        }
        guard out.count == Int(entry.size) else { throw FATError.corrupt("\(entry.name) is shorter than its directory entry says") }
        return out
    }

    // MARK: Writing

    /// Writes a new file. `name` must be a valid, unused 8.3 name.
    @discardableResult
    func createFile(in dir: FATDirectory, name: String, contents: Data, progress: ((Double) -> Void)? = nil) throws -> FATEntry {
        let raw = try Self.encodeShortName(name)
        try checkNameFree(raw, in: dir)
        let clusters = contents.isEmpty ? [] : try allocate(count: (contents.count + clusterBytes - 1) / clusterBytes)
        do {
            // 1. Data.
            for (i, cluster) in clusters.enumerated() {
                let lo = i * clusterBytes
                let hi = min(lo + clusterBytes, contents.count)
                var chunk = [UInt8](contents[contents.startIndex + lo..<contents.startIndex + hi])
                if chunk.count < clusterBytes { chunk += [UInt8](repeating: 0, count: clusterBytes - chunk.count) }
                try image.write(chunk, at: clusterOffset(cluster))
                progress?(Double(i + 1) / Double(clusters.count))
            }
            // 2. Allocation table.
            try writeFAT()
            // 3. The directory entry that makes it visible.
            let entry = Self.makeEntry(raw, attributes: 0x20, cluster: clusters.first ?? 0, size: UInt32(contents.count))
            let slot = try addEntry(entry, to: dir)
            image.flush()
            return try entryAt(slot: slot, in: dir)
        } catch {
            for c in clusters { fat[Int(c)] = 0 }
            try? writeFAT()
            throw error
        }
    }

    @discardableResult
    func createDirectory(in dir: FATDirectory, name: String) throws -> FATEntry {
        let raw = try Self.encodeShortName(name)
        try checkNameFree(raw, in: dir)
        let cluster = try allocate(count: 1)[0]
        do {
            var block = [UInt8](repeating: 0, count: clusterBytes)
            let parentCluster: UInt32
            if case .cluster(let c) = dir { parentCluster = c } else { parentCluster = 0 }
            block.replaceSubrange(0..<32, with: Self.makeEntry(Array(".          ".utf8), attributes: 0x10, cluster: cluster, size: 0))
            block.replaceSubrange(32..<64, with: Self.makeEntry(Array("..         ".utf8), attributes: 0x10, cluster: parentCluster, size: 0))
            try image.write(block, at: clusterOffset(cluster))
            try writeFAT()
            let slot = try addEntry(Self.makeEntry(raw, attributes: 0x10, cluster: cluster, size: 0), to: dir)
            image.flush()
            return try entryAt(slot: slot, in: dir)
        } catch {
            fat[Int(cluster)] = 0
            try? writeFAT()
            throw error
        }
    }

    /// Deletes a file, or a folder and everything in it.
    func delete(_ entry: FATEntry) throws {
        if entry.isDirectory && entry.firstCluster != 0 {
            for child in try list(entry.asDirectory) { try delete(child) }
        }
        // Directory entry first, so a crash leaves unused space rather than a
        // file pointing at freed clusters.
        for slot in entry.slots {
            try image.write([0xE5], at: try slotOffset(slot, in: entry.parent))
        }
        if entry.firstCluster >= 2 {
            for c in try chain(from: entry.firstCluster) { fat[Int(c)] = 0 }
            try writeFAT()
        }
        image.flush()
    }

    /// Gives an entry a new 8.3 name. Any long name is removed, so the Mac
    /// and the MPC both show the new name.
    func rename(_ entry: FATEntry, to name: String) throws {
        let raw = try Self.encodeShortName(name)
        if raw != Array(Self.encodeShortNameUnchecked(entry.shortName)) {
            try checkNameFree(raw, in: entry.parent)
        }
        guard let shortSlot = entry.slots.last else { return }
        let offset = try slotOffset(shortSlot, in: entry.parent)
        var updated = try image.read(at: offset, count: 32)
        updated.replaceSubrange(0..<11, with: raw)
        updated[12] = 0                             // no lowercase display flags
        try image.write(updated, at: offset)
        for slot in entry.slots.dropLast() {
            try image.write([0xE5], at: try slotOffset(slot, in: entry.parent))
        }
        image.flush()
    }

    func names(in dir: FATDirectory) throws -> Set<String> {
        Set(try list(dir).map { $0.shortName.uppercased() })
    }

    // MARK: Internals: clusters

    private func clusterOffset(_ cluster: UInt32) -> UInt64 {
        let sector: Int = firstDataSector + (Int(cluster) - 2) * sectorsPerCluster
        return offset + UInt64(sector) * UInt64(bytesPerSector)
    }

    func chain(from start: UInt32) throws -> [UInt32] {
        var out: [UInt32] = []
        var c = start
        var seen = Set<UInt32>()
        while c >= 2 && c < endMarkerFloor {
            guard Int(c) < fat.count, c != badCluster, seen.insert(c).inserted else {
                throw FATError.corrupt("a broken cluster chain")
            }
            out.append(c)
            c = fat[Int(c)]
        }
        return out
    }

    private func allocate(count: Int) throws -> [UInt32] {
        var picked: [UInt32] = []
        var n = 2
        while picked.count < count && n < fat.count {
            if fat[n] == 0 { picked.append(UInt32(n)) }
            n += 1
        }
        guard picked.count == count else {
            throw FATError.diskFull(needed: Int64(count) * Int64(clusterBytes), free: freeBytes)
        }
        for (i, c) in picked.enumerated() {
            fat[Int(c)] = i + 1 < picked.count ? picked[i + 1] : endOfChain
        }
        return picked
    }

    private func writeFAT() throws {
        var bytes = fatOnDisk
        for n in 0..<fat.count { Self.encode(&bytes, n, fat[n], kind) }
        let base = offset + UInt64(reservedSectors * bytesPerSector)
        for sector in 0..<fatSectors {
            let lo = sector * bytesPerSector, hi = lo + bytesPerSector
            guard bytes[lo..<hi] != fatOnDisk[lo..<hi] else { continue }
            let chunk = Array(bytes[lo..<hi])
            for copy in 0..<fatCount {
                try image.write(chunk, at: base + UInt64(copy * fatSectors * bytesPerSector + lo))
            }
        }
        fatOnDisk = bytes
    }

    static func decode(_ raw: [UInt8], _ n: Int, _ kind: Kind) -> UInt32 {
        switch kind {
        case .fat16:
            guard 2 * n + 1 < raw.count else { return 0 }
            return UInt32(le16(raw, 2 * n))
        case .fat12:
            let i = n + n / 2
            guard i + 1 < raw.count else { return 0 }
            let v = UInt32(le16(raw, i))
            return n & 1 == 0 ? v & 0xFFF : v >> 4
        }
    }

    static func encode(_ raw: inout [UInt8], _ n: Int, _ value: UInt32, _ kind: Kind) {
        switch kind {
        case .fat16:
            guard 2 * n + 1 < raw.count else { return }
            raw[2 * n] = UInt8(value & 0xFF)
            raw[2 * n + 1] = UInt8(value >> 8 & 0xFF)
        case .fat12:
            let i = n + n / 2
            guard i + 1 < raw.count else { return }
            if n & 1 == 0 {
                raw[i] = UInt8(value & 0xFF)
                raw[i + 1] = (raw[i + 1] & 0xF0) | UInt8(value >> 8 & 0x0F)
            } else {
                raw[i] = (raw[i] & 0x0F) | UInt8(value << 4 & 0xF0)
                raw[i + 1] = UInt8(value >> 4 & 0xFF)
            }
        }
    }

    // MARK: Internals: directories

    private func directoryBytes(_ dir: FATDirectory) throws -> [UInt8] {
        switch dir {
        case .root:
            return try image.read(at: offset + UInt64(firstRootSector * bytesPerSector), count: rootEntryCount * 32)
        case .cluster(let start):
            var out: [UInt8] = []
            for c in try chain(from: start) { out += try image.read(at: clusterOffset(c), count: clusterBytes) }
            return out
        }
    }

    private func slotOffset(_ slot: Int, in dir: FATDirectory) throws -> UInt64 {
        switch dir {
        case .root:
            guard slot < rootEntryCount else { throw FATError.corrupt("a directory slot out of range") }
            return offset + UInt64(firstRootSector * bytesPerSector + slot * 32)
        case .cluster(let start):
            let perCluster = clusterBytes / 32
            let clusters = try chain(from: start)
            guard slot / perCluster < clusters.count else { throw FATError.corrupt("a directory slot out of range") }
            return clusterOffset(clusters[slot / perCluster]) + UInt64(slot % perCluster * 32)
        }
    }

    private func entryAt(slot: Int, in dir: FATDirectory) throws -> FATEntry {
        guard let entry = try list(dir).first(where: { $0.slots.last == slot }) else {
            throw FATError.corrupt("a new entry couldn't be read back")
        }
        return entry
    }

    private func checkNameFree(_ raw: [UInt8], in dir: FATDirectory) throws {
        let name = Self.shortName(raw + [UInt8](repeating: 0, count: 21)).plain
        if try names(in: dir).contains(name.uppercased()) { throw FATError.nameTaken(name) }
    }

    /// Puts a 32-byte entry in the first free slot, growing a folder by a
    /// cluster if it's full. Returns the slot used.
    private func addEntry(_ entry: [UInt8], to dir: FATDirectory) throws -> Int {
        let bytes = try directoryBytes(dir)
        for slot in 0..<(bytes.count / 32) where bytes[slot * 32] == 0 || bytes[slot * 32] == 0xE5 {
            try image.write(entry, at: try slotOffset(slot, in: dir))
            return slot
        }
        guard case .cluster(let start) = dir else { throw FATError.directoryFull("The top level of this disk") }
        // Grow the folder by one zeroed cluster.
        let last = try chain(from: start).last ?? start
        let added = try allocate(count: 1)[0]
        try image.write([UInt8](repeating: 0, count: clusterBytes), at: clusterOffset(added))
        fat[Int(last)] = added
        try writeFAT()
        let slot = bytes.count / 32
        try image.write(entry, at: try slotOffset(slot, in: dir))
        return slot
    }

    // MARK: Names, dates

    static let shortNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-!#$%&'()@^`{}~")

    /// "KICK.WAV" → 11 space-padded bytes. Throws if it isn't a valid 8.3 name.
    static func encodeShortName(_ name: String) throws -> [UInt8] {
        let upper = name.uppercased()
        let parts = upper.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              (1...8).contains(parts[0].count),
              parts.count == 1 || (1...3).contains(parts[1].count),
              parts.allSatisfy({ $0.allSatisfy { shortNameCharacters.contains($0) } }) else {
            throw FATError.invalidName(name)
        }
        var out = encodeShortNameUnchecked(upper)
        if out[0] == 0xE5 { out[0] = 0x05 }
        return out
    }

    static func encodeShortNameUnchecked(_ name: String) -> [UInt8] {
        let parts = name.uppercased().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let base = Array(String(parts[0]).utf8.prefix(8))
        let ext = parts.count > 1 ? Array(String(parts[1]).utf8.prefix(3)) : []
        return base + [UInt8](repeating: 0x20, count: 8 - base.count) + ext + [UInt8](repeating: 0x20, count: 3 - ext.count)
    }

    /// The 8.3 name of an entry, plain (as stored) and for display (honouring
    /// the lowercase flags some systems set).
    static func shortName(_ e: [UInt8]) -> (plain: String, display: String) {
        var baseBytes = Array(e[0..<8])
        if baseBytes[0] == 0x05 { baseBytes[0] = 0xE5 }
        let base = String(decoding: baseBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ext = String(decoding: e[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let plain = ext.isEmpty ? base : base + "." + ext
        let flags = e.count > 12 ? e[12] : 0
        let dBase = flags & 0x08 != 0 ? base.lowercased() : base
        let dExt = flags & 0x10 != 0 ? ext.lowercased() : ext
        return (plain, dExt.isEmpty ? dBase : dBase + "." + dExt)
    }

    static func longNamePart(_ e: [UInt8]) -> String {
        var units: [UInt16] = []
        for range in [1..<11, 14..<26, 28..<32] {
            var i = range.lowerBound
            while i < range.upperBound {
                units.append(UInt16(le16(e, i)))
                i += 2
            }
        }
        if let end = units.firstIndex(where: { $0 == 0 || $0 == 0xFFFF }) { units = Array(units[..<end]) }
        return String(decoding: units, as: UTF16.self)
    }

    static func checksum(_ name: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for b in name { sum = (sum & 1 != 0 ? 0x80 : 0) &+ (sum >> 1) &+ b }
        return sum
    }

    static func makeEntry(_ name: [UInt8], attributes: UInt8, cluster: UInt32, size: UInt32, date: Date = Date()) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e.replaceSubrange(0..<11, with: name)
        e[11] = attributes
        let (d, t) = dosDateTime(date)
        e[14] = UInt8(t & 0xFF); e[15] = UInt8(t >> 8)     // created
        e[16] = UInt8(d & 0xFF); e[17] = UInt8(d >> 8)
        e[18] = UInt8(d & 0xFF); e[19] = UInt8(d >> 8)     // accessed
        e[22] = UInt8(t & 0xFF); e[23] = UInt8(t >> 8)     // modified
        e[24] = UInt8(d & 0xFF); e[25] = UInt8(d >> 8)
        e[26] = UInt8(cluster & 0xFF); e[27] = UInt8(cluster >> 8 & 0xFF)
        for i in 0..<4 { e[28 + i] = UInt8(size >> (8 * UInt32(i)) & 0xFF) }
        return e
    }

    static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(0, min(127, (c.year ?? 1980) - 1980))
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let d: Int = (year << 9) | (month << 5) | day
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        return (UInt16(d), UInt16(t))
    }

    static func date(_ d: Int, _ t: Int) -> Date? {
        guard d != 0 else { return nil }
        var c = DateComponents()
        c.year = 1980 + (d >> 9)
        c.month = d >> 5 & 0x0F
        c.day = d & 0x1F
        c.hour = t >> 11
        c.minute = t >> 5 & 0x3F
        c.second = (t & 0x1F) * 2
        return Calendar.current.date(from: c)
    }
}
