import Foundation
import Combine
import ServiceManagement
import UserNotifications

enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case error(String)
}

struct PrintStatus {
    var gcodeState = ""
    var percent = 0
    var remainingMinutes = 0
    var layer = 0
    var totalLayers = 0
    var nozzle: Double?
    var nozzleTarget: Double?
    var bed: Double?
    var bedTarget: Double?
    var chamber: Double?
    var taskName = ""
    var printError = 0
    var speedLevel = 0
    var wifiSignal: Int?
    var amsUnits: [AMSUnit] = []
    var externalSpool: AMSTray?
    var hms: [HMSAlert] = []
    var lightOn: Bool?

    init() {}

    init(dict: [String: Any]) {
        gcodeState = (dict["gcode_state"] as? String ?? "").uppercased()
        percent = Self.int(dict["mc_percent"]) ?? 0
        remainingMinutes = Self.int(dict["mc_remaining_time"]) ?? 0
        layer = Self.int(dict["layer_num"]) ?? 0
        totalLayers = Self.int(dict["total_layer_num"]) ?? 0
        nozzle = Self.double(dict["nozzle_temper"])
        nozzleTarget = Self.double(dict["nozzle_target_temper"])
        bed = Self.double(dict["bed_temper"])
        bedTarget = Self.double(dict["bed_target_temper"])
        chamber = Self.double(dict["chamber_temper"])
        printError = Self.int(dict["print_error"]) ?? 0
        speedLevel = Self.int(dict["spd_lvl"]) ?? 0
        if let wifi = dict["wifi_signal"] as? String {
            wifiSignal = Int(wifi.filter { $0.isNumber || $0 == "-" })
        }

        if let ams = dict["ams"] as? [String: Any] {
            let trayNow = Self.int(ams["tray_now"]) ?? 255
            let units = ams["ams"] as? [[String: Any]] ?? []
            amsUnits = units.enumerated().map { (index, unit) -> AMSUnit in
                let unitID = Self.int(unit["id"]) ?? index
                let trays = (unit["tray"] as? [[String: Any]] ?? []).enumerated().map { (slotIndex, tray) -> AMSTray in
                    let slot = Self.int(tray["id"]) ?? slotIndex
                    let letter = String(UnicodeScalar(UInt8(65 + min(max(unitID, 0), 25))))
                    return AMSTray(dict: tray, id: "\(unitID)-\(slot)", label: "\(letter)\(slot + 1)",
                                   active: unitID * 4 + slot == trayNow)
                }
                var humidity = Self.int(unit["humidity_raw"])
                if humidity == 0 { humidity = nil }
                return AMSUnit(id: unitID, humidity: humidity, temperature: Self.double(unit["temp"]),
                               trays: trays)
            }
            if let vt = dict["vt_tray"] as? [String: Any] {
                externalSpool = AMSTray(dict: vt, id: "ext", label: "Est.", active: trayNow == 254)
            }
        } else if let vt = dict["vt_tray"] as? [String: Any] {
            externalSpool = AMSTray(dict: vt, id: "ext", label: "Est.", active: false)
        }

        hms = (dict["hms"] as? [[String: Any]] ?? []).compactMap { item in
            guard let attr = Self.int(item["attr"]), let code = Self.int(item["code"]) else { return nil }
            return HMSAlert(attr: attr, code: code)
        }
        if let lights = dict["lights_report"] as? [[String: Any]],
           let chamber = lights.first(where: { ($0["node"] as? String) == "chamber_light" }) {
            lightOn = (chamber["mode"] as? String) == "on"
        }

        var name = (dict["subtask_name"] as? String) ?? ""
        if name.isEmpty { name = (dict["gcode_file"] as? String) ?? "" }
        for ext in [".gcode.3mf", ".3mf", ".gcode"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        taskName = name
    }

    var isActive: Bool { ["RUNNING", "PAUSE", "PREPARE", "SLICING"].contains(gcodeState) }

    var stateName: String {
        switch gcodeState {
        case "RUNNING": return "In stampa"
        case "PAUSE": return "In pausa"
        case "PREPARE": return "Preparazione"
        case "SLICING": return "Slicing"
        case "FINISH": return "Stampa completata"
        case "FAILED": return "Stampa fallita"
        case "IDLE": return "Pronta"
        case "": return "Sconosciuto"
        default: return gcodeState.capitalized
        }
    }

    var speedName: String? {
        switch speedLevel {
        case 1: return "Silenziosa"
        case 2: return "Standard"
        case 3: return "Sport"
        case 4: return "Ludicrous"
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }
}

struct AMSTray: Identifiable {
    let id: String
    let label: String
    let type: String
    let colorHex: String
    let remain: Int?
    let active: Bool

    var isEmpty: Bool { type.isEmpty }

    init(dict: [String: Any], id: String, label: String, active: Bool) {
        self.id = id
        self.label = label
        self.active = active
        type = (dict["tray_type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        colorHex = dict["tray_color"] as? String ?? ""
        let value = PrintStatus.int(dict["remain"])
        remain = (value ?? -1) >= 0 ? value : nil
    }
}

/// Messaggio HMS (Health Management System) della stampante.
struct HMSAlert: Identifiable, Hashable {
    let attr: Int
    let code: Int

    var id: String { fullCode }

    var fullCode: String {
        String(format: "%04X_%04X_%04X_%04X", (attr >> 16) & 0xFFFF, attr & 0xFFFF, (code >> 16) & 0xFFFF, code & 0xFFFF)
    }

    /// Modulo da cui arriva l'avviso.
    var module: String {
        switch (attr >> 24) & 0xFF {
        case 0x03: return "Movimento"
        case 0x05: return "Scheda madre"
        case 0x07: return "AMS"
        case 0x08: return "Testina"
        case 0x0C: return "Telecamera / AI"
        case 0x12: return "AMS lite"
        default: return "Stampante"
        }
    }

    var isAMS: Bool { [0x07, 0x12].contains((attr >> 24) & 0xFF) }

    /// AMS e slot coinvolti, se l'avviso riguarda una bobina.
    var amsDetail: String? {
        guard isAMS else { return nil }
        let unit = (attr >> 16) & 0xFF
        let slot = (attr >> 8) & 0xFF
        let letter = String(UnicodeScalar(UInt8(65 + min(unit, 25))))
        return slot < 4 ? "AMS \(letter), slot \(slot + 1)" : "AMS \(letter)"
    }

    /// 1 = fatale, 2 = grave, 3 = normale, 4 = informazione
    var severity: Int { (code >> 16) & 0xFFFF }

    var severityName: String {
        switch severity {
        case 1: return "Fatale"
        case 2: return "Grave"
        case 3: return "Avviso"
        default: return "Info"
        }
    }

    var wikiURL: URL? {
        URL(string: "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/\(fullCode)")
    }
}

struct AMSUnit: Identifiable {
    let id: Int
    let humidity: Int?
    let temperature: Double?
    let trays: [AMSTray]
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case cloud
    case lan

    var id: String { rawValue }
    var label: String { self == .cloud ? "Cloud" : "Rete locale" }
}

enum LoginStep: Equatable {
    case credentials
    case emailCode
    case tfa(String)
}

@MainActor
final class PrinterStore: ObservableObject {
    // Modalità
    @Published private(set) var mode: ConnectionMode

    // Rete locale
    @Published private(set) var lanHost: String
    @Published private(set) var lanSerial: String
    @Published private(set) var lanAccessCode: String

    // Account cloud
    @Published private(set) var region: CloudRegion
    @Published private(set) var email: String
    @Published private(set) var serial: String
    @Published private(set) var printerName: String
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var devices: [CloudDevice] = []
    @Published private(set) var loginStep: LoginStep = .credentials
    @Published private(set) var busy = false
    @Published var loginError: String?
    @Published private(set) var loginItemError: String?

    // Stato stampante
    @Published private(set) var state: ConnectionState = .notConfigured
    @Published private(set) var status = PrintStatus()
    @Published private(set) var hasData = false
    @Published private(set) var lastUpdate: Date?

    private var token: String?
    private var mqttUsername: String
    private var raw: [String: Any] = [:]
    private var client: MQTTClient?
    private let defaults = UserDefaults.standard
    private let notificationDelegate = NotificationDelegate()

    init() {
        let defaults = UserDefaults.standard
        mode = ConnectionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .cloud
        lanHost = defaults.string(forKey: "lanHost") ?? ""
        lanSerial = defaults.string(forKey: "lanSerial") ?? ""
        lanAccessCode = Keychain.get("lanAccessCode") ?? ""
        region = CloudRegion(rawValue: defaults.string(forKey: "region") ?? "") ?? .global
        email = defaults.string(forKey: "email") ?? ""
        serial = defaults.string(forKey: "serial") ?? ""
        printerName = defaults.string(forKey: "printerName") ?? ""
        mqttUsername = defaults.string(forKey: "mqttUsername") ?? ""
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
        token = Keychain.get("token")

        UNUserNotificationCenter.current().delegate = notificationDelegate
        if notificationsEnabled { requestNotificationPermission() }

        connect()
        if isLoggedIn {
            Task { await self.refreshDevices(silent: true) }
        }
    }

    // MARK: - Modalità e rete locale

    func setMode(_ newMode: ConnectionMode) {
        guard newMode != mode else { return }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: "mode")
        loginError = nil
        connect()
    }

    var isLANConfigured: Bool { !lanHost.isEmpty && !lanSerial.isEmpty && !lanAccessCode.isEmpty }

    func saveLAN(host: String, serial: String, accessCode: String) {
        lanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        lanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lanAccessCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(lanHost, forKey: "lanHost")
        defaults.set(lanSerial, forKey: "lanSerial")
        Keychain.set(lanAccessCode, for: "lanAccessCode")
        loginError = nil
        connect()
    }

    /// Seriale e access code della stampante scelta nel cloud, per precompilare la rete locale.
    var cloudDeviceForLAN: CloudDevice? {
        devices.first(where: { $0.id == serial }) ?? (devices.count == 1 ? devices.first : nil)
    }

    private var cloud: BambuCloud { BambuCloud(region: region) }

    var isLoggedIn: Bool { !(token ?? "").isEmpty && !mqttUsername.isEmpty }
    var isCloudConfigured: Bool { isLoggedIn && !serial.isEmpty }
    var isConfigured: Bool { mode == .cloud ? isCloudConfigured : isLANConfigured }
    private var activeSerial: String { mode == .cloud ? serial : lanSerial }

    // MARK: - Login cloud

    func login(email: String, password: String, region: CloudRegion) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        defaults.set(region.rawValue, forKey: "region")
        self.email = email
        defaults.set(email, forKey: "email")

        busy = true
        loginError = nil
        defer { busy = false }
        do {
            switch try await cloud.login(email: email, password: password) {
            case .success(let token):
                try await finishLogin(token: token)
            case .needsEmailCode:
                lastCodeSent = Date()
                loginStep = .emailCode
            case .needsTFA(let key):
                loginStep = .tfa(key)
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func submitCode(_ code: String) async {
        let code = String(code.filter(\.isNumber))
        busy = true
        loginError = nil
        defer { busy = false }
        do {
            let token: String
            switch loginStep {
            case .emailCode: token = try await cloud.login(email: email, code: code)
            case .tfa(let key): token = try await cloud.login(tfaKey: key, code: code)
            case .credentials: return
            }
            try await finishLogin(token: token)
        } catch {
            loginError = error.localizedDescription
        }
    }

    @Published private(set) var lastCodeSent: Date?

    func resendCode() async {
        busy = true
        defer { busy = false }
        do {
            try await cloud.sendEmailCode(email: email)
            lastCodeSent = Date()
            loginError = "Nuovo codice inviato a \(email). Usa solo l'ultimo: i precedenti non valgono più."
        } catch {
            loginError = error.localizedDescription
        }
    }

    func cancelLogin() {
        loginStep = .credentials
        loginError = nil
    }

    private func finishLogin(token: String) async throws {
        let username = try await cloud.mqttUsername(token: token)
        self.token = token
        Keychain.set(token, for: "token")
        mqttUsername = username
        defaults.set(username, forKey: "mqttUsername")
        loginStep = .credentials

        devices = try await cloud.devices(token: token)
        if let current = devices.first(where: { $0.id == serial }) {
            select(current)
        } else if devices.count == 1, let only = devices.first {
            select(only)
        } else {
            serial = ""
            defaults.removeObject(forKey: "serial")
            if devices.isEmpty { loginError = "Nessuna stampante associata a questo account." }
            connect()
        }
    }

    func refreshDevices(silent: Bool = false) async {
        guard let token, isLoggedIn else { return }
        do {
            devices = try await cloud.devices(token: token)
            if let current = devices.first(where: { $0.id == serial }), current.name != printerName {
                printerName = current.name
                defaults.set(current.name, forKey: "printerName")
            }
        } catch let error as CloudError where error.isUnauthorized {
            sessionExpired()
        } catch {
            if !silent { loginError = error.localizedDescription }
        }
    }

    func select(_ device: CloudDevice) {
        serial = device.id
        printerName = device.name
        defaults.set(serial, forKey: "serial")
        defaults.set(printerName, forKey: "printerName")
        connect()
    }

    func logout() {
        client?.stop()
        client = nil
        token = nil
        Keychain.set(nil, for: "token")
        mqttUsername = ""
        defaults.removeObject(forKey: "mqttUsername")
        devices = []
        loginStep = .credentials
        connect()
    }

    private func sessionExpired() {
        logout()
        loginError = "Sessione scaduta: accedi di nuovo."
    }

    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: "notifications")
        if enabled { requestNotificationPermission() }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Avvio al login non riuscito: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // MARK: - MQTT

    func connect() {
        client?.stop()
        client = nil
        raw = [:]
        status = PrintStatus()
        hasData = false
        lastUpdate = nil

        let newClient: MQTTClient
        let clientID = "bambugo-\(UUID().uuidString.prefix(8))"
        switch mode {
        case .cloud:
            guard isCloudConfigured, let token else { state = .notConfigured; return }
            newClient = MQTTClient(host: region.mqttHost, username: mqttUsername, password: token,
                                   clientID: clientID, subscribeTopic: "device/\(serial)/report")
        case .lan:
            guard isLANConfigured else { state = .notConfigured; return }
            newClient = MQTTClient(host: lanHost, username: "bblp", password: lanAccessCode,
                                   clientID: clientID, subscribeTopic: "device/\(lanSerial)/report",
                                   allowSelfSigned: true)
        }
        state = .connecting

        newClient.onStateChange = { [weak self, weak newClient] connected, error in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                if connected {
                    self.state = .connected
                    self.refresh()
                } else {
                    self.state = .error(error ?? "Disconnesso")
                }
            }
        }
        newClient.onAuthRejected = { [weak self, weak newClient] in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                if self.mode == .cloud {
                    self.sessionExpired()
                } else {
                    self.client = nil
                    self.state = .error("Access code errato")
                }
            }
        }
        newClient.onMessage = { [weak self, weak newClient] _, data in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                self.handle(data)
            }
        }
        client = newClient
        newClient.start()
    }

    /// Chiede alla stampante di inviare lo stato completo.
    func refresh() {
        let payload = #"{"pushing":{"sequence_id":"0","command":"pushall","version":1,"push_target":1}}"#
        client?.publish(topic: "device/\(activeSerial)/request", payload: Data(payload.utf8))
    }

    // MARK: - Comandi

    @Published var commandMessage: String?
    @Published private(set) var pendingCommand: String?

    func pause() { sendPrintCommand("pause") }
    func resume() { sendPrintCommand("resume") }
    func stop() { sendPrintCommand("stop") }

    func setLight(_ on: Bool) {
        let mode = on ? "on" : "off"
        let json = #"{"system":{"sequence_id":"0","command":"ledctrl","led_node":"chamber_light","led_mode":""# + mode
            + #"","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}"#
        guard state == .connected else { return }
        client?.publish(topic: "device/\(activeSerial)/request", payload: Data(json.utf8))
        status.lightOn = on   // aggiornamento ottimistico
        raw["lights_report"] = [["node": "chamber_light", "mode": mode]]
    }

    private func sendPrintCommand(_ command: String) {
        guard state == .connected else { return }
        let json = #"{"print":{"sequence_id":"0","command":""# + command + #"","param":""}}"#
        client?.publish(topic: "device/\(activeSerial)/request", payload: Data(json.utf8))
        commandMessage = nil
        pendingCommand = command
        let sent = command
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if self.pendingCommand == sent {
                self.pendingCommand = nil
                self.commandMessage = "La stampante non ha risposto al comando. Con il firmware recente il controllo da app di terze parti può richiedere la modalità LAN + sviluppatore."
            }
            self.refresh()
        }
    }

    private func handleCommandReply(_ dict: [String: Any]) {
        guard let command = dict["command"] as? String,
              ["pause", "resume", "stop", "ledctrl"].contains(command),
              let result = dict["result"] as? String else { return }
        if command == pendingCommand { pendingCommand = nil }
        if result.lowercased() != "success" {
            let reason = (dict["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? result
            commandMessage = "Comando rifiutato dalla stampante: \(reason)"
        } else {
            commandMessage = nil
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let system = object["system"] as? [String: Any] { handleCommandReply(system) }
        guard let print = object["print"] as? [String: Any] else { return }
        handleCommandReply(print)
        if let command = print["command"] as? String, command != "push_status" { return }

        let previousState = status.gcodeState
        // P1/A1 inviano aggiornamenti parziali: uniamo i campi a quelli già noti.
        raw = Self.deepMerge(raw, print)
        let newStatus = PrintStatus(dict: raw)
        status = newStatus
        hasData = true
        lastUpdate = Date()
        if state != .connected { state = .connected }

        notifyTransition(from: previousState, to: newStatus)
    }

    private static func deepMerge(_ base: [String: Any], _ update: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in update {
            if let old = result[key] as? [String: Any], let new = value as? [String: Any] {
                result[key] = deepMerge(old, new)
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Barra dei menu

    /// Modello della stampante (es. "P1P"), se noto dal cloud.
    var model: String {
        let id = mode == .cloud ? serial : lanSerial
        return devices.first(where: { $0.id == id })?.model ?? ""
    }

    // MARK: - Telecamera

    /// In modalità cloud permette di indicare l'IP locale per la telecamera.
    func setCameraHost(_ host: String) {
        lanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(lanHost, forKey: "lanHost")
        if lanSerial.isEmpty || lanSerial != serial, !serial.isEmpty {
            lanSerial = serial
            defaults.set(lanSerial, forKey: "lanSerial")
        }
        if let code = devices.first(where: { $0.id == serial })?.accessCode, !code.isEmpty {
            lanAccessCode = code
            Keychain.set(code, for: "lanAccessCode")
        }
    }

    /// Indirizzo e access code per la telecamera (serve la rete locale).
    var cameraEndpoint: (host: String, accessCode: String)? {
        guard !lanHost.isEmpty else { return nil }
        if mode == .lan { return lanAccessCode.isEmpty ? nil : (lanHost, lanAccessCode) }
        // In cloud: usa l'IP salvato per la rete locale, se riguarda la stessa stampante.
        guard lanSerial.isEmpty || lanSerial == serial else { return nil }
        let code = devices.first(where: { $0.id == serial })?.accessCode ?? ""
        let accessCode = code.isEmpty ? lanAccessCode : code
        return accessCode.isEmpty ? nil : (lanHost, accessCode)
    }

    /// X1 e H2 trasmettono in RTSP; P1 e A1 con il flusso JPEG sulla porta 6000.
    /// Se il modello non è noto si prova il JPEG e, se non risponde, si passa a RTSP.
    var cameraUsesRTSP: Bool {
        let m = model.uppercased()
        return m.hasPrefix("X1") || m.hasPrefix("H2")
    }

    /// P1 e A1 non hanno il sensore in camera: il valore riportato non è reale.
    var hasChamberSensor: Bool {
        let m = model.uppercased()
        if m.hasPrefix("P1") || m.hasPrefix("A1") { return false }
        return (status.chamber ?? 0) > 5
    }

    var displayName: String {
        switch mode {
        case .cloud: return printerName.isEmpty ? "Bambu Lab" : printerName
        case .lan:
            if !printerName.isEmpty && lanSerial == serial { return printerName }
            return "Stampante locale"
        }
    }

    var menuIcon: String {
        switch state {
        case .notConfigured: return "cube"
        case .connecting: return "cube.transparent"
        case .error: return "exclamationmark.triangle"
        case .connected:
            switch status.gcodeState {
            case "RUNNING", "PREPARE", "SLICING": return "cube.fill"
            case "PAUSE": return "pause.circle"
            case "FINISH": return "checkmark.circle"
            case "FAILED": return "xmark.octagon"
            default: return "cube"
            }
        }
    }

    var menuTitle: String {
        guard state == .connected, hasData else { return "" }
        switch status.gcodeState {
        case "RUNNING":
            if status.remainingMinutes > 0 {
                return "\(status.percent)% · \(Self.formatMinutes(status.remainingMinutes))"
            }
            return "\(status.percent)%"
        case "PAUSE": return "Pausa \(status.percent)%"
        case "PREPARE", "SLICING": return "Prep."
        case "FINISH": return "Finita"
        case "FAILED": return "Errore"
        default: return ""
        }
    }

    var stateDescription: String {
        switch state {
        case .notConfigured:
            if mode == .lan { return "Configura la rete locale" }
            return isLoggedIn ? "Scegli una stampante" : "Accedi con l'account Bambu Lab"
        case .connecting: return mode == .cloud ? "Connessione al cloud…" : "Connessione a \(lanHost)…"
        case .error: return "Disconnessa – nuovo tentativo tra poco"
        case .connected:
            let suffix = mode == .cloud ? " · cloud" : " · LAN"
            return (hasData ? status.stateName : "In attesa della stampante") + suffix
        }
    }

    nonisolated static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - Notifiche

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTransition(from previous: String, to new: PrintStatus) {
        guard notificationsEnabled, !previous.isEmpty, previous != new.gcodeState else { return }
        let name = new.taskName.isEmpty ? displayName : new.taskName

        switch new.gcodeState {
        case "FINISH" where ["RUNNING", "PAUSE", "PREPARE"].contains(previous):
            sendNotification(title: "Stampa completata ✅", body: name)
        case "FAILED":
            sendNotification(title: "Stampa fallita ❌", body: name)
        case "PAUSE" where previous == "RUNNING":
            sendNotification(title: "Stampa in pausa ⏸", body: "\(name) – controlla la stampante")
        default:
            break
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Mostra le notifiche anche quando l'app è "in primo piano" (il pannello è aperto).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
