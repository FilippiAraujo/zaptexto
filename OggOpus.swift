// Decodes WhatsApp voice messages (Opus inside an Ogg container) without ffmpeg.
// macOS can decode Opus packets natively; it just can't read the Ogg container,
// so we split the pages into packets here and hand them to AVAudioConverter.

import AVFoundation

enum OggOpusError: LocalizedError {
    case notOgg, notOpus, unsupported, decode(String)
    var errorDescription: String? {
        switch self {
        case .notOgg: "not an Ogg file"
        case .notOpus: "not an Opus stream"
        case .unsupported: "audio format not supported"
        case .decode(let m): "could not decode audio (\(m))"
        }
    }
}

struct OggOpusStream {
    let channels: Int
    let packets: [Data]

    /// Splits an Ogg file into its packets (https://www.rfc-editor.org/rfc/rfc3533).
    init(data: Data) throws {
        let b = [UInt8](data)
        var packets: [Data] = []
        var current = Data()
        var p = 0
        while p + 27 <= b.count {
            guard b[p] == 0x4F, b[p + 1] == 0x67, b[p + 2] == 0x67, b[p + 3] == 0x53 else { throw OggOpusError.notOgg }
            let segments = Int(b[p + 26])
            let table = p + 27
            var body = table + segments
            guard body <= b.count else { break }
            for s in 0..<segments {
                let len = Int(b[table + s])
                guard body + len <= b.count else { break }
                current.append(contentsOf: b[body..<(body + len)])
                body += len
                // A segment shorter than 255 bytes ends the packet; otherwise it continues
                // (possibly on the next page).
                if len < 255 { packets.append(current); current = Data() }
            }
            p = body
        }
        // Packet 0 is OpusHead, packet 1 is OpusTags (https://www.rfc-editor.org/rfc/rfc7845).
        guard packets.count >= 2, packets[0].count >= 19, packets[0].starts(with: Array("OpusHead".utf8))
        else { throw OggOpusError.notOpus }
        channels = Int(packets[0][packets[0].startIndex + 9])
        guard channels == 1 || channels == 2 else { throw OggOpusError.unsupported }
        self.packets = packets.dropFirst(2).filter { !$0.isEmpty }
    }

    /// Samples (at 48 kHz) in one Opus packet, from its TOC byte (RFC 6716, section 3.1).
    static func frames(in packet: Data) -> Int {
        let b = [UInt8](packet.prefix(2))
        guard let toc = b.first else { return 0 }
        let config = Int(toc >> 3)
        let tenthsOfMs: Int // frame duration in 0.1 ms
        switch config {
        case 0...11: tenthsOfMs = [100, 200, 400, 600][config % 4]   // SILK
        case 12...15: tenthsOfMs = [100, 200][config % 2]            // Hybrid
        default: tenthsOfMs = [25, 50, 100, 200][config % 4]         // CELT
        }
        let count: Int
        switch toc & 0x3 {
        case 0: count = 1
        case 1, 2: count = 2
        default: count = b.count > 1 ? Int(b[1] & 0x3F) : 1
        }
        return count * tenthsOfMs * 48 / 10
    }
}

/// Decodes an .opus file to a mono 48 kHz PCM .caf file.
func decodeOggOpus(from src: URL, to dst: URL) throws {
    let ogg = try OggOpusStream(data: Data(contentsOf: src))

    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(ogg.channels),
        mBitsPerChannel: 0, mReserved: 0)
    guard let inFormat = AVAudioFormat(streamDescription: &asbd),
          let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat),
          let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 48000)
    else { throw OggOpusError.unsupported }
    converter.downmix = true

    let file = try AVAudioFile(forWriting: dst, settings: outFormat.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let maxPacket = max(ogg.packets.map(\.count).max() ?? 1, 1)
    var next = 0

    while true {
        out.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard next < ogg.packets.count else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let packet = ogg.packets[next]
            next += 1
            let buf = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: maxPacket)
            packet.withUnsafeBytes { buf.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            buf.packetDescriptions![0] = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: UInt32(OggOpusStream.frames(in: packet)), mDataByteSize: UInt32(packet.count))
            buf.packetCount = 1
            buf.byteLength = UInt32(packet.count)
            inputStatus.pointee = .haveData
            return buf
        }
        if status == .error { throw OggOpusError.decode(error?.localizedDescription ?? "unknown") }
        if out.frameLength > 0 { try file.write(from: out) }
        if status == .endOfStream || status == .inputRanDry { break }
    }
}
