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
        let icon = Image(nsImage: MenuBarIcon.image(for: store))
        let title = store.menuTitle
        if title.isEmpty {
            icon
        } else {
            Text("\(icon) \(title)")
                .monospacedDigit()
        }
    }
}

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject var store: PrinterStore
    var onDone: () -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var serial = ""
    @State private var code = ""
    @State private var model = ""
    @State private var loaded = false
    @State private var searching = false
    @State private var found: [DiscoveredPrinter] = []
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stampante in rete locale").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    Task {
                        searching = true
                        found = await PrinterDiscovery.search()
                        searching = false
                        searched = true
                        if found.count == 1, let only = found.first { use(only) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if searching { ProgressView().controlSize(.mini) } else { Image(systemName: "dot.radiowaves.left.and.right") }
                        Text(searching ? "Ricerca…" : "Cerca in rete")
                    }
                }
                .controlSize(.small)
                .disabled(searching)
            }

            if !found.isEmpty {
                VStack(spacing: 4) {
                    ForEach(found) { printer in
                        Button { use(printer) } label: {
                            HStack {
                                Image(systemName: printer.id == serial ? "checkmark.circle.fill" : "printer")
                                    .foregroundStyle(printer.id == serial ? Palette.brandA : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(printer.name).font(.system(size: 11, weight: .medium))
                                    Text("\(printer.model) · \(printer.host)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if searched && !searching {
                Text("Nessuna stampante trovata: inserisci i dati a mano. Il Mac deve essere sulla stessa rete e avere il permesso Rete locale.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeled("Nome (facoltativo)") { TextField(model.isEmpty ? "es. Stampante officina" : model, text: $name) }
            labeled("Indirizzo IP") { TextField("192.168.1.50", text: $host) }
            labeled("Numero di serie") { TextField("es. 01S00A123456789", text: $serial) }
            labeled("Access code") { SecureField("8 caratteri", text: $code) }

            Text("IP e access code sono sul display della stampante (Impostazioni → Rete/WLAN). Per pausa, interruzione e luce, con i firmware recenti attiva anche la modalità LAN e la modalità sviluppatore.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if store.isConfigured {
                    Button("Annulla") { onDone() }
                }
                Button("Salva e connetti") {
                    store.save(host: host, serial: serial, accessCode: code, name: name, model: model)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || serial.trimmingCharacters(in: .whitespaces).isEmpty
                          || code.trimmingCharacters(in: .whitespaces).isEmpty)
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

            Text("BambuGo è un progetto indipendente, non affiliato a Bambu Lab. Comunica solo con la stampante nella tua rete; usalo a tuo rischio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .onAppear {
            guard !loaded else { return }
            name = store.customName
            host = store.host
            serial = store.serial
            code = store.accessCode
            model = store.model
            loaded = true
        }
    }

    private func use(_ printer: DiscoveredPrinter) {
        host = printer.host
        serial = printer.id
        model = printer.model
        if name.isEmpty || found.contains(where: { $0.name == name }) { name = printer.name }
    }
}

private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        content()
    }
}
