import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Walidacja NIP

enum NIP {
    /// Zostawia same cyfry (pozwala wpisać np. "123-456-32-18").
    static func normalize(_ s: String) -> String { s.filter(\.isNumber) }

    static func isValid(_ nip: String) -> Bool {
        let d = nip.compactMap { $0.wholeNumberValue }
        guard d.count == 10 else { return false }
        let w = [6, 5, 7, 2, 3, 4, 5, 6, 7]
        let sum = zip(d, w).map { $0 * $1 }.reduce(0, +)
        return sum % 11 == d[9]
    }
}

// MARK: - Klient API CEIDG (dane.biznes.gov.pl, API v3)

enum CEIDGError: LocalizedError {
    case notFound, unauthorized, rateLimited, http(Int), badResponse

    var errorDescription: String? {
        switch self {
        case .notFound: return "Nie znaleziono firmy o podanym NIP w CEIDG."
        case .unauthorized: return "Nieprawidłowy lub wygasły token API CEIDG."
        case .rateLimited: return "Przekroczono limit zapytań do API. Spróbuj za chwilę."
        case .http(let c): return "Błąd serwera CEIDG (HTTP \(c))."
        case .badResponse: return "Nieoczekiwana odpowiedź z CEIDG."
        }
    }
}

struct CEIDGClient {
    let token: String
    var baseURL = URL(string: "https://dane.biznes.gov.pl/api/ceidg/v3/firma")!

    /// Zwraca słownik z danymi pierwszej firmy pasującej do NIP.
    func fetch(nip: String) async throws -> [String: Any] {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "nip", value: nip)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CEIDGError.badResponse }
        switch http.statusCode {
        case 200: break
        case 204, 404: throw CEIDGError.notFound
        case 401, 403: throw CEIDGError.unauthorized
        case 429: throw CEIDGError.rateLimited
        default: throw CEIDGError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CEIDGError.badResponse }

        // API zwraca {"firma": [...]} lub {"firmy": [...]}
        let list = (json["firma"] ?? json["firmy"]) as? [[String: Any]]
        guard let firm = list?.first ?? (json["nazwa"] != nil ? json : nil)
        else { throw CEIDGError.notFound }
        return firm
    }
}

// MARK: - Budowanie wydruku (HTML -> PDF)

enum Printout {
    static let labels: [String: String] = [
        "nazwa": "Firma przedsiębiorcy",
        "wlasciciel": "Właściciel",
        "imie": "Imię", "nazwisko": "Nazwisko",
        "nip": "NIP", "regon": "REGON",
        "status": "Status",
        "dataRozpoczecia": "Data rozpoczęcia działalności",
        "dataZawieszenia": "Data zawieszenia",
        "dataWznowienia": "Data wznowienia",
        "dataZakonczenia": "Data zakończenia",
        "dataWykreslenia": "Data wykreślenia",
        "adresDzialalnosci": "Adres wykonywania działalności",
        "adresKorespondencyjny": "Adres do doręczeń",
        "adresyDzialalnosciDodatkowe": "Dodatkowe adresy działalności",
        "ulica": "Ulica", "budynek": "Nr budynku", "lokal": "Nr lokalu",
        "miasto": "Miejscowość", "kod": "Kod", "gmina": "Gmina",
        "powiat": "Powiat", "wojewodztwo": "Województwo", "kraj": "Kraj",
        "pkd": "Kody PKD", "pkdGlowny": "Przeważający PKD",
        "obywatelstwa": "Obywatelstwa", "spolki": "Spółki cywilne",
        "telefon": "Telefon", "email": "E-mail", "www": "Strona WWW",
        "link": "Link", "id": "Identyfikator wpisu",
    ]

    static func label(_ key: String) -> String {
        if let l = labels[key] { return l }
        // camelCase -> "Camel case"
        var out = ""
        for ch in key {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(contentsOf: ch.lowercased())
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func valueHTML(_ v: Any) -> String {
        switch v {
        case let d as [String: Any]:
            return table(d)
        case let a as [Any]:
            if a.isEmpty { return "—" }
            return a.map { valueHTML($0) }.joined(separator: "<br>")
        case is NSNull:
            return "—"
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            return n.boolValue ? "tak" : "nie"
        default:
            let s = "\(v)"
            return s.isEmpty ? "—" : esc(s)
        }
    }

    static func table(_ d: [String: Any]) -> String {
        let keys = d.keys.sorted {
            let ia = preferredOrder.firstIndex(of: $0) ?? Int.max
            let ib = preferredOrder.firstIndex(of: $1) ?? Int.max
            return ia != ib ? ia < ib : $0 < $1
        }
        let rows = keys.compactMap { k -> String? in
            guard let v = d[k], !(v is NSNull) else { return nil }
            return "<tr><th>\(esc(label(k)))</th><td>\(valueHTML(v))</td></tr>"
        }
        return "<table>\(rows.joined())</table>"
    }

    static let preferredOrder = [
        "nazwa", "wlasciciel", "imie", "nazwisko", "nip", "regon", "status",
        "dataRozpoczecia", "dataZawieszenia", "dataWznowienia", "dataZakonczenia",
        "dataWykreslenia", "adresDzialalnosci", "adresKorespondencyjny",
        "adresyDzialalnosciDodatkowe", "pkdGlowny", "pkd", "kod",
        "ulica", "budynek", "lokal", "miasto", "gmina", "powiat", "wojewodztwo", "kraj",
    ]

    static func html(for firm: [String: Any], nip: String) -> String {
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: Helvetica; font-size: 10pt; }
        h1 { font-size: 15pt; margin-bottom: 2pt; }
        p.meta { color: #555; font-size: 9pt; }
        table { border-collapse: collapse; width: 100%; margin: 2pt 0; }
        th, td { border: 1px solid #bbb; padding: 3pt; vertical-align: top; text-align: left; }
        th { background: #eee; width: 35%; font-weight: bold; }
        </style></head><body>
        <h1>Wydruk z CEIDG</h1>
        <p class="meta">NIP: \(esc(nip)) · pobrano: \(esc(date)) · źródło: API CEIDG (dane.biznes.gov.pl)</p>
        \(table(firm))
        </body></html>
        """
    }

    /// Renderuje HTML do wielostronicowego PDF A4.
    @MainActor
    static func savePDF(html: String, to url: URL) throws {
        guard let data = html.data(using: .utf8),
              let attr = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                            documentAttributes: nil)
        else { throw CEIDGError.badResponse }

        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.paperSize = NSSize(width: 595, height: 842) // A4
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(attr)
        view.isVerticallyResizable = true
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CEIDGError.badResponse }
    }
}

// MARK: - UI

@MainActor
final class Model: ObservableObject {
    @Published var nip = ""
    @Published var busy = false
    @Published var message: String?
    @Published var firm: [String: Any]?

    var nipDigits: String { NIP.normalize(nip) }

    func fetch() async {
        message = nil; firm = nil
        guard NIP.isValid(nipDigits) else { message = "Niepoprawny NIP (błędna suma kontrolna)."; return }
        let token = UserDefaults.standard.string(forKey: "ceidgToken") ?? ""
        guard !token.isEmpty else { message = "Wpisz token API CEIDG w Ustawieniach (⌘,)."; return }
        busy = true; defer { busy = false }
        do {
            firm = try await CEIDGClient(token: token).fetch(nip: nipDigits)
            savePDF()
        } catch {
            message = error.localizedDescription
        }
    }

    func savePDF() {
        guard let firm else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "CEIDG_\(nipDigits).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Printout.savePDF(html: Printout.html(for: firm, nip: nipDigits), to: url)
            message = "Zapisano: \(url.lastPathComponent)"
            NSWorkspace.shared.open(url)
        } catch {
            message = "Nie udało się zapisać PDF: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @AppStorage("ceidgToken") private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wydruk z CEIDG").font(.title2.bold())
            HStack {
                TextField("NIP, np. 1234563218", text: $model.nip)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.fetch() } }
                Button("Pobierz wydruk") { Task { await model.fetch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.nipDigits.count != 10)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let firm = model.firm {
                Text(firm["nazwa"] as? String ?? "—").font(.headline)
                Button("Zapisz PDF ponownie…") { model.savePDF() }
            }
            if let msg = model.message {
                Text(msg).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Link("Wyszukiwarka CEIDG (oficjalny wydruk)",
                     destination: URL(string: "https://aplikacja.ceidg.gov.pl/ceidg/ceidg.public.ui/search.aspx")!)
                Spacer()
                if token.isEmpty { Text("Brak tokenu API").foregroundStyle(.red) }
            }
            .font(.footnote)
        }
        .padding(20)
        .frame(width: 520, height: 260)
    }
}

struct SettingsView: View {
    @AppStorage("ceidgToken") var token = ""

    var body: some View {
        Form {
            SecureField("Token API CEIDG", text: $token)
            Text("Bezpłatny token (JWT) uzyskasz na biznes.gov.pl → „Dostęp do API CEIDG”.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
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
            .windowResizability(.contentSize)
        Settings { SettingsView() }
    }
}

CEIDGWydrukApp.main()
