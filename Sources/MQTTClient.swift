import Foundation
import Network

/// Client MQTT 3.1.1 minimale su TLS, sufficiente per parlare con le stampanti Bambu Lab
/// in rete locale.
final class MQTTClient {
    var onMessage: ((String, Data) -> Void)?
    /// (connesso, messaggio di errore)
    var onStateChange: ((Bool, String?) -> Void)?
    /// Credenziali rifiutate dal broker (token scaduto o non valido): non si riprova.
    var onAuthRejected: (() -> Void)?

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let clientID: String
    private let subscribeTopic: String
    private let allowSelfSigned: Bool

    private let queue = DispatchQueue(label: "it.ifeldr.bambugo.mqtt")
    private var connection: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var lastReceived = Date()
    private var packetID: UInt16 = 1
    private var isConnected = false
    private var stopped = true

    init(host: String, port: UInt16 = 8883, username: String, password: String,
         clientID: String, subscribeTopic: String, allowSelfSigned: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.clientID = clientID
        self.subscribeTopic = subscribeTopic
        self.allowSelfSigned = allowSelfSigned
    }

    // MARK: - API pubblica

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

    func publish(topic: String, payload: Data) {
        queue.async {
            guard self.isConnected else { return }
            var body = self.encodeString(topic)
            body.append(payload)
            self.send(self.packet(0x30, body))
        }
    }

    // MARK: - Connessione

    private func connect() {
        teardown()

        let tls = NWProtocolTLS.Options()
        if allowSelfSigned {
            // Solo per connessioni dirette alla stampante (certificato self-signed).
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true

        let params = NWParameters(tls: tls, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self, conn === self.connection else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.sendConnect()
                self.receive(on: conn)
                // Se entro 15 s non arriva il CONNACK, riproviamo.
                self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, conn === self.connection, !self.isConnected else { return }
                    self.fail("Timeout di connessione")
                }
            case .waiting(let error):
                self.fail("Server non raggiungibile (\(error.localizedDescription))")
            case .failed(let error):
                self.fail("Connessione fallita (\(error.localizedDescription))")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        isConnected = false
    }

    private func fail(_ message: String) {
        let wasActive = connection != nil
        teardown()
        guard wasActive else { return }
        onStateChange?(false, message)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.connect()
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 95 {
                self.fail("Nessuna risposta dal server")
                return
            }
            self.send(Data([0xC0, 0x00])) // PINGREQ
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Invio pacchetti

    private func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error, conn === self.connection else { return }
            self.fail("Errore di invio (\(error.localizedDescription))")
        })
    }

    private func sendConnect() {
        var body = encodeString("MQTT")
        // livello protocollo 4 (3.1.1), flag: username + password + clean session, keepalive 60 s
        body.append(contentsOf: [0x04, 0xC2, 0x00, 0x3C])
        body.append(encodeString(clientID))
        body.append(encodeString(username))
        body.append(encodeString(password))
        send(packet(0x10, body))
    }

    private func sendSubscribe() {
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
        packetID = packetID &+ 1
        if packetID == 0 { packetID = 1 }
        body.append(encodeString(subscribeTopic))
        body.append(0x00) // QoS 0
        send(packet(0x82, body))
    }

    private func encodeString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var data = Data([UInt8((bytes.count >> 8) & 0xFF), UInt8(bytes.count & 0xFF)])
        data.append(bytes)
        return data
    }

    private func packet(_ header: UInt8, _ body: Data) -> Data {
        var data = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            data.append(byte)
        } while length > 0
        data.append(body)
        return data
    }

    // MARK: - Ricezione

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.buffer.append(data)
                self.parseBuffer()
            }
            guard conn === self.connection else { return }
            if let error {
                self.fail("Connessione interrotta (\(error.localizedDescription))")
                return
            }
            if isComplete {
                self.fail("Connessione chiusa dal server")
                return
            }
            self.receive(on: conn)
        }
    }

    private func parseBuffer() {
        while buffer.count >= 2 {
            let start = buffer.startIndex
            var multiplier = 1
            var remaining = 0
            var index = 1
            var complete = false

            while index < buffer.count {
                let byte = buffer[start + index]
                remaining += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { complete = true; break }
                if index > 4 { fail("Pacchetto MQTT non valido"); return }
            }
            guard complete else { return }

            let total = index + remaining
            guard buffer.count >= total else { return }

            let header = buffer[start]
            let body = Data(buffer[(start + index)..<(start + total)])
            buffer = Data(buffer[(start + total)...])
            handlePacket(header: header, body: body)
        }
    }

    private func handlePacket(header: UInt8, body: Data) {
        switch header >> 4 {
        case 2: // CONNACK
            let code: UInt8 = body.count >= 2 ? body[1] : 255
            if code == 0 {
                isConnected = true
                sendSubscribe()
                startPing()
                onStateChange?(true, nil)
            } else if code == 4 || code == 5 {
                stopped = true
                teardown()
                onAuthRejected?()
            } else {
                fail("Connessione rifiutata (codice \(code))")
            }

        case 3: // PUBLISH
            let qos = (header >> 1) & 0x03
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var offset = 2 + topicLength
            guard body.count >= offset else { return }
            let topic = String(decoding: body[2..<offset], as: UTF8.self)
            if qos > 0 { offset += 2 }
            guard body.count >= offset else { return }
            onMessage?(topic, Data(body[offset...]))

        default:
            break // SUBACK, PINGRESP, ecc.
        }
    }
}
