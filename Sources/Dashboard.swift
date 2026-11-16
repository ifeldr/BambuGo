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
        switch store.state {
        case .connected:
            parts.append(store.mode == .cloud ? "Cloud" : "LAN")
        case .connecting:
            parts.append("Connessione…")
        case .error:
            parts.append("Disconnessa")
        case .notConfigured:
            parts.append(store.mode == .lan ? "Configura la rete locale"
                         : (store.isLoggedIn ? "Scegli una stampante" : "Accedi a Bambu Lab"))
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
            if store.status.printError != 0 {
                Banner(text: "Errore stampante \(String(store.status.printError, radix: 16, uppercase: true))",
                       systemImage: "exclamationmark.octagon.fill", color: .red)
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
                JobCard()
                TemperatureRow()
                if !store.status.amsUnits.isEmpty || store.status.externalSpool.map({ !$0.isEmpty }) == true {
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
                        StatePill(text: s.stateName, color: color)
                        Text(s.taskName.isEmpty ? "Lavoro senza nome" : s.taskName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if s.totalLayers > 0 {
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
                if let speed = s.speedName {
                    Divider().padding(.vertical, 2)
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
        switch state {
        case "FINISH": return "Stampa completata"
        case "FAILED": return "Stampa non riuscita"
        case "IDLE", "": return "Pronta per stampare"
        default: return store.status.stateName
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

// MARK: - Temperature

struct TemperatureRow: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        HStack(spacing: 8) {
            TempTile(title: "Ugello", systemImage: "flame", current: s.nozzle, target: s.nozzleTarget)
            TempTile(title: "Piatto", systemImage: "square.split.bottomrightquarter", current: s.bed, target: s.bedTarget)
            if store.hasChamberSensor {
                TempTile(title: "Camera", systemImage: "thermometer", current: s.chamber, target: nil, ambient: true)
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
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(current.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
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
                    Text("obiettivo \(Int(target.rounded()))°")
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
        .padding(10)
        .background(CardBackground())
    }
}

// MARK: - Filamenti (AMS)

struct FilamentCard: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        Card {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.amsUnits) { unit in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(s.amsUnits.count > 1 ? "AMS \(String(UnicodeScalar(UInt8(65 + min(max(unit.id, 0), 25)))))" : "AMS")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            if let humidity = unit.humidity {
                                Label("\(humidity)%", systemImage: "humidity")
                                    .help("Umidità nell'AMS")
                            }
                            if let temp = unit.temperature, temp > 0 {
                                Label("\(Int(temp.rounded()))°", systemImage: "thermometer")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .labelStyle(CompactLabelStyle())

                        HStack(spacing: 0) {
                            ForEach(unit.trays) { tray in
                                SpoolView(tray: tray).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                if let ext = s.externalSpool, !ext.isEmpty {
                    if !s.amsUnits.isEmpty { Divider() }
                    HStack(spacing: 10) {
                        SpoolDisc(tray: ext, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bobina esterna").font(.system(size: 11, weight: .semibold))
                            Text(ext.type).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ext.active { StatePill(text: "in uso", color: Palette.brandB) }
                    }
                }
            }
        }
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
            Text(tray.isEmpty ? "Vuoto" : tray.type)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tray.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
            Text(remainText)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
