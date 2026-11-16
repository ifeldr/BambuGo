import Foundation
import Network
import AppKit

/// Flusso della telecamera di P1 / A1: JPEG su TLS, porta 6000, solo in rete locale.
/// (X1 e H2 usano RTSP sulla porta 322, non supportato.)
final class CameraClient {
    var onFrame: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?

    private let host: String
    private let accessCode: String
    private let queue = DispatchQueue(label: "it.ifeldr.bambugo.camera")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = true
    private var lastFrame = Date.distantPast

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

    private func connect() {
        teardown()
        let tls = NWProtocolTLS.Options()
        // Certificato self-signed della stampante.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 6000,
                                using: NWParameters(tls: tls, tcp: tcp))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }
            switch state {
            case .ready:
                conn.send(content: self.authPacket(), completion: .contentProcessed { _ in })
                self.lastFrame = Date()
                self.receive(on: conn)
                self.watchdog(conn)
            case .waiting(let error), .failed(let error):
                self.fail("Telecamera non raggiungibile (\(error.localizedDescription))")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func authPacket() -> Data {
        var data = Data()
        func le32(_ value: UInt32) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 4))
        }
        le32(0x40); le32(0x3000); le32(0); le32(0)
        for text in ["bblp", accessCode] {
            var field = Data(text.utf8.prefix(32))
            field.append(Data(repeating: 0, count: 32 - field.count))
            data.append(field)
        }
        return data
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data { self.buffer.append(data); self.parse() }
            if let error { self.fail("Telecamera: \(error.localizedDescription)"); return }
            if isComplete { self.fail("Telecamera disconnessa (access code errato?)"); return }
            self.receive(on: conn)
        }
    }

    private func parse() {
        while buffer.count >= 16 {
            let size = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            guard size > 0, size < 8_000_000 else { buffer.removeAll(); return }
            guard buffer.count >= 16 + size else { return }
            let start = buffer.startIndex + 16
            let jpeg = buffer.subdata(in: start..<(start + size))
            buffer.removeSubrange(buffer.startIndex..<(start + size))
            lastFrame = Date()
            if let image = NSImage(data: jpeg) {
                DispatchQueue.main.async { self.onFrame?(image) }
            }
        }
    }

    private func watchdog(_ conn: NWConnection) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, conn === self.connection, !self.stopped else { return }
            if Date().timeIntervalSince(self.lastFrame) > 12 {
                self.fail("Nessuna immagine dalla telecamera")
            } else {
                self.watchdog(conn)
            }
        }
    }

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
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
}
