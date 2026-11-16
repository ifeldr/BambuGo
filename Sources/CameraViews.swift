import SwiftUI
import AppKit

/// Flusso condiviso tra pannello e finestra: resta attivo finché qualcuno lo guarda.
@MainActor
final class CameraFeed: ObservableObject {
    static let shared = CameraFeed()

    @Published private(set) var image: NSImage?
    @Published private(set) var error: String?
    @Published private(set) var lastFrame: Date?

    private var client: CameraStream?
    private var key = ""
    private var viewers = 0
    private var host = ""
    private var accessCode = ""
    private var useRTSP = false
    private var gotFrame = false

    func attach(host: String, accessCode: String, preferRTSP: Bool) {
        viewers += 1
        let newKey = host + "|" + accessCode
        guard client == nil || newKey != key else { return }
        if newKey != key {
            image = nil
            gotFrame = false
            useRTSP = preferRTSP
        }
        key = newKey
        self.host = host
        self.accessCode = accessCode
        startClient()
    }

    private func startClient() {
        client?.stop()
        error = nil
        let camera: CameraStream
        if useRTSP {
            camera = RTSPCameraClient(host: host, accessCode: accessCode)
        } else {
            camera = CameraClient(host: host, accessCode: accessCode)
        }
        camera.onFrame = { [weak self, weak camera] frame in
            Task { @MainActor in
                guard let self, let camera, self.client === camera else { return }
                self.image = frame
                self.lastFrame = Date()
                self.error = nil
                self.gotFrame = true
            }
        }
        camera.onError = { [weak self, weak camera] message in
            Task { @MainActor in
                guard let self, let camera, self.client === camera else { return }
                self.error = message
                // Mai visto un'immagine: forse il modello usa l'altro protocollo.
                if !self.gotFrame && self.viewers > 0 {
                    camera.stop()
                    self.useRTSP.toggle()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard self.client === camera, self.viewers > 0 else { return }
                    self.startClient()
                }
            }
        }
        client = camera
        camera.start()
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        // Piccolo ritardo: chiudere e riaprire il pannello non riavvia la connessione.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.viewers == 0 {
                self.client?.stop()
                self.client = nil
            }
        }
    }
}

/// Anteprima della telecamera con controllo luce e apertura in finestra.
struct CameraView: View {
    @EnvironmentObject var store: PrinterStore
    @ObservedObject private var feed: CameraFeed
    let host: String
    let accessCode: String
    let preferRTSP: Bool
    let showsWindowButton: Bool

    init(host: String, accessCode: String, preferRTSP: Bool, showsWindowButton: Bool = true) {
        self.host = host
        self.accessCode = accessCode
        self.preferRTSP = preferRTSP
        self.showsWindowButton = showsWindowButton
        _feed = ObservedObject(wrappedValue: CameraFeed.shared)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))

            if let image = feed.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let error = feed.error {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash").font(.system(size: 18))
                    Text(error)
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(12)
            } else {
                ProgressView().controlSize(.small).colorScheme(.dark)
            }

            VStack {
                HStack(spacing: 6) {
                    if feed.image != nil && feed.error == nil {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 5, height: 5)
                            Text("LIVE").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                    Spacer()
                    if let light = store.status.lightOn {
                        OverlayButton(systemName: light ? "lightbulb.fill" : "lightbulb",
                                      help: light ? "Spegni la luce" : "Accendi la luce",
                                      tint: light ? .yellow : .white) {
                            store.setLight(!light)
                        }
                    }
                    if showsWindowButton {
                        OverlayButton(systemName: "arrow.up.left.and.arrow.down.right",
                                      help: "Apri in una finestra", tint: .white) {
                            CameraWindowController.shared.show(store: store, host: host, accessCode: accessCode, preferRTSP: preferRTSP)
                        }
                    }
                }
                Spacer()
            }
            .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { feed.attach(host: host, accessCode: accessCode, preferRTSP: preferRTSP) }
        .onDisappear { feed.detach() }
    }
}

struct OverlayButton: View {
    let systemName: String
    let help: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Scheda della telecamera nel pannello.
struct CameraCard: View {
    @EnvironmentObject var store: PrinterStore
    @AppStorage("showCamera") private var expanded = true

    var body: some View {
        Card {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Telecamera", systemImage: "video")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let endpoint = store.cameraEndpoint {
                    CameraView(host: endpoint.host, accessCode: endpoint.accessCode, preferRTSP: store.cameraUsesRTSP)
                        .frame(height: 176)
                } else {
                    note("Configura IP e access code della rete locale per vedere il video.")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Finestra separata

final class CameraWindowController {
    static let shared = CameraWindowController()
    private var window: NSPanel?

    @MainActor
    func show(store: PrinterStore, host: String, accessCode: String, preferRTSP: Bool) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = CameraView(host: host, accessCode: accessCode, preferRTSP: preferRTSP, showsWindowButton: false)
            .environmentObject(store)
            .padding(6)
            .frame(minWidth: 320, minHeight: 180)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 372),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "\(store.displayName) – Telecamera"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            panel.contentView = nil   // chiude il flusso
            self?.window = nil
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
