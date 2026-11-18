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

@MainActor
final class PrinterStore: ObservableObject {
    // Configurazione (solo rete locale)
    @Published private(set) var host: String
    @Published private(set) var serial: String
    @Published private(set) var accessCode: String
    @Published private(set) var customName: String
    @Published private(set) var detectedModel: String
    /// Modello di ciascuna unità AMS (id → "AMS 2 Pro", "AMS HT"…), da get_version.
    @Published private(set) var amsModels: [Int: String] = [:]
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var loginItemError: String?

    // Stato stampante
    @Published private(set) var state: ConnectionState = .notConfigured
    @Published private(set) var status = PrintStatus()
    @Published private(set) var hasData = false
    @Published private(set) var lastUpdate: Date?

    private var raw: [String: Any] = [:]
    private var client: MQTTClient?
    private let defaults = UserDefaults.standard
    private let notificationDelegate = NotificationDelegate()

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "lanHost") ?? ""
        serial = defaults.string(forKey: "lanSerial") ?? ""
        accessCode = Keychain.get("lanAccessCode") ?? ""
        customName = defaults.string(forKey: "customName") ?? ""
        detectedModel = defaults.string(forKey: "printerModel") ?? ""
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true

        // Pulizia dei dati della vecchia modalità cloud.
        if defaults.object(forKey: "mode") != nil || defaults.object(forKey: "mqttUsername") != nil {
            Keychain.set(nil, for: "token")
            for key in ["mode", "region", "email", "serial", "printerName", "mqttUsername"] {
                defaults.removeObject(forKey: key)
            }
        }

        UNUserNotificationCenter.current().delegate = notificationDelegate
        if notificationsEnabled { requestNotificationPermission() }

        connect()
    }

    // MARK: - Configurazione

    var isConfigured: Bool { !host.isEmpty && !serial.isEmpty && !accessCode.isEmpty }

    func save(host: String, serial: String, accessCode: String, name: String, model: String? = nil) {
        let newSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if newSerial != self.serial {
            detectedModel = ""
        }
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serial = newSerial
        self.accessCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model, !model.isEmpty { detectedModel = model }
        defaults.set(self.host, forKey: "lanHost")
        defaults.set(self.serial, forKey: "lanSerial")
        defaults.set(customName, forKey: "customName")
        defaults.set(detectedModel, forKey: "printerModel")
        Keychain.set(self.accessCode, for: "lanAccessCode")
        connect()
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
        commandMessage = nil
        pendingCommand = nil
        amsModels = [:]

        guard isConfigured else { state = .notConfigured; return }
        let newClient = MQTTClient(host: host, username: "bblp", password: accessCode,
                                   clientID: "bambugo-\(UUID().uuidString.prefix(8))",
                                   subscribeTopic: "device/\(serial)/report",
                                   allowSelfSigned: true)
        state = .connecting

        newClient.onStateChange = { [weak self, weak newClient] connected, error in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                if connected {
                    self.state = .connected
                    self.refresh()
                    self.requestVersion()
                } else {
                    self.state = .error(error ?? "Disconnesso")
                }
            }
        }
        newClient.onAuthRejected = { [weak self, weak newClient] in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                self.client = nil
                self.state = .error("Access code errato: controllalo sul display della stampante.")
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

    private func publish(_ json: String) {
        client?.publish(topic: "device/\(serial)/request", payload: Data(json.utf8))
    }

    /// Chiede alla stampante di inviare lo stato completo.
    func refresh() {
        publish(#"{"pushing":{"sequence_id":"0","command":"pushall","version":1,"push_target":1}}"#)
    }

    /// Chiede i moduli installati, per riconoscere il modello.
    private func requestVersion() {
        publish(#"{"info":{"sequence_id":"0","command":"get_version"}}"#)
    }

    // MARK: - Comandi

    @Published var commandMessage: String?
    @Published private(set) var pendingCommand: String?

    func pause() { sendPrintCommand("pause") }
    func resume() { sendPrintCommand("resume") }
    func stop() { sendPrintCommand("stop") }

    func setLight(_ on: Bool) {
        guard state == .connected else { return }
        let mode = on ? "on" : "off"
        // Le H2 hanno una seconda luce in camera: le comandiamo insieme.
        var nodes = ["chamber_light"]
        if status.hasSecondLight { nodes.append("chamber_light2") }
        for node in nodes {
            publish(#"{"system":{"sequence_id":"0","command":"ledctrl","led_node":""# + node + #"","led_mode":""# + mode
                    + #"","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}"#)
        }
        status.lightOn = on   // aggiornamento ottimistico
        var lights = raw["lights_report"] as? [[String: Any]] ?? []
        for node in nodes {
            lights.removeAll { ($0["node"] as? String) == node }
            lights.append(["node": node, "mode": mode])
        }
        raw["lights_report"] = lights
    }

    private func sendPrintCommand(_ command: String) {
        guard state == .connected else { return }
        publish(#"{"print":{"sequence_id":"0","command":""# + command + #"","param":""}}"#)
        commandMessage = nil
        pendingCommand = command
        let sent = command
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if self.pendingCommand == sent {
                self.pendingCommand = nil
                self.commandMessage = "La stampante non ha risposto al comando. Con i firmware recenti attiva la modalità LAN e la modalità sviluppatore sul display."
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

    private func handleVersion(_ info: [String: Any]) {
        guard (info["command"] as? String) == "get_version",
              let modules = info["module"] as? [[String: Any]] else { return }

        // Modello della stampante: prima il nome commerciale del modulo "ota",
        // poi qualunque "Bambu Lab …", infine il codice interno.
        var fromOTA: String?
        var fromProduct: String?
        var fromCode: String?
        var units: [Int: String] = [:]
        for module in modules {
            let name = module["name"] as? String ?? ""
            if let unit = Self.amsUnit(module: module, name: name) {
                units[unit.id] = unit.model
                continue
            }
            if let product = module["product_name"] as? String, let model = PrinterModels.fromProductName(product) {
                if name == "ota" { fromOTA = model } else if fromProduct == nil { fromProduct = model }
            }
            if fromCode == nil, let code = module["project_name"] as? String, let model = PrinterModels.fromCode(code) {
                fromCode = model
            }
        }
        if !units.isEmpty { amsModels = units }
        if let found = fromOTA ?? fromProduct ?? fromCode, found != detectedModel {
            detectedModel = found
            defaults.set(found, forKey: "printerModel")
        }
    }

    /// Riconosce le unità AMS tra i moduli di get_version (es. "n3f/0" = AMS 2 Pro, unità A).
    private static func amsUnit(module: [String: Any], name: String) -> (id: Int, model: String)? {
        let prefixes: [(String, String)] = [
            ("ams_f1/", "AMS lite"), ("ams/", "AMS"), ("n3f/", "AMS 2 Pro"), ("n3s/", "AMS HT"), ("n10a/", "AMS 3H"),
        ]
        for (prefix, model) in prefixes where name.hasPrefix(prefix) {
            guard let id = Int(name.dropFirst(prefix.count)) else { return nil }
            return (id, model)
        }
        if name == "n10a" {
            return (PrintStatus.int(module["id"]) ?? -1, "AMS 3H")
        }
        return nil
    }

    /// Nome del modello di un'unità AMS.
    func amsModel(_ unit: AMSUnit) -> String {
        amsModels[unit.id] ?? (unit.trays.count > 4 ? amsModels[-1] : nil) ?? unit.guessedModel(printer: model)
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let system = object["system"] as? [String: Any] { handleCommandReply(system) }
        if let info = object["info"] as? [String: Any] { handleVersion(info) }
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

    /// Nel blocco "device" (ugelli, moduli…) gli elenchi possono arrivare a pezzi:
    /// li uniamo per "id". Altrove (es. bobine AMS) l'elenco nuovo sostituisce il vecchio,
    /// così uno slot svuotato non conserva il filamento precedente.
    private static func deepMerge(_ base: [String: Any], _ update: [String: Any], mergeLists: Bool = false) -> [String: Any] {
        var result = base
        for (key, value) in update {
            let merge = mergeLists || key == "device"
            if let old = result[key] as? [String: Any], let new = value as? [String: Any] {
                result[key] = deepMerge(old, new, mergeLists: merge)
            } else if mergeLists, let old = result[key] as? [[String: Any]], let new = value as? [[String: Any]],
                      !new.isEmpty, new.allSatisfy({ $0["id"] != nil }), old.allSatisfy({ $0["id"] != nil }) {
                var merged = old
                for item in new {
                    let id = "\(item["id"]!)"
                    if let index = merged.firstIndex(where: { "\($0["id"]!)" == id }) {
                        merged[index] = deepMerge(merged[index], item, mergeLists: true)
                    } else {
                        merged.append(item)
                    }
                }
                result[key] = merged
            } else {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Modello e telecamera

    /// Modello della stampante (es. "P1P"), se riconosciuto.
    var model: String {
        if !detectedModel.isEmpty { return detectedModel }
        return PrinterModels.fromSerial(serial) ?? ""
    }

    var cameraEndpoint: (host: String, accessCode: String)? {
        isConfigured ? (host, accessCode) : nil
    }

    /// P1, A1 e A2 trasmettono JPEG sulla porta 6000; X1, X2, P2, H2, H3 e R1 in RTSP.
    /// Se il modello non è noto si prova il JPEG e, se non risponde, si passa a RTSP.
    var cameraUsesRTSP: Bool {
        !model.isEmpty && !PrinterModels.usesJPEGCamera(model)
    }

    /// P1, A1 e A2 non hanno il sensore in camera: il valore riportato non è reale.
    var hasChamberSensor: Bool {
        if PrinterModels.lacksChamberSensor(model) { return false }
        return (status.chamber ?? 0) > 5
    }

    /// Incisore laser dedicato (R1) o H2 con modulo laser/lama in uso.
    var isLaserWork: Bool {
        PrinterModels.isLaserMachine(model) || status.workMode != .fdm
    }

    /// Nome dello stato, tenendo conto della modalità di lavoro.
    var stateName: String {
        var adjusted = status
        adjusted.workMode = workMode
        return adjusted.stateName
    }

    /// Modalità di lavoro effettiva: la R1 è sempre laser.
    var workMode: WorkMode {
        PrinterModels.isLaserMachine(model) && status.workMode == .fdm ? .laser : status.workMode
    }

    // MARK: - Barra dei menu

    var displayName: String {
        if !customName.isEmpty { return customName }
        if !model.isEmpty { return model }
        return "Stampante"
    }

    /// Ci sono errori o avvisi gravi da segnalare.
    var hasProblems: Bool {
        status.printError != 0 || status.hms.contains { $0.severity <= 2 }
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
        let job = workMode == .fdm ? "Stampa" : "Lavoro"

        switch new.gcodeState {
        case "FINISH" where ["RUNNING", "PAUSE", "PREPARE"].contains(previous):
            sendNotification(title: workMode == .fdm ? "Stampa completata ✅" : "Lavoro completato ✅", body: name)
        case "FAILED":
            sendNotification(title: workMode == .fdm ? "Stampa fallita ❌" : "Lavoro non riuscito ❌", body: name)
        case "PAUSE" where previous == "RUNNING":
            sendNotification(title: "\(job) in pausa ⏸", body: "\(name) – controlla la macchina")
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
