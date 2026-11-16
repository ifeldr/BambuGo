import AppKit
import Combine
import SwiftUI
import WebKit

/// Siti di modelli pronti da stampare.
enum ModelSite: String, CaseIterable, Identifiable {
    case makerworld, printables, thingiverse

    var id: String { rawValue }

    var name: String {
        switch self {
        case .makerworld: return "MakerWorld"
        case .printables: return "Printables"
        case .thingiverse: return "Thingiverse"
        }
    }

    var url: URL {
        switch self {
        case .makerworld: return URL(string: "https://makerworld.com/it")!
        case .printables: return URL(string: "https://www.printables.com/")!
        case .thingiverse: return URL(string: "https://www.thingiverse.com/")!
        }
    }

    static func matching(_ url: URL?) -> ModelSite? {
        guard let host = url?.host?.lowercased() else { return nil }
        return allCases.first { host.contains($0.rawValue) }
    }
}

// MARK: - Finestra

final class BrowserWindowController {
    static let shared = BrowserWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ModelBrowserView())
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "BambuGo – Modelli online"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 1200, height: 820))
            newWindow.isReleasedWhenClosed = false
            newWindow.setFrameAutosaveName("BambuGoModelBrowser")
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Modello del browser

final class WebBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var site: ModelSite = .makerworld
    @Published var downloadedFile: URL?
    @Published var downloadMessage: String?

    private var destinations: [ObjectIdentifier: URL] = [:]
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // resta loggato tra un'apertura e l'altra
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoBack = $0 }.store(in: &cancellables)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoForward = $0 }.store(in: &cancellables)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main)
            .sink { [weak self] in self?.isLoading = $0 }.store(in: &cancellables)
        webView.publisher(for: \.url).receive(on: RunLoop.main)
            .sink { [weak self] url in
                if let found = ModelSite.matching(url) { self?.site = found }
            }.store(in: &cancellables)

        open(.makerworld)
    }

    func open(_ site: ModelSite) {
        self.site = site
        webView.load(URLRequest(url: site.url))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        // Link tipo "Apri in Bambu Studio" (bambustudioopen://, orcasliceropen://…): li passa a macOS.
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKUIDelegate

    /// Link che aprono una nuova finestra: li carichiamo nella stessa.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = Self.uniqueURL(in: folder, name: suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        downloadedFile = nil
        downloadMessage = "Scaricamento di \(destination.lastPathComponent)…"
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        downloadedFile = file
        downloadMessage = "Scaricato: \(file.lastPathComponent)"
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        downloadedFile = nil
        downloadMessage = "Download non riuscito: \(error.localizedDescription)"
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Vista

struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ModelBrowserView: View {
    @StateObject private var browser = WebBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebView(webView: browser.webView)
            if let message = browser.downloadMessage {
                Divider()
                downloadBar(message)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
                .help("Indietro")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
                .help("Avanti")
            Button {
                if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
            } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(browser.isLoading ? "Interrompi" : "Ricarica")

            Picker("Sito", selection: Binding(
                get: { browser.site },
                set: { browser.open($0) }
            )) {
                ForEach(ModelSite.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            if browser.isLoading { ProgressView().controlSize(.small) }

            Spacer()

            Button {
                if let url = browser.webView.url { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "safari")
            }
            .help("Apri nel browser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func downloadBar(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: browser.downloadedFile == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                .foregroundStyle(browser.downloadedFile == nil ? Color.secondary : Color.green)
            Text(message).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let file = browser.downloadedFile {
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .keyboardShortcut(.defaultAction)
            }
            Button {
                browser.downloadMessage = nil
                browser.downloadedFile = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
