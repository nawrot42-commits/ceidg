import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// Strona startowa wyszukiwarki CEIDG.
let searchURL = URL(string: "https://aplikacja.ceidg.gov.pl/ceidg/ceidg.public.ui/search.aspx")!

// MARK: - Walidacja NIP

enum NIP {
    static func normalize(_ s: String) -> String { s.filter(\.isNumber) }

    static func isValid(_ nip: String) -> Bool {
        let d = nip.compactMap { $0.wholeNumberValue }
        guard d.count == 10 else { return false }
        let w = [6, 5, 7, 2, 3, 4, 5, 6, 7]
        return zip(d, w).map { $0 * $1 }.reduce(0, +) % 11 == d[9]
    }
}

// MARK: - Skrypty JS sterujące stroną
// Selektory są celowo „heurystyczne” (po id/name/tekście), żeby działały
// zarówno na starej wyszukiwarce ASP.NET, jak i po drobnych zmianach strony.

enum JS {
    static let helpers = """
    function visible(e){ return !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length)); }
    function txt(e){ return ((e.innerText||'') + ' ' + (e.value||'') + ' ' + (e.title||'') + ' ' + (e.id||'') + ' ' + (e.getAttribute('aria-label')||'')).toLowerCase(); }
    function findPrint(){
      var els = Array.from(document.querySelectorAll('a,button,input[type=submit],input[type=button],input[type=image]')).filter(visible);
      return els.find(function(e){ return /wydruk|drukuj|pobierz pdf|zapisz pdf|printpdf|print/.test(txt(e)) && !/instrukc|regulamin|pomoc/.test(txt(e)); });
    }
    function findDetails(){
      var sel = 'a[href*="SearchDetails" i], a[href*="details" i], a[href*="/wpis/" i], a[id*="hlkName" i]';
      return Array.from(document.querySelectorAll(sel)).filter(visible)[0];
    }
    """

    /// Wpisuje NIP i klika „Szukaj”.
    static func search(nip: String) -> String {
        helpers + """
        (function(){
          var input = Array.from(document.querySelectorAll('input[id*="nip" i], input[name*="nip" i], input[placeholder*="NIP"]')).filter(visible)[0];
          if (!input) return 'wait';
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          setter.call(input, '\(nip)');
          ['input','change','keyup'].forEach(function(t){ input.dispatchEvent(new Event(t, {bubbles:true})); });
          var btns = Array.from(document.querySelectorAll('button,input[type=submit],input[type=button],a')).filter(visible);
          var btn = btns.find(function(e){ return /btninputsearch/.test((e.id||'').toLowerCase()); })
                 || btns.find(function(e){ return /^\\s*(szukaj|wyszukaj)\\s*$/.test((e.innerText||e.value||'').toLowerCase()); })
                 || btns.find(function(e){ return /szukaj|search/.test(txt(e)); });
          if (btn) { btn.click(); return 'ok'; }
          if (input.form) { input.form.submit(); return 'ok'; }
          return 'nobutton';
        })();
        """
    }

    /// Na liście wyników otwiera pierwszy wpis (albo zgłasza, że już jesteśmy na szczegółach).
    static let results = helpers + """
    (function(){
      var d = findDetails();
      if (d) { d.removeAttribute('target'); d.click(); return 'clicked'; }
      if (findPrint()) return 'details';
      if (/nie znaleziono|brak wynik|0 wynik/.test(document.body.innerText.toLowerCase())) return 'notfound';
      return 'wait';
    })();
    """

    /// Na stronie wpisu klika przycisk wydruku PDF.
    static let clickPrint = helpers + """
    (function(){
      var p = findPrint();
      if (!p) return 'wait';
      if (p.tagName === 'A') p.removeAttribute('target');
      p.click();
      return 'ok';
    })();
    """
}

// MARK: - Sterownik przeglądarki

@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    enum Step { case idle, search, results, details, waitingPDF, done }

    let webView: WKWebView
    @Published var status = "Wpisz NIP i kliknij „Pobierz wydruk”."
    @Published var busy = false

    private var step: Step = .idle
    private var nip = ""
    private var loop: Task<Void, Never>?
    private var savedURL: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: searchURL))
    }

    func start(nip: String) {
        self.nip = nip
        loop?.cancel()
        step = .search
        busy = true
        status = "Otwieram wyszukiwarkę CEIDG…"
        webView.load(URLRequest(url: searchURL))
        loop = Task { await run() }
    }

    func stop(_ message: String) {
        loop?.cancel()
        step = .done
        busy = false
        status = message
    }

    /// Co sekundę sprawdza stronę i wykonuje kolejny krok (działa też dla stron JS bez przeładowań).
    private func run() async {
        var waited = 0
        while !Task.isCancelled, waited < 60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
            if webView.isLoading { continue }

            switch step {
            case .search:
                let r = await eval(JS.search(nip: nip))
                if r == "ok" { step = .results; waited = 0; status = "Szukam NIP \(nip)…" }
            case .results:
                switch await eval(JS.results) {
                case "clicked": step = .details; waited = 0; status = "Otwieram wpis…"
                case "details": step = .details
                case "notfound": stop("Nie znaleziono firmy o NIP \(nip)."); return
                default: break
                }
            case .details:
                if await eval(JS.clickPrint) == "ok" {
                    step = .waitingPDF; waited = 0; status = "Pobieram wydruk PDF…"
                }
            case .waitingPDF, .done, .idle:
                break
            }
        }
        if !Task.isCancelled, step != .done {
            stop("Automat nie dokończył (krok: \(step)). Dokończ ręcznie w oknie – pobrany PDF zostanie zapisany – albo użyj „Zapisz stronę jako PDF”.")
        }
    }

    private func eval(_ js: String) async -> String? {
        try? await webView.evaluateJavaScript(js) as? String
    }

    // MARK: Pobieranie plików

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let mime = response.response.mimeType?.lowercased() ?? ""
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if mime.contains("pdf") || disposition.contains("attachment") || !response.canShowMIMEType {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let ext = (suggestedFilename as NSString).pathExtension.isEmpty ? "pdf" : (suggestedFilename as NSString).pathExtension
        let base = nip.isEmpty ? "CEIDG" : "CEIDG_\(nip)"
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(i)).\(ext)"); i += 1
        }
        savedURL = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = savedURL else { return }
        stop("Zapisano: \(url.path)")
        NSWorkspace.shared.open(url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        stop("Błąd pobierania: \(error.localizedDescription)")
    }

    // Linki otwierane w nowym oknie (target=_blank / window.open) ładujemy w tym samym widoku.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if busy { status = "Błąd ładowania: \(error.localizedDescription)" }
    }

    // MARK: Awaryjnie: zapis bieżącej strony jako PDF

    func savePageAsPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = nip.isEmpty ? "CEIDG.pdf" : "CEIDG_\(nip).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        webView.createPDF { result in
            Task { @MainActor in
                switch result {
                case .success(let data):
                    do { try data.write(to: url); self.status = "Zapisano: \(url.path)"; NSWorkspace.shared.open(url) }
                    catch { self.status = "Błąd zapisu: \(error.localizedDescription)" }
                case .failure(let error):
                    self.status = "Błąd tworzenia PDF: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - UI

struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var browser = Browser()
    @State private var nip = ""

    private var digits: String { NIP.normalize(nip) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("NIP, np. 1234563218", text: $nip)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(go)
                Button("Pobierz wydruk", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(browser.busy || digits.count != 10)
                if browser.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Zapisz stronę jako PDF") { browser.savePageAsPDF() }
            }
            .padding(10)
            Text(browser.status)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 8)
                .textSelection(.enabled)
            Divider()
            WebView(webView: browser.webView)
        }
        .frame(minWidth: 900, minHeight: 650)
    }

    private func go() {
        guard NIP.isValid(digits) else {
            browser.status = "Niepoprawny NIP (błędna suma kontrolna)."
            return
        }
        browser.start(nip: digits)
    }
}

struct CEIDGWydrukApp: App {
    init() {
        // Pozwala uruchomić aplikację przez `swift run` jak zwykłą aplikację z oknem.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("CEIDG Wydruk") { ContentView() }
    }
}

CEIDGWydrukApp.main()
