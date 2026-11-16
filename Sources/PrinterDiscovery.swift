import Foundation
import Darwin

/// Stampante trovata in rete locale.
struct DiscoveredPrinter: Identifiable, Hashable {
    let id: String      // numero di serie
    let host: String
    let name: String
    let model: String
}

/// Le stampanti Bambu Lab si annunciano in rete con messaggi SSDP sulla porta UDP 2021.
/// Ascoltiamo per qualche secondo (dopo aver inviato una richiesta di ricerca) e raccogliamo le risposte.
enum PrinterDiscovery {
    static func search(seconds: Double = 6) async -> [DiscoveredPrinter] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: listen(seconds: seconds))
            }
        }
    }

    private static func listen(seconds: Double) -> [DiscoveredPrinter] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(2021).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        // Richiesta di ricerca: alcune stampanti rispondono subito invece di aspettare l'annuncio periodico.
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
        for (ip, port) in [("239.255.255.250", UInt16(1990)), ("255.255.255.255", UInt16(2021))] {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = port.bigEndian
            inet_pton(AF_INET, ip, &target.sin_addr)
            _ = search.withCString { text in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: DiscoveredPrinter] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            guard count > 0 else { continue }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            if let printer = parse(text, sender: sender) { found[printer.id] = printer }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    private static func parse(_ text: String, sender: sockaddr_in) -> DiscoveredPrinter? {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let serial = headers["usn"], !serial.isEmpty,
              headers["devmodel.bambu.com"] != nil || headers["nt"]?.contains("bambulab") == true
        else { return nil }

        var host = headers["location"] ?? ""
        if host.isEmpty {
            var addr = sender.sin_addr
            var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &chars, socklen_t(INET_ADDRSTRLEN))
            host = String(cString: chars)
        }
        let code = headers["devmodel.bambu.com"] ?? ""
        let model = PrinterModels.fromCode(code) ?? PrinterModels.fromSerial(serial) ?? code
        let name = headers["devname.bambu.com"].flatMap { $0.isEmpty ? nil : $0 } ?? model
        return DiscoveredPrinter(id: serial, host: host, name: name, model: model)
    }
}
