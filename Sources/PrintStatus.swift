import Foundation

// MARK: - Stato della macchina

/// Modalità di lavoro della macchina: le H2 con modulo laser o lama, e la R1, non stampano.
enum WorkMode: Equatable {
    case fdm, laser, cut
}

/// Modulo montato sulla testina (H2D, H2S, H2C, A2L…).
enum ToolModule: Equatable {
    case laser10, laser40, cutter, other(String)

    var name: String {
        switch self {
        case .laser10: return "Laser 10 W"
        case .laser40: return "Laser 40 W"
        case .cutter: return "Lama da taglio"
        case .other: return "Modulo accessorio"
        }
    }

    var systemImage: String {
        switch self {
        case .laser10, .laser40: return "rays"
        case .cutter: return "scissors"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// Temperatura di un ugello (le stampanti a doppio ugello ne hanno due: 0 = destro, 1 = sinistro).
struct NozzleTemp: Identifiable {
    let id: Int
    let current: Double?
    let target: Double?

    var sideName: String { id == 1 ? "Sinistro" : "Destro" }
    var sideLetter: String { id == 1 ? "S" : "D" }
}

struct PrintStatus {
    var gcodeState = ""
    var percent = 0
    var remainingMinutes = 0
    var layer = 0
    var totalLayers = 0
    var nozzle: Double?
    var nozzleTarget: Double?
    /// Tutti gli ugelli, se la stampante li riporta separatamente.
    var nozzles: [NozzleTemp] = []
    /// Ugello in uso (0 = destro, 1 = sinistro).
    var activeExtruder = 0
    var bed: Double?
    var bedTarget: Double?
    var chamber: Double?
    var chamberTarget: Double?
    var taskName = ""
    var printError = 0
    var speedLevel = 0
    var wifiSignal: Int?
    var amsUnits: [AMSUnit] = []
    var externalSpools: [AMSTray] = []
    var hms: [HMSAlert] = []
    var lightOn: Bool?
    var hasSecondLight = false
    var workMode: WorkMode = .fdm
    var toolModule: ToolModule?

    var isDualNozzle: Bool { nozzles.count > 1 }

    init() {}

    init(dict: [String: Any]) {
        gcodeState = (dict["gcode_state"] as? String ?? "").uppercased()
        percent = Self.int(dict["mc_percent"]) ?? 0
        remainingMinutes = Self.int(dict["mc_remaining_time"]) ?? 0
        layer = Self.int(dict["layer_num"]) ?? 0
        totalLayers = Self.int(dict["total_layer_num"]) ?? 0
        printError = Self.int(dict["print_error"]) ?? 0
        speedLevel = Self.int(dict["spd_lvl"]) ?? 0
        if let wifi = dict["wifi_signal"] as? String {
            wifiSignal = Int(wifi.filter { $0.isNumber || $0 == "-" })
        }

        let device = dict["device"] as? [String: Any] ?? [:]

        // Temperature. I firmware recenti mettono i valori nel blocco "device", con la
        // parola bassa = temperatura attuale e la parola alta = obiettivo.
        let extruder = device["extruder"] as? [String: Any] ?? [:]
        let extruderInfo = (extruder["info"] as? [[String: Any]] ?? [])
            .filter { entry in
                guard let id = Self.int(entry["id"]) else { return false }
                return id >= 0 && id < 16
            }
            .sorted { (Self.int($0["id"]) ?? 0) < (Self.int($1["id"]) ?? 0) }
        nozzles = extruderInfo.map { entry -> NozzleTemp in
            let id = Self.int(entry["id"]) ?? 0
            let packed = Self.packed(entry["temp"])
            return NozzleTemp(id: id, current: packed?.current, target: packed?.target)
        }
        let extruderCount = (Self.int(extruder["state"]) ?? 0) & 0xF
        if nozzles.count > 1 || extruderCount > 1 {
            let active = ((Self.int(extruder["state"]) ?? 0) >> 4) & 0xF
            activeExtruder = active == 1 ? 1 : 0   // 15 = cambio ugello in corso
        }
        if isDualNozzle {
            let active = nozzles.first { $0.id == activeExtruder } ?? nozzles[0]
            nozzle = active.current
            nozzleTarget = active.target
        } else if let single = nozzles.first, single.current != nil {
            nozzle = single.current
            nozzleTarget = single.target
        } else {
            nozzle = Self.double(dict["nozzle_temper"])
            nozzleTarget = Self.double(dict["nozzle_target_temper"])
        }

        if let packed = Self.packed(Self.dictionary(device, "bed", "info")?["temp"]) {
            bed = packed.current
            bedTarget = packed.target
        } else {
            bed = Self.double(dict["bed_temper"])
            bedTarget = Self.double(dict["bed_target_temper"])
        }

        if let packed = Self.packed(Self.dictionary(device, "ctc", "info")?["temp"]) {
            chamber = packed.current
            chamberTarget = (packed.target ?? 0) > 0 ? packed.target : nil
        } else {
            chamber = Self.double(dict["chamber_temper"])
        }

        // Modalità di lavoro (bitmask): 0x1 stampa, 0x10 laser, 0x100 taglio.
        let mode = Self.int(device["type"]) ?? 1
        if mode & 0x10 != 0 { workMode = .laser } else if mode & 0x100 != 0 { workMode = .cut }

        if let tool = device["ext_tool"] as? [String: Any], Self.int(tool["mount"]) == 1 {
            let type = (tool["type"] as? String ?? "").uppercased()
            switch type {
            case "LB00": toolModule = .laser10
            case "LB01": toolModule = .laser40
            case "CP00": toolModule = .cutter
            default: toolModule = .other(type)
            }
        }

        parseFilaments(dict, device: device, extruderInfo: extruderInfo)

        hms = (dict["hms"] as? [[String: Any]] ?? []).compactMap { item in
            guard let attr = Self.int(item["attr"]), let code = Self.int(item["code"]) else { return nil }
            return HMSAlert(attr: attr, code: code)
        }
        if let lights = dict["lights_report"] as? [[String: Any]] {
            if let chamber = lights.first(where: { ($0["node"] as? String) == "chamber_light" }) {
                lightOn = (chamber["mode"] as? String) == "on"
            }
            hasSecondLight = lights.contains { ($0["node"] as? String) == "chamber_light2" }
        }

        var name = (dict["subtask_name"] as? String) ?? ""
        if name.isEmpty { name = (dict["gcode_file"] as? String) ?? "" }
        for ext in [".gcode.3mf", ".3mf", ".gcode"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        taskName = name
    }

    // MARK: Filamenti

    /// Posizione di una bobina: unità AMS (o 254/255 per le bobine esterne) e slot.
    private struct TrayRef: Hashable {
        let unit: Int
        let slot: Int
    }

    /// Decodifica "snow" (firmware recenti): unità nel byte alto, slot nel byte basso.
    private static func decodeSnow(_ value: Int) -> TrayRef? {
        let unit = (value >> 8) & 0xFF
        let slot = value & 0xFF
        if slot == 0xFF { return nil }
        if unit >= 254 { return TrayRef(unit: unit, slot: 0) }   // bobina esterna
        return TrayRef(unit: unit, slot: slot)
    }

    /// Decodifica "tray_now" (firmware storici, un solo ugello).
    private static func decodeTrayNow(_ value: Int) -> TrayRef? {
        switch value {
        case 255: return nil
        case 254: return TrayRef(unit: 254, slot: 0)
        case 128...253: return TrayRef(unit: value, slot: 0)   // AMS HT: id 128-135
        default: return TrayRef(unit: value >> 2, slot: value & 0x3)
        }
    }

    private mutating func parseFilaments(_ dict: [String: Any], device: [String: Any], extruderInfo: [[String: Any]]) {
        let ams = dict["ams"] as? [String: Any] ?? [:]

        // Bobina caricata in ciascun ugello.
        var loaded: [TrayRef: Int] = [:]   // posizione → ugello
        var activeRef: TrayRef?
        let snows = extruderInfo.compactMap { entry -> (Int, TrayRef)? in
            guard let id = Self.int(entry["id"]), let snow = Self.int(entry["snow"]),
                  let ref = Self.decodeSnow(snow) else { return nil }
            return (id, ref)
        }
        if !extruderInfo.isEmpty && extruderInfo.contains(where: { $0["snow"] != nil }) {
            for (id, ref) in snows {
                loaded[ref] = id
                if id == activeExtruder || snows.count == 1 { activeRef = ref }
            }
        } else if let trayNow = Self.int(ams["tray_now"]), let ref = Self.decodeTrayNow(trayNow) {
            loaded[ref] = 0
            activeRef = ref
        }

        let dual = isDualNozzle
        func loadedOn(_ ref: TrayRef) -> String? {
            guard dual, let nozzle = loaded[ref] else { return nil }
            return nozzle == 1 ? "S" : "D"
        }

        // Unità AMS.
        let units = ams["ams"] as? [[String: Any]] ?? []
        amsUnits = units.enumerated().compactMap { (index, unit) -> AMSUnit? in
            let unitID = Self.int(unit["id"]) ?? index
            guard unitID >= 0 else { return nil }
            let zones = unit["zone_info"] as? [[String: Any]] ?? []
            let trays = (unit["tray"] as? [[String: Any]] ?? []).enumerated().map { (slotIndex, tray) -> AMSTray in
                let slot = Self.int(tray["id"]) ?? slotIndex
                let ref = TrayRef(unit: unitID, slot: slot)
                return AMSTray(dict: tray, id: "\(unitID)-\(slot)",
                               label: AMSUnit.slotLabel(unit: unitID, slot: slot),
                               active: ref == activeRef, loadedOn: loadedOn(ref))
            }.sorted { $0.slotIndex < $1.slotIndex }

            var humidity = Self.int(unit["humidity_raw"])
            var temperature = Self.double(unit["temp"])
            if (humidity ?? 0) <= 0 || humidity! > 100 {
                humidity = zones.compactMap { Self.int($0["humidity_raw"]) }.filter { $0 > 0 && $0 <= 100 }.max()
            }
            if (temperature ?? 0) <= 0 {
                temperature = zones.compactMap { Self.double($0["temp"]) }.filter { $0 > 0 }.max()
            }
            var drying = Self.int(unit["dry_time"]) ?? 0
            if drying <= 0 { drying = zones.compactMap { Self.int($0["dry_time"]) }.max() ?? 0 }

            // Ugello a cui è collegata l'unità (H2D, H2C, X2D): bit 8-11 di "info".
            var nozzle: String?
            if dual, let info = unit["info"] {
                let value: Int? = (info as? String).flatMap { Int($0, radix: 16) } ?? Self.int(info)
                switch value.map({ ($0 >> 8) & 0xF }) {
                case 0?: nozzle = "Destro"
                case 1?: nozzle = "Sinistro"
                case 0xE?: nozzle = "Selettore"
                default: break
                }
            }
            return AMSUnit(id: unitID, humidity: humidity, temperature: temperature,
                           dryingMinutes: max(drying, 0), nozzle: nozzle, trays: trays)
        }.sorted { $0.id < $1.id }

        // Bobine esterne: "vt_tray" (un ugello) o "vir_slot" (una per ugello).
        var external: [[String: Any]] = []
        if let slots = dict["vir_slot"] as? [[String: Any]] {
            external = slots
        } else if let vt = dict["vt_tray"] as? [String: Any] {
            external = [vt]
        }
        externalSpools = external.compactMap { tray -> AMSTray? in
            let id = Self.int(tray["id"]) ?? 254
            let ref = TrayRef(unit: id, slot: 0)
            var label = "Est."
            if dual {
                label = id == 254 ? "Est. S" : (id == 255 ? "Est. D" : "Est.")
            } else if external.count > 1 {
                label = "Est. \(256 - id)"
            }
            return AMSTray(dict: tray, id: "ext-\(id)", label: label,
                           active: ref == activeRef, loadedOn: loadedOn(ref))
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: Stato

    var isActive: Bool { ["RUNNING", "PAUSE", "PREPARE", "SLICING"].contains(gcodeState) }

    var stateName: String {
        switch gcodeState {
        case "RUNNING":
            switch workMode {
            case .fdm: return "In stampa"
            case .laser: return "Laser in funzione"
            case .cut: return "Taglio in corso"
            }
        case "PAUSE": return "In pausa"
        case "PREPARE": return "Preparazione"
        case "SLICING": return "Slicing"
        case "FINISH": return workMode == .fdm ? "Stampa completata" : "Lavoro completato"
        case "FAILED": return workMode == .fdm ? "Stampa fallita" : "Lavoro non riuscito"
        case "IDLE": return "Pronta"
        case "": return "Sconosciuto"
        default: return gcodeState.capitalized
        }
    }

    var speedName: String? {
        guard workMode == .fdm else { return nil }
        switch speedLevel {
        case 1: return "Silenziosa"
        case 2: return "Standard"
        case 3: return "Sport"
        case 4: return "Ludicrous"
        default: return nil
        }
    }

    // MARK: Conversioni

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }

    /// Temperatura "impacchettata": parola bassa = attuale, parola alta = obiettivo.
    static func packed(_ value: Any?) -> (current: Double?, target: Double?)? {
        guard let raw = int(value), raw >= 0 else { return nil }
        return (Double(raw & 0xFFFF), Double((raw >> 16) & 0xFFFF))
    }

    static func dictionary(_ dict: [String: Any], _ keys: String...) -> [String: Any]? {
        var current: [String: Any]? = dict
        for key in keys { current = current?[key] as? [String: Any] }
        return current
    }
}

// MARK: - Bobine e AMS

struct AMSTray: Identifiable {
    let id: String
    let label: String
    let slotIndex: Int
    let type: String
    let colorHex: String
    let remain: Int?
    /// Bobina in uso nell'ugello attivo.
    let active: Bool
    /// Ugello in cui è caricata ("S" o "D"), sulle stampanti a doppio ugello.
    let loadedOn: String?

    var isEmpty: Bool { type.isEmpty }

    init(dict: [String: Any], id: String, label: String, active: Bool, loadedOn: String? = nil) {
        self.id = id
        self.label = label
        self.active = active
        self.loadedOn = loadedOn
        slotIndex = PrintStatus.int(dict["id"]) ?? 0
        type = (dict["tray_type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        colorHex = dict["tray_color"] as? String ?? ""
        let value = PrintStatus.int(dict["remain"])
        remain = (value ?? -1) >= 0 ? value : nil
    }
}

struct AMSUnit: Identifiable {
    let id: Int
    let humidity: Int?
    let temperature: Double?
    /// Minuti di essiccazione rimanenti (AMS 2 Pro, AMS HT).
    let dryingMinutes: Int
    /// Ugello a cui è collegata (stampanti a doppio ugello).
    let nozzle: String?
    let trays: [AMSTray]

    /// AMS HT: una sola bobina, id da 128 in su.
    var isSingleSlot: Bool { id >= 128 || trays.count == 1 }

    /// Lettera dell'unità come sul display: A, B, C… (AMS HT: HT-A, HT-B…).
    static func letter(_ unit: Int) -> String {
        let index = unit >= 128 ? unit - 128 : unit % 16
        return String(UnicodeScalar(UInt8(65 + min(max(index, 0), 25))))
    }

    static func slotLabel(unit: Int, slot: Int) -> String {
        unit >= 128 ? "HT-\(letter(unit))" : "\(letter(unit))\(slot + 1)"
    }

    /// Modello probabile se la stampante non l'ha (ancora) comunicato.
    func guessedModel(printer: String) -> String {
        if id >= 128 { return "AMS HT" }
        if trays.count > 4 { return "AMS 3H" }
        if printer.uppercased().hasPrefix("A") { return "AMS lite" }
        return "AMS"
    }
}

// MARK: - Avvisi HMS

/// Messaggio HMS (Health Management System) della stampante.
struct HMSAlert: Identifiable, Hashable {
    let attr: Int
    let code: Int

    var id: String { fullCode }

    var fullCode: String {
        String(format: "%04X_%04X_%04X_%04X", (attr >> 16) & 0xFFFF, attr & 0xFFFF, (code >> 16) & 0xFFFF, code & 0xFFFF)
    }

    private var moduleID: Int { (attr >> 24) & 0xFF }

    /// Modulo da cui arriva l'avviso.
    var module: String {
        switch moduleID {
        case 0x03: return "Movimento"
        case 0x05: return "Scheda madre"
        case 0x07: return "AMS"
        case 0x08: return "Testina"
        case 0x0C: return "Telecamera / AI"
        case 0x12: return "AMS lite"
        case 0x18: return "AMS HT"
        default: return "Stampante"
        }
    }

    var isAMS: Bool { [0x07, 0x12, 0x18].contains(moduleID) }

    /// AMS e slot coinvolti, se l'avviso riguarda una bobina.
    var amsDetail: String? {
        guard isAMS else { return nil }
        let unit = (attr >> 16) & 0xFF
        let slot = (attr >> 8) & 0xFF
        if moduleID == 0x18 { return "AMS HT \(AMSUnit.letter(128 + unit))" }
        let letter = AMSUnit.letter(unit)
        return slot < 4 ? "\(module) \(letter), slot \(slot + 1)" : "\(module) \(letter)"
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

    func wikiURL(model: String) -> URL? {
        URL(string: "https://wiki.bambulab.com/en/\(PrinterModels.wikiSection(model))/troubleshooting/hmscode/\(fullCode)")
    }
}

// MARK: - Modelli

/// Modelli noti, dai prefissi del numero di serie e dai codici interni.
enum PrinterModels {
    static func fromSerial(_ serial: String) -> String? {
        let prefixes: [String: String] = [
            "00M": "X1C", "00W": "X1", "03W": "X1E", "20P": "X2D",
            "01S": "P1P", "01P": "P1S", "22E": "P2S",
            "030": "A1 mini", "039": "A1", "26A": "A2L",
            "094": "H2D", "239": "H2D Pro", "093": "H2S", "31B": "H2C",
            "32X": "H3C",
            "35F": "R1",
        ]
        return prefixes[String(serial.uppercased().prefix(3))]
    }

    /// Codici usati da SSDP (DevModel) e da get_version (project_name).
    static func fromCode(_ code: String) -> String? {
        let codes: [String: String] = [
            "BL-P001": "X1C", "BL-P002": "X1", "C13": "X1E", "N6": "X2D",
            "C11": "P1P", "C12": "P1S", "N7": "P2S",
            "N1": "A1 mini", "N2S": "A1", "N9": "A2L",
            "O1D": "H2D", "O1E": "H2D Pro", "O1S": "H2S", "O1C": "H2C", "O1C2": "H2C",
            "N10": "H3C",
            "N8": "R1",
        ]
        let upper = code.uppercased()
        return codes[upper] ?? codes[upper.components(separatedBy: "-V").first ?? upper]
    }

    /// Nome commerciale da "product_name" (es. "Bambu Lab X1-Carbon" → "X1C").
    static func fromProductName(_ product: String) -> String? {
        var name = product.trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("Bambu Lab") else { return nil }
        name = String(name.dropFirst("Bambu Lab".count)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        switch name.lowercased() {
        case "x1-carbon", "x1 carbon": return "X1C"
        default: return name
        }
    }

    /// P1, A1 e A2 trasmettono JPEG sulla porta 6000; le altre RTSP sulla 322.
    static func usesJPEGCamera(_ model: String) -> Bool {
        let m = model.uppercased()
        return m.hasPrefix("P1") || m.hasPrefix("A1") || m.hasPrefix("A2")
    }

    /// Macchine senza sensore di temperatura in camera.
    static func lacksChamberSensor(_ model: String) -> Bool {
        usesJPEGCamera(model) || isLaserMachine(model)
    }

    /// Incisore/taglierina laser dedicata (Bambu Lab R1).
    static func isLaserMachine(_ model: String) -> Bool {
        model.uppercased().hasPrefix("R1")
    }

    /// Sezione del wiki Bambu Lab con le spiegazioni dei codici HMS.
    static func wikiSection(_ model: String) -> String {
        let m = model.uppercased()
        if m.hasPrefix("H") { return "h2" }
        if m.hasPrefix("P2") { return "p2s" }
        if m.hasPrefix("X2") { return "x2d" }
        if m == "A1 MINI" { return "a1-mini" }
        if m.hasPrefix("A") { return "a1" }
        return "x1"
    }
}
