import Foundation
import AVFoundation

/// An Akai S1000/S3000 sample file: a header (150 bytes for S1000-family,
/// 192 for S3000-family) followed by 16-bit signed little-endian mono PCM.
///
/// Header fields used here:
/// - 0: format (3), 1: rate flag (1 = 44.1 kHz, 0 = 22.05 kHz), 2: original note
/// - 3–14: name, 15: 0x80, 19: loop mode (2 = no looping)
/// - 26–29: length in samples, 30–33: start, 34–37: end
/// - 138–139: sample rate in Hz (S1100/S3000 extension)
/// Stereo samples are stored as two mono samples, named "… -L" and "… -R".
public struct AkaiSample: Equatable {
    public var name: String
    public var sampleRate: Int
    public var frames: [Int16]

    public enum SampleError: LocalizedError {
        case notASample
        public var errorDescription: String? { "This isn't an Akai sample." }
    }

    public init(name: String, sampleRate: Int, frames: [Int16]) {
        self.name = name
        self.sampleRate = sampleRate
        self.frames = frames
    }

    public static func headerLength(forType type: UInt8) -> Int { type & 0x80 != 0 ? 192 : 150 }

    /// Reads a sample file. `type` is its directory type byte (0x73 or 0xF3).
    public init(file: Data, type: UInt8) throws {
        let b = [UInt8](file)
        let header = Self.headerLength(forType: type)
        guard b.count >= header, b[0] == 3 else { throw SampleError.notASample }
        name = AkaiCharset.decode(b[3..<15])
        let declared = Int(b[26]) | Int(b[27]) << 8 | Int(b[28]) << 16 | Int(b[29]) << 24
        let available = (b.count - header) / 2
        let count = min(declared, available)
        let hz = Int(b[138]) | Int(b[139]) << 8
        sampleRate = hz >= 4000 ? hz : (b[1] == 0 ? 22_050 : 44_100)
        var frames = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            frames[i] = Int16(bitPattern: UInt16(b[header + 2 * i]) | UInt16(b[header + 2 * i + 1]) << 8)
        }
        self.frames = frames
    }

    public var duration: TimeInterval { Double(frames.count) / Double(max(sampleRate, 1)) }

    /// The file as stored on a disk of the given layout (header + PCM).
    public func fileData(for layout: AkaiDisk.Layout) -> Data {
        let n = frames.count
        var h = [UInt8](repeating: 0, count: layout == .s3000 ? 192 : 150)
        h[0] = 3
        h[1] = sampleRate == 44_100 ? 1 : 0
        h[2] = 60
        h.replaceSubrange(3..<15, with: AkaiCharset.encode(name))
        h[15] = 0x80
        h[19] = 2
        Self.put32(&h, 26, UInt32(n))
        Self.put32(&h, 34, UInt32(max(n - 1, 0)))
        h[136] = 0xff
        h[137] = 0xff
        let rate = UInt16(clamping: sampleRate)
        h[138] = UInt8(rate & 0xff)
        h[139] = UInt8(rate >> 8)
        var out = Data(h)
        out.reserveCapacity(h.count + 2 * n)
        frames.withUnsafeBufferPointer { buffer in
            for v in buffer {
                let u = UInt16(bitPattern: v)
                out.append(UInt8(u & 0xff))
                out.append(UInt8(u >> 8))
            }
        }
        return out
    }

    public static func fileType(for layout: AkaiDisk.Layout) -> UInt8 { layout == .s3000 ? 0xF3 : 0x73 }

    static func put32(_ h: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { h[o + i] = UInt8(v >> (8 * UInt32(i)) & 0xff) }
    }

    /// A 16-bit mono WAV file of this sample.
    public func wavData() -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(frames.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        frames.withUnsafeBufferPointer { buffer in
            for v in buffer { le16(UInt16(bitPattern: v)) }
        }
        return d
    }

    /// The sample as a float buffer for playback.
    public func pcmBuffer() -> AVAudioPCMBuffer? {
        guard !frames.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        for (i, v) in frames.enumerated() { channel[i] = Float(v) / 32768 }
        return buffer
    }
}

/// Converts any audio file macOS can read into Akai samples.
public enum AudioImport {
    public enum Channels: String, CaseIterable, Identifiable {
        /// Akai's own convention: two mono samples, "NAME -L" and "NAME -R".
        case splitLeftRight
        case mixToMono
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .splitLeftRight: return "Split into -L and -R samples"
            case .mixToMono: return "Mix to mono"
            }
        }
    }

    public enum ImportError: LocalizedError {
        case unreadable(String)
        case empty(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't read \(name) as audio."
            case .empty(let name): return "\(name) has no audio in it."
            }
        }
    }

    /// Reads `url`, converts it to 16-bit at `sampleRate` and returns one
    /// sample (mono) or two (stereo split into -L/-R). Names are based on the
    /// file name; the caller makes them unique on the disk.
    public static func samples(from url: URL, sampleRate: Int, channels: Channels) throws -> [AkaiSample] {
        let display = url.lastPathComponent
        guard let file = try? AVAudioFile(forReading: url) else { throw ImportError.unreadable(display) }
        let source = file.processingFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ImportError.empty(display)
        }
        do { try file.read(into: input) } catch { throw ImportError.unreadable(display) }

        let channelCount = Int(source.channelCount)
        let stereo = channelCount >= 2
        let outChannels: AVAudioChannelCount = stereo && channels == .splitLeftRight ? 2 : 1
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: outChannels, interleaved: false) else {
            throw ImportError.unreadable(display)
        }

        // Mix down first when asked (AVAudioConverter's own downmix can
        // change the level), so the converter only resamples.
        var resampleInput = input
        if outChannels == 1 && channelCount > 1 {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                           channels: 1, interleaved: false),
                  let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: input.frameLength),
                  let src = input.floatChannelData, let dst = mixed.floatChannelData?[0] else {
                throw ImportError.unreadable(display)
            }
            mixed.frameLength = input.frameLength
            for i in 0..<Int(input.frameLength) {
                var sum: Float = 0
                for c in 0..<channelCount { sum += src[c][i] }
                dst[i] = sum / Float(channelCount)
            }
            resampleInput = mixed
        } else if outChannels == 2 && channelCount > 2 {
            // More than stereo: keep the first two channels.
            guard let two = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                          channels: 2, interleaved: false),
                  let pair = AVAudioPCMBuffer(pcmFormat: two, frameCapacity: input.frameLength),
                  let src = input.floatChannelData, let dst = pair.floatChannelData else {
                throw ImportError.unreadable(display)
            }
            pair.frameLength = input.frameLength
            for c in 0..<2 { dst[c].update(from: src[c], count: Int(input.frameLength)) }
            resampleInput = pair
        }

        let output: AVAudioPCMBuffer
        if resampleInput.format.sampleRate == Double(sampleRate) && resampleInput.format.commonFormat == .pcmFormatFloat32
            && !resampleInput.format.isInterleaved {
            output = resampleInput
        } else {
            guard let converter = AVAudioConverter(from: resampleInput.format, to: target) else {
                throw ImportError.unreadable(display)
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            let ratio = Double(sampleRate) / resampleInput.format.sampleRate
            let capacity = AVAudioFrameCount(Double(resampleInput.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw ImportError.unreadable(display)
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .endOfStream; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return resampleInput
            }
            guard status != .error else { throw ImportError.unreadable(display) }
            output = out
        }

        guard output.frameLength > 0, let data = output.floatChannelData else { throw ImportError.empty(display) }
        let base = url.deletingPathExtension().lastPathComponent
        func ints(_ c: Int) -> [Int16] {
            (0..<Int(output.frameLength)).map { i in
                let v = (data[c][i] * 32767).rounded()
                return Int16(max(-32768, min(32767, v)))
            }
        }
        if output.format.channelCount == 2 {
            let stem = String(AkaiCharset.clean(base).prefix(10))
            return [AkaiSample(name: stem.padding(toLength: 10, withPad: " ", startingAt: 0) + "-L", sampleRate: sampleRate, frames: ints(0)),
                    AkaiSample(name: stem.padding(toLength: 10, withPad: " ", startingAt: 0) + "-R", sampleRate: sampleRate, frames: ints(1))]
        }
        return [AkaiSample(name: AkaiCharset.clean(base), sampleRate: sampleRate, frames: ints(0))]
    }
}
