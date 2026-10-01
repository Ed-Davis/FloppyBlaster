import Foundation
import AVFoundation

/// Turns any audio file macOS can read (WAV, AIFF, MP3, M4A, FLAC…) into a plain
/// 16-bit / 44.1 kHz PCM WAV with a minimal header, which the MPC2000XL loads reliably.
///
/// Anything that isn't a recognized audio format — MPC program/setup files
/// (.PGM, .APS, .SND, .ALL), unknown extensions, or no extension at all — is
/// copied through byte-for-byte instead of being forced through AVFoundation,
/// which would either fail outright or silently produce garbage.
enum AudioPrep {

    /// Extensions AVFoundation can actually decode as audio. Anything NOT in
    /// this list is treated as a raw pass-through file, so the app never
    /// errors out on a file it can't convert — it just copies it unchanged.
    static let audioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "caf",
        "mp3", "m4a", "mp4", "aac", "flac", "alac", "ac3", "au"
    ]

    /// MPC program/setup files the MPC2000XL itself writes and reads: Akai's
    /// own binary formats, never audio, always copied byte-for-byte.
    static let passthroughExtensions: Set<String> = ["pgm", "aps", "snd", "all"]

    nonisolated static func isPassthrough(_ url: URL) -> Bool {
        passthroughExtensions.contains(url.pathExtension.lowercased())
    }

    /// True for anything AVFoundation should attempt to decode as audio.
    /// False (including unknown/missing extensions) means "copy raw" —
    /// the app accepts any file, it just won't try to convert what isn't audio.
    nonisolated static func isConvertibleAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Naming (DOS 8.3, uppercase)

    nonisolated static func baseName(_ raw: String, fallback: String = "SAMPLE") -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var result = ""
        for ch in raw.folding(options: .diacriticInsensitive, locale: nil).uppercased() {
            if allowed.contains(ch) {
                result.append(ch)
            } else if (ch == " " || ch == ".") && result.last != "_" {
                result.append("_")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { result = fallback }
        return String(result.prefix(8))
    }

    nonisolated static func uniqueName(for source: URL, taken: Set<String>) -> String {
        uniqueName(baseName: source.deletingPathExtension().lastPathComponent,
                   extension: "WAV", taken: taken)
    }

    /// Same 8.3 uniquing logic as `uniqueName(for:taken:)`, but keeps whatever
    /// extension the caller supplies instead of forcing `.WAV`. Used for
    /// pass-through MPC files so a `.pgm` stays a `.PGM`.
    nonisolated static func uniqueName(baseName raw: String, extension ext: String, taken: Set<String>) -> String {
        let base = baseName(raw)
        let upperExt = ext.uppercased()
        var candidate = base + "." + upperExt
        var n = 1
        while taken.contains(candidate) {
            let suffix = String(n)
            candidate = String(base.prefix(8 - suffix.count)) + suffix + "." + upperExt
            n += 1
        }
        return candidate
    }

    /// 8.3 uniquing for folder names (no extension) — used when adding a
    /// folder so its name survives on the FAT-formatted MPC volume without
    /// colliding with an existing folder of the same truncated name.
    nonisolated static func uniqueFolderName(_ raw: String, taken: Set<String>) -> String {
        let base = baseName(raw, fallback: "FOLDER")
        var candidate = base
        var n = 1
        while taken.contains(candidate) {
            let suffix = String(n)
            candidate = String(base.prefix(8 - suffix.count)) + suffix
            n += 1
        }
        return candidate
    }

    // MARK: - Conversion

    nonisolated static func writeMPCWav(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat
        let channels = min(inFormat.channelCount, 2)
        let sampleRate: Double = 44_100

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                            channels: channels, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 8192) else {
            throw NSError(domain: "MPCDisk", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This audio format can't be converted."])
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameCapacity) * sampleRate / inFormat.sampleRate) + 1024
        var pcm = Data()
        var reachedEnd = false

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer, frameCount: inBuffer.frameCapacity)
                } catch {
                    reachedEnd = true
                }
                if reachedEnd || inBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }

            if outBuffer.frameLength > 0, let samples = outBuffer.int16ChannelData {
                let count = Int(outBuffer.frameLength) * Int(channels)
                pcm.append(UnsafeBufferPointer(start: samples[0], count: count))
            }
            if status == .endOfStream || status == .error || status == .inputRanDry { break }
        }

        guard !pcm.isEmpty else {
            throw NSError(domain: "MPCDisk", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The file contains no audio."])
        }

        let wav = wavFile(pcm: pcm, channels: UInt16(channels), sampleRate: UInt32(sampleRate))
        try wav.write(to: destination, options: .withoutOverwriting)
    }

    /// RIFF header with only "fmt " and "data" chunks: no metadata for the MPC to trip over.
    nonisolated static func wavFile(pcm: Data, channels: UInt16, sampleRate: UInt32) -> Data {
        var d = Data()
        func text(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        let blockAlign = channels * 2
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * UInt32(blockAlign)); u16(blockAlign); u16(16)
        text("data"); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
