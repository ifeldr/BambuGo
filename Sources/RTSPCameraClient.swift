import Foundation
import Network
import AppKit
import CryptoKit
import CoreMedia
import VideoToolbox

/// Interfaccia comune ai due tipi di telecamera.
protocol CameraStream: AnyObject {
    var onFrame: ((NSImage) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
}

extension CameraClient: CameraStream {}

/// Telecamera di X1 / H2: RTSP su TLS (porta 322), video H.264 via RTP interleaved su TCP.
/// Sulla stampante va attivata l'opzione "Liveview in LAN" (LAN Only Liveview).
final class RTSPCameraClient: CameraStream {
    var onFrame: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?

    private enum Step { case describe, setup, play, streaming }

    private let host: String
    private let accessCode: String
    private let queue = DispatchQueue(label: "it.ifeldr.bambugo.rtsp")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var stopped = true

    // RTSP
    private var step = Step.describe
    private var cseq = 0
    private var session: String?
    private var baseURL = ""
    private var lastRequest: (method: String, url: String, headers: [String])?
    private var digest: (realm: String, nonce: String)?
    private var authRetried = false

    // H.264
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDescription: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var nals: [[UInt8]] = []
    private var fuBuffer: [UInt8]?
    private var currentTimestamp: UInt32?
    private var lastPacket = Date.distantPast
    private var lastUIFrame = Date.distantPast

    private var streamURL: String { "rtsp://\(host):322/streaming/live/1" }

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    func start() {
        queue.async {
            self.stopped = false
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    // MARK: - Connessione

    private func connect() {
        teardown()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 322, using: NWParameters(tls: tls, tcp: tcp))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }
            switch state {
            case .ready:
                self.lastPacket = Date()
                self.receive(on: conn)
                self.send("DESCRIBE", self.streamURL, ["Accept: application/sdp"])
                self.watchdog(conn)
            case .waiting(let error), .failed(let error):
                self.fail("Telecamera non raggiungibile (\(error.localizedDescription)). Sulla stampante attiva «Liveview in LAN».")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        step = .describe
        session = nil
        digest = nil
        authRetried = false
        nals.removeAll()
        fuBuffer = nil
        currentTimestamp = nil
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        formatDescription = nil
    }

    private func fail(_ message: String) {
        teardown()
        guard !stopped else { return }
        DispatchQueue.main.async { self.onError?(message) }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.connect()
        }
    }

    private func watchdog(_ conn: NWConnection) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, conn === self.connection, !self.stopped else { return }
            if Date().timeIntervalSince(self.lastPacket) > 15 {
                self.fail("Nessuna immagine dalla telecamera")
                return
            }
            if self.step == .streaming, Int(Date().timeIntervalSince1970) % 25 < 5 {
                // keep-alive della sessione RTSP
                self.send("GET_PARAMETER", self.baseURL, [])
            }
            self.watchdog(conn)
        }
    }

    // MARK: - RTSP

    private func send(_ method: String, _ url: String, _ headers: [String]) {
        cseq += 1
        lastRequest = (method, url, headers)
        var lines = ["\(method) \(url) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: BambuGo"]
        lines.append("Authorization: " + authorization(method: method, uri: url))
        if let session { lines.append("Session: \(session)") }
        lines += headers
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func authorization(method: String, uri: String) -> String {
        if let digest {
            let ha1 = md5("bblp:\(digest.realm):\(accessCode)")
            let ha2 = md5("\(method):\(uri)")
            let response = md5("\(ha1):\(digest.nonce):\(ha2)")
            return #"Digest username="bblp", realm="\#(digest.realm)", nonce="\#(digest.nonce)", uri="\#(uri)", response="\#(response)""#
        }
        return "Basic " + Data("bblp:\(accessCode)".utf8).base64EncodedString()
    }

    private func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data {
                self.buffer.append(contentsOf: data)
                self.parse()
            }
            guard conn === self.connection else { return }
            if let error { self.fail("Telecamera: \(error.localizedDescription)"); return }
            if isComplete { self.fail("Telecamera disconnessa"); return }
            self.receive(on: conn)
        }
    }

    private func parse() {
        while !buffer.isEmpty, connection != nil {
            if buffer[0] == 0x24 {                     // '$' = pacchetto RTP interleaved
                guard buffer.count >= 4 else { return }
                let length = Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + length else { return }
                let channel = buffer[1]
                let packet = Array(buffer[4..<(4 + length)])
                buffer.removeFirst(4 + length)
                lastPacket = Date()
                if channel == 0 { handleRTP(packet) }
            } else if buffer[0] == 0x52 {              // 'R' = risposta RTSP
                guard let end = headerEnd() else {
                    if buffer.count > 64 * 1024 { buffer.removeAll() }
                    return
                }
                let headerText = String(decoding: buffer[0..<end], as: UTF8.self)
                var headers: [String: String] = [:]
                let lines = headerText.components(separatedBy: "\r\n")
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.count >= end + 4 + bodyLength else { return }
                let body = String(decoding: buffer[(end + 4)..<(end + 4 + bodyLength)], as: UTF8.self)
                buffer.removeFirst(end + 4 + bodyLength)
                let parts = (lines.first ?? "").split(separator: " ")
                let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                handleResponse(status: status, headers: headers, body: body)
            } else {
                // byte non riconosciuti: si riallinea
                if let next = buffer.firstIndex(where: { $0 == 0x24 || $0 == 0x52 }), next > 0 {
                    buffer.removeFirst(next)
                } else {
                    buffer.removeAll()
                }
            }
        }
    }

    private func headerEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4)
        where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func handleResponse(status: Int, headers: [String: String], body: String) {
        if step == .streaming { return }   // risposte ai keep-alive

        if status == 401 {
            guard !authRetried, let request = lastRequest else {
                fail("Access code rifiutato dalla telecamera")
                return
            }
            authRetried = true
            if let header = headers["www-authenticate"], header.lowercased().hasPrefix("digest") {
                digest = (value(of: "realm", in: header) ?? "", value(of: "nonce", in: header) ?? "")
            }
            send(request.method, request.url, request.headers)
            return
        }
        guard (200..<300).contains(status) else {
            fail("La telecamera ha risposto \(status). Sulla stampante attiva «Liveview in LAN».")
            return
        }
        authRetried = false

        switch step {
        case .describe:
            var base = headers["content-base"] ?? streamURL
            if base.hasSuffix("/") { base.removeLast() }
            baseURL = base
            guard let track = parseSDP(body) else { return }
            step = .setup
            send("SETUP", track, ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])
        case .setup:
            if let value = headers["session"] {
                session = value.split(separator: ";").first.map(String.init)
            }
            step = .play
            send("PLAY", baseURL, ["Range: npt=0.000-"])
        case .play:
            step = .streaming
        case .streaming:
            break
        }
    }

    private func value(of key: String, in header: String) -> String? {
        guard let range = header.range(of: key + "=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Legge l'SDP: URL della traccia video e parametri SPS/PPS.
    private func parseSDP(_ sdp: String) -> String? {
        var inVideo = false
        var control: String?
        var codec = ""
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            } else if line.hasPrefix("a=rtpmap:") {
                codec = line.uppercased()
            } else if line.hasPrefix("a=fmtp:"), let range = line.range(of: "sprop-parameter-sets=") {
                let sets = line[range.upperBound...].split(separator: ";").first ?? ""
                let decoded = sets.split(separator: ",").compactMap { Data(base64Encoded: String($0)).map { [UInt8]($0) } }
                for nal in decoded where !nal.isEmpty {
                    switch nal[0] & 0x1F {
                    case 7: sps = nal
                    case 8: pps = nal
                    default: break
                    }
                }
            }
        }
        if codec.contains("H265") || codec.contains("HEVC") {
            fail("Il video H.265 di questa stampante non è ancora supportato.")
            return nil
        }
        guard let control, control != "*" else { return baseURL }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return baseURL + "/" + control
    }

    // MARK: - RTP / H.264 (RFC 6184)

    private func handleRTP(_ p: [UInt8]) {
        guard p.count > 12 else { return }
        let csrcCount = Int(p[0] & 0x0F)
        let hasExtension = p[0] & 0x10 != 0
        let padding = p[0] & 0x20 != 0 ? Int(p[p.count - 1]) : 0
        let marker = p[1] & 0x80 != 0
        let timestamp = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard p.count >= offset + 4 else { return }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        let end = p.count - padding
        guard offset < end else { return }
        let payload = Array(p[offset..<end])

        if let currentTimestamp, currentTimestamp != timestamp { flushAccessUnit() }
        currentTimestamp = timestamp

        let type = payload[0] & 0x1F
        switch type {
        case 1...23:
            appendNAL(payload)
        case 24:   // STAP-A
            var i = 1
            while i + 2 <= payload.count {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.count else { break }
                appendNAL(Array(payload[i..<(i + size)]))
                i += size
            }
        case 28:   // FU-A
            guard payload.count > 2 else { return }
            let header = payload[1]
            if header & 0x80 != 0 {
                fuBuffer = [(payload[0] & 0xE0) | (header & 0x1F)] + payload[2...]
            } else if fuBuffer != nil {
                fuBuffer?.append(contentsOf: payload[2...])
            }
            if header & 0x40 != 0, let nal = fuBuffer {
                appendNAL(nal)
                fuBuffer = nil
            }
        default:
            break
        }

        if marker { flushAccessUnit() }
    }

    private func appendNAL(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }
        switch nal[0] & 0x1F {
        case 7:
            if nal != sps { sps = nal; resetDecoder() }
        case 8:
            if nal != pps { pps = nal; resetDecoder() }
        case 9:
            break   // access unit delimiter
        default:
            nals.append(nal)
        }
    }

    private func resetDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        formatDescription = nil
    }

    private func makeDecoder() -> Bool {
        if decoder != nil { return true }
        guard let sps, let pps else { return false }
        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return false }
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                                   decoderSpecification: nil, imageBufferAttributes: attributes,
                                                   outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { return false }
        formatDescription = description
        decoder = session
        return true
    }

    private func flushAccessUnit() {
        defer { nals.removeAll() }
        guard !nals.isEmpty, makeDecoder(), let decoder, let formatDescription else { return }

        var avcc: [UInt8] = []
        for nal in nals {
            let n = UInt32(nal.count)
            avcc += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            avcc += nal
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                                 flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copied = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }

        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, imageBuffer, _, _ in
            guard let self, status == noErr, let imageBuffer else { return }
            // Il pannello non ha bisogno di più di ~5 fotogrammi al secondo.
            let now = Date()
            guard now.timeIntervalSince(self.lastUIFrame) >= 0.2 else { return }
            self.lastUIFrame = now
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
            guard let cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async { self.onFrame?(image) }
        }
    }
}
