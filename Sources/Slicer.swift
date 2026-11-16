import AppKit
import UniformTypeIdentifiers

/// Uno slicer installato sul Mac.
struct SlicerApp: Identifiable, Hashable {
    let id: String      // identificativo stabile (usato nelle preferenze)
    let name: String
    let url: URL
}

/// Trova gli slicer installati e apre file/app con quello preferito.
enum Slicers {
    private struct Candidate {
        let id: String
        let name: String
        let bundleIDs: [String]
        let appNames: [String]
    }

    private static let candidates: [Candidate] = [
        Candidate(id: "bambustudio", name: "Bambu Studio",
                  bundleIDs: ["com.bambulab.bambu-studio"],
                  appNames: ["BambuStudio.app", "Bambu Studio.app"]),
        Candidate(id: "orcaslicer", name: "OrcaSlicer",
                  bundleIDs: ["com.softfever3d.orca-slicer"],
                  appNames: ["OrcaSlicer.app"]),
        Candidate(id: "prusaslicer", name: "PrusaSlicer",
                  bundleIDs: ["com.prusa3d.slic3r"],
                  appNames: ["PrusaSlicer.app"]),
        Candidate(id: "cura", name: "UltiMaker Cura",
                  bundleIDs: ["nl.ultimaker.cura"],
                  appNames: ["UltiMaker Cura.app", "Ultimaker Cura.app"]),
    ]

    static let preferenceKey = "preferredSlicer"

    /// Estensioni dei file che gli slicer sanno aprire.
    static let fileExtensions = ["3mf", "stl", "step", "stp", "obj", "amf", "gcode"]

    static func installed() -> [SlicerApp] {
        let fm = FileManager.default
        let folders = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        return candidates.compactMap { candidate in
            for bundleID in candidate.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return SlicerApp(id: candidate.id, name: candidate.name, url: url)
                }
            }
            for folder in folders {
                for appName in candidate.appNames {
                    let path = (folder as NSString).appendingPathComponent(appName)
                    if fm.fileExists(atPath: path) {
                        return SlicerApp(id: candidate.id, name: candidate.name, url: URL(fileURLWithPath: path))
                    }
                }
            }
            return nil
        }
    }

    /// Slicer preferito (dalle impostazioni) oppure il primo trovato.
    static func preferred() -> SlicerApp? {
        let all = installed()
        let wanted = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        return all.first(where: { $0.id == wanted }) ?? all.first
    }

    static func openSlicer() {
        guard let slicer = preferred() else { showMissingAlert(); return }
        NSWorkspace.shared.openApplication(at: slicer.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func open(_ files: [URL]) {
        guard !files.isEmpty else { return }
        guard let slicer = preferred() else { showMissingAlert(); return }
        NSWorkspace.shared.open(files, withApplicationAt: slicer.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Chiede un file 3D e lo apre nello slicer.
    static func chooseAndOpenFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Apri un modello nello slicer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK else { return }
            open(panel.urls)
        }
    }

    private static func showMissingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nessuno slicer trovato"
        alert.informativeText = "Installa Bambu Studio (o OrcaSlicer) nella cartella Applicazioni per aprire i modelli."
        alert.addButton(withTitle: "Scarica Bambu Studio")
        alert.addButton(withTitle: "Annulla")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://bambulab.com/it/download/studio") {
            NSWorkspace.shared.open(url)
        }
    }
}
