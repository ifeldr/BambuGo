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

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }
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

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let print = object["print"] as? [String: Any] else { return }

        let previousState = status.gcodeState
        // P1/A1 inviano aggiornamenti parziali: uniamo i campi a quelli già noti.
        raw.merge(print) { _, new in new }
        let newStatus = PrintStatus(dict: raw)
        status = newStatus
        hasData = true
        lastUpdate = Date()
        if state != .connected { state = .connected }

        notifyTransition(from: previousState, to: newStatus)
    }

    // MARK: - Barra dei menu

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
