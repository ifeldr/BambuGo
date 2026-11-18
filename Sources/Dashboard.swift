import SwiftUI
import AppKit

// MARK: - Palette

enum Palette {
    static let brandA = Color(red: 0.10, green: 0.74, blue: 0.56)   // verde acqua
    static let brandB = Color(red: 0.12, green: 0.55, blue: 0.86)   // azzurro
    static let heat = Color(red: 0.98, green: 0.47, blue: 0.20)
    static let brand = LinearGradient(colors: [brandA, brandB], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Colore di stato usato da badge, anello e pillola.
@MainActor
func stateColor(_ store: PrinterStore) -> Color {
    switch store.state {
    case .error: return .orange
    case .notConfigured, .connecting: return .gray
    case .connected:
        guard store.hasData else { return .gray }
        switch store.status.gcodeState {
        case "RUNNING", "PREPARE", "SLICING": return Palette.brandB
        case "PAUSE": return .yellow
        case "FINISH": return .green
        case "FAILED": return .red
        default: return Palette.brandA
        }
    }
}

// MARK: - Pannello principale

struct ContentView: View {
    @EnvironmentObject var store: PrinterStore
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(showSettings: $showSettings)

            if showSettings || !store.isConfigured {
                Card { SettingsView(onDone: { showSettings = false }) }
            } else {
                DashboardView()
            }

            FooterView()
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Intestazione

struct HeaderView: View {
    @EnvironmentObject var store: PrinterStore
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            PrinterBadge(color: stateColor(store), working: store.status.isActive && store.state == .connected)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ForEach(Array(subtitleParts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Text("·").foregroundStyle(.tertiary) }
                        Text(part)
                    }
                    if let signal = store.status.wifiSignal, store.state == .connected {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "wifi")
                            .font(.system(size: 9, weight: .semibold))
                            .help("Segnale Wi-Fi: \(signal) dBm")
                        Text(wifiQuality(signal))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if store.isConfigured {
                IconButton(systemName: showSettings ? "xmark" : "gearshape",
                           help: showSettings ? "Chiudi impostazioni" : "Impostazioni") {
                    withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
                }
            }
        }
    }

    private var subtitleParts: [String] {
        var parts: [String] = []
        if !store.model.isEmpty && store.model != store.displayName { parts.append(store.model) }
        if let tool = store.status.toolModule, store.state == .connected { parts.append(tool.name) }
        switch store.state {
        case .connected:
            parts.append(store.host)
        case .connecting:
            parts.append("Connessione…")
        case .error:
            parts.append("Disconnessa")
        case .notConfigured:
            parts.append("Configura la stampante")
        }
        return parts
    }

    private func wifiQuality(_ dBm: Int) -> String {
        switch dBm {
        case (-55)...: return "ottimo"
        case (-67)...: return "buono"
        case (-75)...: return "discreto"
        default: return "debole"
        }
    }
}

/// Riquadro con la stampante stilizzata; durante la stampa la testina si muove.
struct PrinterBadge: View {
    let color: Color
    let working: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    // telaio
                    RoundedRectangle(cornerRadius: w * 0.08, style: .continuous)
                        .stroke(Color.white, lineWidth: 1.6)
                        .frame(width: w * 0.62, height: h * 0.62)
                        .offset(x: w * 0.19, y: h * 0.19)
                    // asse X
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: w * 0.62, height: 1.4)
                        .offset(x: w * 0.19, y: h * 0.36)
                    // testina
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white)
                        .frame(width: w * 0.14, height: h * 0.11)
                        .offset(x: w * (phase ? 0.58 : 0.28), y: h * 0.32)
                    // oggetto in stampa
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: w * 0.2, height: h * 0.1)
                        .offset(x: w * 0.4, y: h * 0.6)
                    // piatto
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: w * 0.46, height: 1.6)
                        .offset(x: w * 0.27, y: h * 0.7)
                }
            }
        }
        .frame(width: 44, height: 44)
        .shadow(color: color.opacity(0.35), radius: 6, y: 2)
        .onAppear { updateAnimation() }
        .onChange(of: working) { _ in updateAnimation() }
    }

    private func updateAnimation() {
        if working {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = true }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { phase = false }
        }
    }
}

// MARK: - Corpo

struct DashboardView: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .error(let message) = store.state {
                Banner(text: message, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
            if let message = store.commandMessage {
                Banner(text: message, systemImage: "hand.raised.fill", color: .orange)
            }
            if !store.hasData {
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.state == .connecting ? "Connessione in corso…" : "In attesa di dati dalla stampante…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            } else {
                if store.status.printError != 0 || !store.status.hms.isEmpty {
                    ErrorsCard()
                }
                JobCard()
                CameraCard()
                if store.isLaserWork {
                    LaserCard()
                } else {
                    TemperatureRow()
                }
                if !store.status.amsUnits.isEmpty || store.status.externalSpools.contains(where: { !$0.isEmpty }) {
                    FilamentCard()
                }
            }
        }
    }
}

struct JobCard: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        let color = stateColor(store)
        Card {
            if s.isActive {
                HStack(spacing: 14) {
                    ProgressRing(value: Double(s.percent) / 100, color: color)
                        .frame(width: 74, height: 74)

                    VStack(alignment: .leading, spacing: 5) {
                        StatePill(text: store.stateName, color: color)
                        Text(s.taskName.isEmpty ? "Lavoro senza nome" : s.taskName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if s.totalLayers > 0 && store.workMode == .fdm {
                            Label("Strato \(s.layer) di \(s.totalLayers)", systemImage: "square.stack.3d.up")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if s.remainingMinutes > 0 {
                            Label {
                                Text("\(PrinterStore.formatMinutes(s.remainingMinutes)) · fine alle \(eta(s.remainingMinutes))")
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider().padding(.vertical, 2)
                PrintControls()
                if let speed = s.speedName, store.workMode == .fdm {
                    HStack {
                        Label("Velocità", systemImage: "gauge.medium")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(speed).fontWeight(.medium)
                    }
                    .font(.system(size: 11))
                }
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(color.opacity(0.15))
                        Image(systemName: idleIcon(s.gcodeState))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(idleTitle(s.gcodeState))
                            .font(.system(size: 13, weight: .semibold))
                        if !s.taskName.isEmpty {
                            Text("Ultimo lavoro: \(s.taskName)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func eta(_ minutes: Int) -> String {
        Date().addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)
    }

    private func idleIcon(_ state: String) -> String {
        switch state {
        case "FINISH": return "checkmark"
        case "FAILED": return "xmark"
        default: return "sparkles"
        }
    }

    private func idleTitle(_ state: String) -> String {
        let fdm = store.workMode == .fdm
        switch state {
        case "FINISH": return fdm ? "Stampa completata" : "Lavoro completato"
        case "FAILED": return fdm ? "Stampa non riuscita" : "Lavoro non riuscito"
        case "IDLE", "":
            switch store.workMode {
            case .fdm: return "Pronta per stampare"
            case .laser: return "Pronta per incidere"
            case .cut: return "Pronta per tagliare"
            }
        default: return store.stateName
        }
    }
}

struct ProgressRing: View {
    let value: Double
    let color: Color

    var body: some View {
        let clamped = min(max(value, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(clamped, 0.01))),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: clamped)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatePill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Controlli di stampa

struct PrintControls: View {
    @EnvironmentObject var store: PrinterStore
    @State private var confirmStop = false

    var body: some View {
        let paused = store.status.gcodeState == "PAUSE"
        let busy = store.pendingCommand != nil
        HStack(spacing: 8) {
            if confirmStop {
                Text(store.workMode == .fdm ? "Interrompere la stampa?" : "Interrompere il lavoro?")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                ControlButton(title: "No", systemImage: "arrow.uturn.backward", color: .gray) {
                    confirmStop = false
                }
                ControlButton(title: "Interrompi", systemImage: "stop.fill", color: .red, filled: true) {
                    confirmStop = false
                    store.stop()
                }
            } else {
                ControlButton(title: paused ? "Riprendi" : "Pausa",
                              systemImage: paused ? "play.fill" : "pause.fill",
                              color: paused ? .green : .yellow) {
                    paused ? store.resume() : store.pause()
                }
                ControlButton(title: "Interrompi", systemImage: "stop.fill", color: .red) {
                    withAnimation(.easeInOut(duration: 0.15)) { confirmStop = true }
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Invio…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(busy || store.state != .connected)
    }
}

struct ControlButton: View {
    let title: String
    let systemImage: String
    let color: Color
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    init(title: String, systemImage: String, color: Color, filled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? color : color.opacity(hovering ? 0.25 : 0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Errori

struct ErrorsCard: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        let printerAlerts = s.hms.filter { !$0.isAMS }
        let amsAlerts = s.hms.filter { $0.isAMS }
        Card {
            HStack {
                Label("Errori e avvisi", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                Spacer()
                Text("\(s.hms.count + (s.printError != 0 ? 1 : 0))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            }

            if s.printError != 0 {
                ErrorRow(title: printErrorTitle(s.printError),
                         detail: "Codice \(printErrorCode(s.printError))",
                         severity: "Stampa", color: .red,
                         url: URL(string: "https://wiki.bambulab.com/en/\(PrinterModels.wikiSection(store.model))/troubleshooting/hmscode/\(printErrorCode(s.printError))"))
            }

            if !printerAlerts.isEmpty {
                section("Stampante")
                ForEach(printerAlerts) { alert in
                    ErrorRow(title: alert.module, detail: alert.fullCode, severity: alert.severityName,
                             color: color(alert.severity), url: alert.wikiURL(model: store.model))
                }
            }

            if !amsAlerts.isEmpty {
                section("AMS")
                ForEach(amsAlerts) { alert in
                    ErrorRow(title: alert.amsDetail ?? alert.module, detail: alert.fullCode, severity: alert.severityName,
                             color: color(alert.severity), url: alert.wikiURL(model: store.model))
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func color(_ severity: Int) -> Color {
        switch severity {
        case 1, 2: return .red
        case 3: return .orange
        default: return .blue
        }
    }

    private func printErrorCode(_ code: Int) -> String {
        String(format: "%04X_%04X", (code >> 16) & 0xFFFF, code & 0xFFFF)
    }

    /// Descrizioni dei codici più comuni.
    private func printErrorTitle(_ code: Int) -> String {
        switch code {
        case 0x0300_400C: return "Stampa annullata"
        default:
            let module = (code >> 24) & 0xFF
            if [0x07, 0x12, 0x18].contains(module) && code & 0xFFFF == 0x8011 { return "Filamento esaurito" }
            if [0x07, 0x12, 0x18].contains(module) { return "Problema dell'AMS" }
            return store.workMode == .fdm ? "Errore di stampa" : "Errore del lavoro"
        }
    }
}

struct ErrorRow: View {
    let title: String
    let detail: String
    let severity: String
    let color: Color
    let url: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Text(severity)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Apri la spiegazione sul wiki Bambu Lab")
            }
        }
    }
}

// MARK: - Temperature

struct TemperatureRow: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        let compact = s.isDualNozzle && store.hasChamberSensor
        HStack(spacing: compact ? 6 : 8) {
            if s.isDualNozzle {
                ForEach(s.nozzles) { nozzle in
                    TempTile(title: "Ugello \(nozzle.sideLetter)", systemImage: "flame",
                             current: nozzle.current, target: nozzle.target,
                             highlighted: nozzle.id == s.activeExtruder && s.isActive, compact: compact)
                        .help("Ugello \(nozzle.sideName.lowercased())\(nozzle.id == s.activeExtruder ? " – in uso" : "")")
                }
            } else {
                TempTile(title: "Ugello", systemImage: "flame", current: s.nozzle, target: s.nozzleTarget)
            }
            TempTile(title: "Piatto", systemImage: "square.split.bottomrightquarter", current: s.bed, target: s.bedTarget,
                     compact: compact)
            if store.hasChamberSensor {
                TempTile(title: "Camera", systemImage: "thermometer", current: s.chamber, target: s.chamberTarget,
                         ambient: true, compact: compact)
            }
        }
    }
}

struct TempTile: View {
    let title: String
    let systemImage: String
    let current: Double?
    let target: Double?
    var ambient = false
    var highlighted = false
    var compact = false

    private var heating: Bool { (target ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(heating ? Palette.heat : Color.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if highlighted {
                    Circle().fill(Palette.brandB).frame(width: 5, height: 5)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(current.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("°C")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if heating, let target {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        let ratio = min(max((current ?? 0) / target, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [Color.yellow, Palette.heat],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(geo.size.width * ratio, 4))
                        }
                    }
                    .frame(height: 3)
                    Text(compact ? "→ \(Int(target.rounded()))°" : "obiettivo \(Int(target.rounded()))°")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text(ambient ? "ambiente" : "spento")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(height: 15, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 8 : 10)
        .background(CardBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.brandB.opacity(highlighted ? 0.6 : 0), lineWidth: 1)
        )
    }
}

// MARK: - Laser e taglio

/// Al posto delle temperature quando la macchina lavora con il laser o la lama.
struct LaserCard: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        let cut = store.workMode == .cut
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.14))
                    Image(systemName: s.toolModule?.systemImage ?? (cut ? "scissors" : "rays"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.red)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cut ? "Modalità taglio" : "Modalità laser")
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if store.hasChamberSensor, let chamber = s.chamber {
                    Label("\(Int(chamber.rounded()))°", systemImage: "thermometer")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .labelStyle(CompactLabelStyle())
                        .help("Temperatura in camera")
                }
            }
        }
    }

    private var subtitle: String {
        if let tool = store.status.toolModule { return "\(tool.name) montato" }
        if PrinterModels.isLaserMachine(store.model) { return "Incisore e taglierina laser" }
        return store.workMode == .cut ? "Modulo da taglio" : "Modulo laser"
    }
}

// MARK: - Filamenti (AMS)

struct FilamentCard: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        let multi = s.amsUnits.filter { !$0.isSingleSlot }
        let singles = s.amsUnits.filter { $0.isSingleSlot }
        let externals = s.externalSpools.filter { !$0.isEmpty }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(multi.enumerated()), id: \.element.id) { index, unit in
                    if index > 0 { Divider() }
                    AMSUnitView(unit: unit, title: title(unit, multiple: multi.count > 1))
                }

                if !singles.isEmpty {
                    if !multi.isEmpty { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(singles.count > 1 ? "\(store.amsModel(singles[0])) ×\(singles.count)" : store.amsModel(singles[0]))
                            .font(.system(size: 11, weight: .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 10) {
                            ForEach(singles) { unit in
                                if let tray = unit.trays.first {
                                    VStack(spacing: 3) {
                                        SpoolView(tray: tray)
                                        UnitClimate(unit: unit, compact: true)
                                    }
                                }
                            }
                        }
                    }
                }

                if !externals.isEmpty {
                    if !s.amsUnits.isEmpty { Divider() }
                    ForEach(externals) { ext in
                        HStack(spacing: 10) {
                            SpoolDisc(tray: ext, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(externalTitle(ext, dual: s.isDualNozzle))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(ext.type).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ext.active {
                                StatePill(text: "in uso", color: Palette.brandB)
                            } else if ext.loadedOn != nil {
                                StatePill(text: "caricata", color: .secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func title(_ unit: AMSUnit, multiple: Bool) -> String {
        let model = store.amsModel(unit)
        return multiple ? "\(model) · \(AMSUnit.letter(unit.id))" : model
    }

    private func externalTitle(_ tray: AMSTray, dual: Bool) -> String {
        guard dual else { return "Bobina esterna" }
        if tray.id == "ext-254" { return "Bobina esterna sinistra" }
        if tray.id == "ext-255" { return "Bobina esterna destra" }
        return "Bobina esterna"
    }
}

/// Un'unità AMS con più slot (AMS, AMS lite, AMS 2 Pro, AMS 3H).
struct AMSUnitView: View {
    let unit: AMSUnit
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let nozzle = unit.nozzle {
                    Text("→ \(nozzle)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .help("Ugello a cui è collegata l'unità")
                }
                Spacer(minLength: 4)
                UnitClimate(unit: unit, compact: false)
            }

            if unit.trays.count <= 4 {
                HStack(spacing: 0) {
                    ForEach(unit.trays) { tray in
                        SpoolView(tray: tray).frame(maxWidth: .infinity)
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 10) {
                    ForEach(unit.trays) { tray in SpoolView(tray: tray) }
                }
            }
        }
    }
}

/// Umidità, temperatura ed essiccazione di un'unità AMS.
struct UnitClimate: View {
    let unit: AMSUnit
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if unit.dryingMinutes > 0 {
                Label(compact ? "" : PrinterStore.formatMinutes(unit.dryingMinutes), systemImage: "wind")
                    .foregroundStyle(Palette.heat)
                    .help("Essiccazione in corso: \(PrinterStore.formatMinutes(unit.dryingMinutes)) rimanenti")
            }
            if let humidity = unit.humidity {
                Label("\(humidity)%", systemImage: "humidity")
                    .help("Umidità nell'AMS")
            }
            if !compact, let temp = unit.temperature, temp > 0 {
                Label("\(Int(temp.rounded()))°", systemImage: "thermometer")
            }
        }
        .font(.system(size: compact ? 9 : 10))
        .foregroundStyle(.secondary)
        .labelStyle(CompactLabelStyle())
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

struct SpoolView: View {
    let tray: AMSTray

    var body: some View {
        VStack(spacing: 5) {
            SpoolDisc(tray: tray, size: 34)
                .overlay(alignment: .topTrailing) {
                    if let side = tray.loadedOn {
                        Text(side)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(tray.active ? Palette.brandB : Color.gray))
                            .help(side == "S" ? "Caricata nell'ugello sinistro" : "Caricata nell'ugello destro")
                    }
                }
            Text(tray.isEmpty ? "Vuoto" : tray.type)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tray.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
            Text(remainText)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var remainText: String {
        if tray.isEmpty { return tray.label }
        if let remain = tray.remain { return "\(tray.label) · \(remain)%" }
        return tray.label
    }

    private var helpText: String {
        tray.isEmpty ? "Slot \(tray.label) vuoto" : "Slot \(tray.label): \(tray.type)\(tray.active ? " – in uso" : "")"
    }
}

/// Bobina vista dall'alto: anello colorato con il foro centrale.
struct SpoolDisc: View {
    let tray: AMSTray
    let size: CGFloat

    var body: some View {
        ZStack {
            if tray.isEmpty {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            } else {
                Circle().fill(Color(bambuHex: tray.colorHex) ?? Color.gray)
                Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.6))
                if let remain = tray.remain {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(remain, 0), 100)) / 100)
                        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(size * 0.22)
                        .blendMode(.overlay)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(3)
        .overlay(
            Circle()
                .strokeBorder(Palette.brandB, lineWidth: tray.active ? 2 : 0)
        )
    }
}

extension Color {
    /// Colore Bambu nel formato RRGGBBAA.
    init?(bambuHex: String) {
        let hex = bambuHex.trimmingCharacters(in: .whitespaces)
        guard hex.count >= 6, let value = UInt64(hex.prefix(6), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Piede

struct FooterView: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                BrowserWindowController.shared.show()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                    Text("Modelli online")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.brand))
            }
            .buttonStyle(.plain)
            .help("Esplora modelli pronti su MakerWorld, Printables e Thingiverse")

            Spacer(minLength: 4)

            if let date = store.lastUpdate {
                Text(date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help("Ultimo aggiornamento")
            }

            IconButton(systemName: "arrow.clockwise", help: "Aggiorna") { store.refresh() }
                .disabled(store.state != .connected)
            IconButton(systemName: "cup.and.saucer", help: "Offrimi un caffè su PayPal") {
                if let url = URL(string: "https://www.paypal.me/lorenzogarbi") {
                    NSWorkspace.shared.open(url)
                }
            }
            IconButton(systemName: "power", help: "Esci da BambuGo") { NSApp.terminate(nil) }
        }
        .padding(.top, 2)
    }
}

// MARK: - Componenti comuni

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(CardBackground())
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12))
        )
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5))
        .onHover { hovering = $0 }
        .help(help)
    }
}
