import Foundation
import AVFoundation


/// Reads the MPC2000/2000XL's native .SND sample format so it can be
/// auditioned on the Mac.
///
/// Layout (checked against real MPC2000XL files):
/// - 42-byte header: 0x01 0x04, 16-character name (space padded), level,
///   tune, stereo flag (byte 21), start/loop end/end/loop length (4 bytes
///   each, little-endian, in frames), loop flag, beats, sample rate
///   (bytes 40–41).
/// - Then 16-bit little-endian PCM. Stereo files store the whole left
///   channel first, then the whole right channel (not interleaved).
public struct MPCSound: Equatable {
    static let headerSize = 42

    public let name: String
    public let sampleRate: Double
    public let isStereo: Bool
    public let frameCount: Int
    /// One array per channel, -1…1.
    let channels: [[Float]]

    public enum ParseError: LocalizedError {
        case notAnMPCSample
        public var errorDescription: String? { "This isn't an MPC2000/2000XL .SND sample." }
    }

    static func isSND(_ url: URL) -> Bool { url.pathExtension.lowercased() == "snd" }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, bytes[0] == 0x01, bytes[1] == 0x04 else {
            throw ParseError.notAnMPCSample
        }
        name = String(decoding: bytes[2..<18], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        isStereo = bytes[21] != 0
        let rate = Int(bytes[40]) | Int(bytes[41]) << 8
        sampleRate = rate > 0 ? Double(rate) : 44_100

        let channelCount = isStereo ? 2 : 1
        let frames = (bytes.count - Self.headerSize) / (2 * channelCount)
        frameCount = frames
        var channels: [[Float]] = []
        for c in 0..<channelCount {
            let base = Self.headerSize + c * frames * 2
            var samples = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let lo = UInt16(bytes[base + 2 * i])
                let hi = UInt16(bytes[base + 2 * i + 1])
                samples[i] = Float(Int16(bitPattern: lo | hi << 8)) / 32768
            }
            channels.append(samples)
        }
        self.channels = channels
    }

    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    /// The sample as a non-interleaved float buffer, ready for AVAudioPlayerNode.
    public func pcmBuffer() -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { src in
                data[c].update(from: src.baseAddress!, count: frameCount)
            }
        }
        return buffer
    }
}

/// Plays samples from the mounted image (or anywhere) for auditioning.
/// Handles MPC .SND files plus anything Core Audio reads (WAV, AIFF, MP3…).
