import SwiftUI
import AppKit

@main
struct BambuGoApp: App {
    @StateObject private var store = PrinterStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: PrinterStore

    var body: some View {
        let title = store.menuTitle
        if title.isEmpty {
            Image(systemName: store.menuIcon)
        } else {
            Text("\(Image(systemName: store.menuIcon)) \(title)")
                .monospacedDigit()
        }
    }
}

// MARK: - Pannello

struct ContentView: View {
    @EnvironmentObject var store: PrinterStore
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if showSettings || !store.isConfigured {
                SettingsView(onDone: { showSettings = false })
            } else {
                StatusView()
            }
            Divider()
            toolsRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.menuIcon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName).font(.headline).lineLimit(1)
                Text(store.stateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isConfigured {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: showSettings ? "xmark.circle" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Impostazioni")
            }
        }
    }

    private var iconColor: Color {
        switch store.state {
        case .error: return .orange
        case .connected:
            switch store.status.gcodeState {
            case "RUNNING", "PREPARE": return .blue
            case "PAUSE": return .yellow
            case "FINISH": return .green
            case "FAILED": return .red
            default: return .primary
            }
        default: return .secondary
        }
    }

    private var toolsRow: some View {
        HStack(spacing: 6) {
            Button {
                BrowserWindowController.shared.show()
            } label: {
                Label("Modelli", systemImage: "globe")
            }
            .help("Esplora modelli pronti su MakerWorld, Printables e Thingiverse")

            Button {
                Slicers.chooseAndOpenFile()
            } label: {
                Label("Apri file…", systemImage: "doc")
            }
            .help("Apri un file STL/3MF nello slicer")

            Button {
                Slicers.openSlicer()
            } label: {
                Label("Slicer", systemImage: "square.stack.3d.up")
            }
            .help(Slicers.preferred().map { "Apri \($0.name)" } ?? "Nessuno slicer trovato")
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let date = store.lastUpdate {
                Text("Aggiornato alle \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Aggiorna") { store.refresh() }
                .disabled(store.state != .connected)
            Button {
                if let url = URL(string: "https://www.paypal.me/lorenzogarbi") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("☕")
            }
            .help("Offrimi un caffè su PayPal")
            Button("Esci") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

struct StatusView: View {
    @EnvironmentObject var store: PrinterStore

    var body: some View {
        let s = store.status
        VStack(alignment: .leading, spacing: 8) {
            if case .error(let message) = store.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if !store.hasData {
                if store.state == .connecting || store.state == .connected {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("In attesa di dati dalla stampante…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if !s.taskName.isEmpty {
                    Text(s.taskName)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                }

                if s.isActive || s.gcodeState == "FINISH" {
                    ProgressView(value: Double(min(max(s.percent, 0), 100)), total: 100)
                    HStack {
                        Text("\(s.percent)%").monospacedDigit()
                        Spacer()
                        if s.totalLayers > 0 {
                            Text("Strato \(s.layer)/\(s.totalLayers)").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if s.isActive && s.remainingMinutes > 0 {
                    InfoRow("Tempo rimanente", PrinterStore.formatMinutes(s.remainingMinutes))
                    InfoRow("Fine prevista", Date().addingTimeInterval(Double(s.remainingMinutes) * 60)
                        .formatted(date: .omitted, time: .shortened))
                }

                InfoRow("Ugello", temperature(s.nozzle, s.nozzleTarget))
                InfoRow("Piatto", temperature(s.bed, s.bedTarget))
                if let chamber = s.chamber, chamber > 0 {
                    InfoRow("Camera", temperature(chamber, nil))
                }
                if s.isActive, let speed = s.speedName {
                    InfoRow("Velocità", speed)
                }
                if s.printError != 0 {
                    InfoRow("Codice errore", String(s.printError, radix: 16, uppercase: true))
                }
            }
        }
    }

    private func temperature(_ current: Double?, _ target: Double?) -> String {
        guard let current else { return "–" }
        var text = "\(Int(current.rounded()))°C"
        if let target, target > 0 { text += " → \(Int(target.rounded()))°C" }
        return text
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Impostazioni / account

struct SettingsView: View {
    @EnvironmentObject var store: PrinterStore
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connessione", selection: Binding(
                get: { store.mode },
                set: { store.setMode($0) }
            )) {
                ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch store.mode {
            case .cloud:
                if store.isLoggedIn {
                    AccountView(onDone: onDone)
                } else if store.loginStep == .credentials {
                    LoginView()
                } else {
                    CodeView()
                }
            case .lan:
                LANSettingsView(onDone: onDone)
            }

            if let error = store.loginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Notifiche (fine, errore, pausa)", isOn: Binding(
                get: { store.notificationsEnabled },
                set: { store.setNotifications($0) }
            ))
            Toggle("Avvia al login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            if let error = store.loginItemError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            SlicerPicker()
        }
        .textFieldStyle(.roundedBorder)
        .disabled(store.busy)
    }
}

struct LANSettingsView: View {
    @EnvironmentObject var store: PrinterStore
    var onDone: () -> Void

    @State private var host = ""
    @State private var serial = ""
    @State private var code = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stampante in rete locale").font(.subheadline.weight(.semibold))
            labeled("Indirizzo IP") { TextField("192.168.1.50", text: $host) }
            labeled("Numero di serie") { TextField("es. 01P00A123456789", text: $serial) }
            labeled("Access code") { SecureField("8 caratteri", text: $code) }

            Text("Access code e IP sono sul display della stampante in Impostazioni → Rete/WLAN. Il Mac deve raggiungere la stampante (stessa rete o VPN).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let device = store.cloudDeviceForLAN {
                    Button("Compila dal cloud") {
                        serial = device.id
                        if !device.accessCode.isEmpty { code = device.accessCode }
                    }
                    .help("Usa seriale e access code di \(device.name) dall'account Bambu Lab")
                }
                Spacer()
                if store.isLANConfigured {
                    Button("Annulla") { onDone() }
                }
                Button("Salva e connetti") {
                    store.saveLAN(host: host, serial: serial, accessCode: code)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || serial.trimmingCharacters(in: .whitespaces).isEmpty
                          || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            host = store.lanHost
            serial = store.lanSerial
            code = store.lanAccessCode
            loaded = true
        }
    }
}

private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        content()
    }
}

struct LoginView: View {
    @EnvironmentObject var store: PrinterStore
    @State private var email = ""
    @State private var password = ""
    @State private var region: CloudRegion = .global

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accedi a Bambu Lab").font(.subheadline.weight(.semibold))
            labeled("Email") { TextField("nome@esempio.it", text: $email) }
            labeled("Password") { SecureField("Password", text: $password) }
            Picker("Server", selection: $region) {
                ForEach(CloudRegion.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("La password non viene salvata: serve solo per ottenere il token di accesso, conservato nel Portachiavi.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Accedi") {
                    let pwd = password
                    Task {
                        await store.login(email: email, password: pwd, region: region)
                        password = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .onAppear {
            if email.isEmpty { email = store.email }
            region = store.region
        }
    }
}

struct CodeView: View {
    @EnvironmentObject var store: PrinterStore
    @State private var code = ""

    private var isTFA: Bool {
        if case .tfa = store.loginStep { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isTFA ? "Verifica in due passaggi" : "Codice di verifica")
                .font(.subheadline.weight(.semibold))
            Text(isTFA ? "Inserisci il codice della tua app di autenticazione."
                       : "Bambu Lab ha inviato un codice a 6 cifre a \(store.email).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("123456", text: $code)

            HStack {
                Button("Indietro") { store.cancelLogin() }
                if !isTFA {
                    Button("Invia di nuovo") { Task { await store.resendCode() } }
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Conferma") {
                    let value = code
                    Task { await store.submitCode(value) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
            }
        }
    }
}

struct AccountView: View {
    @EnvironmentObject var store: PrinterStore
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account Bambu Lab").font(.subheadline.weight(.semibold))
                    Text(store.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Disconnetti") { store.logout() }
                    .controlSize(.small)
            }

            labeled("Stampante") {
                HStack {
                    Picker("Stampante", selection: Binding(
                        get: { store.serial },
                        set: { serial in
                            if let device = store.devices.first(where: { $0.id == serial }) {
                                store.select(device)
                            }
                        }
                    )) {
                        if store.serial.isEmpty { Text("Scegli…").tag("") }
                        ForEach(store.devices) { device in
                            Text(deviceLabel(device)).tag(device.id)
                        }
                        if !store.serial.isEmpty && !store.devices.contains(where: { $0.id == store.serial }) {
                            Text(store.displayName).tag(store.serial)
                        }
                    }
                    .labelsHidden()

                    Button {
                        Task { await store.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Aggiorna elenco stampanti")
                }
            }

            HStack {
                Spacer()
                Button("Fatto") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.isCloudConfigured)
            }
        }
        .task { if store.devices.isEmpty { await store.refreshDevices(silent: true) } }
    }

    private func deviceLabel(_ device: CloudDevice) -> String {
        let dot = device.online ? "🟢" : "⚪️"
        let model = device.model.isEmpty ? "" : " (" + device.model + ")"
        return dot + " " + device.name + model
    }
}

struct SlicerPicker: View {
    @AppStorage(Slicers.preferenceKey) private var preferred = ""
    @State private var slicers: [SlicerApp] = []

    var body: some View {
        HStack {
            Text("Slicer")
            Spacer()
            if slicers.isEmpty {
                Text("nessuno installato").foregroundStyle(.secondary)
            } else {
                Picker("Slicer", selection: $preferred) {
                    Text("Automatico").tag("")
                    ForEach(slicers) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear { slicers = Slicers.installed() }
    }
}
