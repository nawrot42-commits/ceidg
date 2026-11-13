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
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    enum Step { case idle, search, results, details, waitingPDF, done }

    let webView: WKWebView
    /// Wywoływane przy każdej zmianie statusu – odświeża okno.
    var onChange: (() -> Void)?
    var status = "Wpisz NIP i kliknij „Pobierz wydruk”." { didSet { onChange?() } }
    var busy = false { didSet { onChange?() } }

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

// MARK: - Okno (AppKit)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let browser = Browser()
    var window: NSWindow!
    let nipField = NSTextField()
    let fetchButton = NSButton(title: "Pobierz wydruk", target: nil, action: nil)
    let saveButton = NSButton(title: "Zapisz stronę jako PDF", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let statusLabel = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        nipField.placeholderString = "NIP, np. 1234563218"
        nipField.target = self
        nipField.action = #selector(go)
        fetchButton.target = self
        fetchButton.action = #selector(go)
        fetchButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePage)
        saveButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [nipField, fetchButton, spinner, spacer, saveButton])
        bar.orientation = .horizontal
        bar.spacing = 8

        let web = browser.webView
        let content = NSView()
        for v in [bar, statusLabel, web] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            nipField.widthAnchor.constraint(equalToConstant: 220),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            web.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "CEIDG Wydruk"
        window.contentView = content
        window.minSize = NSSize(width: 800, height: 550)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nipField)

        browser.onChange = { [weak self] in self?.refresh() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)

        // NIP podany przy starcie: `open -a CEIDGWydruk --args 1234563218`
        if let arg = CommandLine.arguments.dropFirst().first(where: { NIP.normalize($0).count == 10 }) {
            pendingNIP = NIP.normalize(arg)
        }
        if let nip = pendingNIP { pendingNIP = nil; start(nip: nip) }
    }

    private var pendingNIP: String?

    /// Wywołanie z Raycasta / Terminala: `open "ceidgwydruk://1234563218"`
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let nip = NIP.normalize(url.absoluteString)
        if window == nil { pendingNIP = nip } else { start(nip: nip) }
    }

    private func start(nip: String) {
        nipField.stringValue = nip
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        browser.busy = false
        go()
    }

    func refresh() {
        statusLabel.stringValue = browser.status
        fetchButton.isEnabled = !browser.busy
        if browser.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc func go() {
        guard !browser.busy else { return }
        let digits = NIP.normalize(nipField.stringValue)
        guard NIP.isValid(digits) else {
            browser.status = "Niepoprawny NIP (wpisz 10 cyfr, sprawdź sumę kontrolną)."
            return
        }
        browser.start(nip: digits)
    }

    @objc func savePage() { browser.savePageAsPDF() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
/// Menu z „Edycja”, żeby działało ⌘V (wklejanie NIP) i ⌘Q.
func buildMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Zakończ CEIDG Wydruk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edycja")
    edit.addItem(withTitle: "Wytnij", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Kopiuj", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Wklej", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Zaznacz wszystko", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = buildMenu()
    app.run()
}
