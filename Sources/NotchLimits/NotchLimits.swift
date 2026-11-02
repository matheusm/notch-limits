import SwiftUI
import CryptoKit
import ServiceManagement

// MARK: - Contas
// Lidas de ~/.config/notch-limits/accounts.json; sem o arquivo, usa ~/.claude e ~/.codex

enum Provider {
    case claude(configDir: String)   // dir passado em CLAUDE_CONFIG_DIR (~/.claude = conta padrão)
    case codex(authFile: String)
}

struct Account: Identifiable {
    let id: String
    let name: String
    let glyph: Glyph                 // ícone no meio do anel
    let provider: Provider
}

struct AccountConfig: Decodable {
    let name: String
    let provider: String             // "claude" | "codex"
    var path: String? = nil          // claude: CLAUDE_CONFIG_DIR (padrão ~/.claude) · codex: CODEX_HOME (padrão ~/.codex)
    var icon: String? = nil          // "claude", "codex" ou nome de um SF Symbol
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configFile = "\(home)/.config/notch-limits/accounts.json"

let accounts: [Account] = loadAccounts()

private func expand(_ path: String) -> String {
    var p = (path as NSString).expandingTildeInPath
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}

private func loadAccounts() -> [Account] {
    var configs = [AccountConfig(name: "Claude", provider: "claude"), AccountConfig(name: "Codex", provider: "codex")]
    if let data = FileManager.default.contents(atPath: configFile),
       let parsed = try? JSONDecoder().decode([AccountConfig].self, from: data), !parsed.isEmpty {
        configs = parsed
    }
    return configs.enumerated().compactMap { i, c in
        let glyph: Glyph = switch c.icon ?? c.provider {
        case "claude": .claude
        case "codex": .codex
        case let symbol: .symbol(symbol)
        }
        switch c.provider {
        case "claude":
            return Account(id: "\(i)", name: c.name, glyph: glyph, provider: .claude(configDir: expand(c.path ?? "~/.claude")))
        case "codex":
            return Account(id: "\(i)", name: c.name, glyph: glyph, provider: .codex(authFile: expand(c.path ?? "~/.codex") + "/auth.json"))
        default:
            return nil
        }
    }
}

let refreshInterval: TimeInterval = 300

// MARK: - Modelo

enum WindowKind: Hashable {
    case session(hours: Int)
    case weekly
    case weeklyModel(String)
    case days(Int)
}

struct LimitWindow: Identifiable {
    var id: WindowKind { kind }
    let kind: WindowKind
    let percent: Double
    let resetsAt: Date?

    var label: String {
        switch kind {
        case .session(let h): L("\(h)h session", "Sessão \(h)h", "Sesión \(h)h")
        case .weekly: L("Weekly", "Semana", "Semanal")
        case .weeklyModel(let model): "\(L("Weekly", "Semana", "Semanal")) · \(model)"
        case .days(let d): "\(d)d"
        }
    }

    /// Versão compacta usada no notch
    var shortLabel: String {
        switch kind {
        case .session(let h): "\(h)h"
        case .weeklyModel(let model): model
        default: label
        }
    }

    /// Sessão mostra contagem regressiva; as demais mostram dia e hora do reset
    var isSession: Bool {
        if case .session = kind { true } else { false }
    }
}

struct Usage {
    var windows: [LimitWindow] = []
    var plan: String?
    var error: String?
    var updatedAt: Date?

    var peak: Double? { windows.map(\.percent).max() }
}

struct UsageError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}

// MARK: - Fetchers

private func runSecurity(_ service: String) throws -> Data {
    // Usa o binário `security`, que já está na ACL do item criado pelo Claude Code (sem prompt)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw UsageError(L("Credential not found in Keychain", "Credencial não encontrada no Keychain", "Credencial no encontrada en el Llavero")) }
    return data
}

/// Mesmo esquema do Claude Code: dir padrão sem sufixo, demais com sha256(path)[0..<8]
private func keychainService(for configDir: String) -> String {
    if configDir == "\(home)/.claude" { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-\(hash.prefix(8))"
}

private func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

private var tokenExpired: UsageError {
    UsageError(L("Token expired — open the CLI to renew it", "Token expirado — abra o CLI para renovar", "Token expirado — abre la CLI para renovarlo"))
}

private func get(_ url: String, headers: [String: String]) async throws -> Any {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return try JSONSerialization.jsonObject(with: data)
    case 401, 403: throw tokenExpired
    case 429: throw UsageError(L("API rate limited, retrying soon", "Rate limit da API, tenta de novo já já", "Límite de la API, se reintentará pronto"))
    default: throw UsageError("HTTP \(status)")
    }
}

private func fetchClaude(configDir: String) async throws -> Usage {
    let raw = try await Task.detached { try runSecurity(keychainService(for: configDir)) }.value
    guard let creds = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
          let token = creds["accessToken"] as? String
    else { throw UsageError(L("Invalid credential", "Credencial inválida", "Credencial no válida")) }
    if let exp = creds["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
        throw tokenExpired
    }

    let json = try await get("https://api.anthropic.com/api/oauth/usage", headers: [
        "Authorization": "Bearer \(token)",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.0",
    ]) as? [String: Any] ?? [:]

    var windows: [LimitWindow] = []
    if let limits = json["limits"] as? [[String: Any]] {
        for l in limits {
            guard let pct = l["percent"] as? Double else { continue }
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let kind: WindowKind = switch l["kind"] as? String {
            case "session": .session(hours: 5)
            case "weekly_all": .weekly
            default: .weeklyModel(model ?? L("other", "outro", "otro"))
            }
            windows.append(LimitWindow(kind: kind, percent: pct, resetsAt: parseISO(l["resets_at"] as? String)))
        }
    } else {
        for (key, kind) in [("five_hour", WindowKind.session(hours: 5)), ("seven_day", .weekly)] {
            guard let w = json[key] as? [String: Any], let pct = w["utilization"] as? Double else { continue }
            windows.append(LimitWindow(kind: kind, percent: pct, resetsAt: parseISO(w["resets_at"] as? String)))
        }
    }

    let plan = [creds["subscriptionType"] as? String,
                (creds["rateLimitTier"] as? String).flatMap { $0.split(separator: "_").last.map(String.init) }]
        .compactMap { $0 }.joined(separator: " ")
    return Usage(windows: windows, plan: plan, updatedAt: Date())
}

private func fetchCodex(authFile: String) async throws -> Usage {
    guard let data = FileManager.default.contents(atPath: authFile),
          let tokens = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String
    else { throw UsageError(L("auth.json not found — log in to Codex", "auth.json não encontrado — faça login no Codex", "auth.json no encontrado — inicia sesión en Codex")) }

    var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs"]
    if let acc = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = acc }
    let json = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers) as? [String: Any] ?? [:]

    var windows: [LimitWindow] = []
    let rl = json["rate_limit"] as? [String: Any] ?? [:]
    for key in ["primary_window", "secondary_window"] {
        guard let w = rl[key] as? [String: Any], let pct = w["used_percent"] as? Double else { continue }
        let secs = w["limit_window_seconds"] as? Int ?? 0
        let kind: WindowKind = secs >= 604_800 ? .weekly : secs >= 86_400 ? .days(secs / 86_400) : .session(hours: secs / 3600)
        let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        windows.append(LimitWindow(kind: kind, percent: pct, resetsAt: reset))
    }
    return Usage(windows: windows, plan: json["plan_type"] as? String, updatedAt: Date())
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var usage: [String: Usage] = [:]
    @Published var loading = false
    private var lastRefresh = Date.distantPast

    init() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 60 { Task { await refresh() } }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        lastRefresh = Date()
        await withTaskGroup(of: (String, Result<Usage, Error>).self) { group in
            for acc in accounts {
                group.addTask {
                    do {
                        switch acc.provider {
                        case .claude(let dir): return (acc.id, .success(try await fetchClaude(configDir: dir)))
                        case .codex(let file): return (acc.id, .success(try await fetchCodex(authFile: file)))
                        }
                    } catch { return (acc.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let u): usage[id] = u
                case .failure(let e):
                    // mantém o último valor bom e só anota o erro
                    var u = usage[id] ?? Usage()
                    u.error = e.localizedDescription
                    usage[id] = u
                }
            }
        }
        loading = false
    }

    /// Um anel por conta, preenchido com o maior uso entre as janelas de limite
    var menuBarImage: NSImage {
        renderStrip(accounts.map { (usage[$0.id]?.peak, $0.glyph) })
    }
}

// MARK: - UI

/// Cor só para alerta (≥70% laranja, ≥90% vermelho); abaixo disso fica neutro
func alertColor(for pct: Double) -> Color? {
    pct >= 90 ? .red : pct >= 70 ? .orange : nil
}

/// Janela de sessão mostra contagem regressiva; as semanais mostram dia e hora do reset
func resetText(_ date: Date?, short: Bool = false, countdown: Bool = false) -> String {
    guard let date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return L("reset", "resetou", "reiniciado") }
    if countdown {
        let h = Int(secs) / 3600, m = Int(secs) % 3600 / 60
        let t = h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
        return short ? L("in \(t)", "em \(t)", "en \(t)") : L("resets in \(t)", "reseta em \(t)", "se reinicia en \(t)")
    }
    // arredonda pro minuto mais próximo (a API manda 00:59:59.9 para resets "às 01:00")
    let d = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = uiLocale
    f.dateFormat = "EEE"
    let day = cal.isDateInToday(d) ? L("today", "hoje", "hoy")
        : cal.isDateInTomorrow(d) ? L("tomorrow", "amanhã", "mañana") : f.string(from: d)
    f.setLocalizedDateFormatFromTemplate("jmm")   // respeita 12h/24h do idioma
    let t = "\(day) \(f.string(from: d))"
    return short ? t : L("resets \(t)", "reseta \(t)", "se reinicia \(t)")
}

struct AccountView: View {
    let account: Account
    let usage: Usage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name).font(.headline)
                if let plan = usage?.plan, !plan.isEmpty {
                    Text(plan).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            if let err = usage?.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let windows = usage?.windows, !windows.isEmpty {
                ForEach(windows) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(w.label).font(.caption)
                            Spacer()
                            Text("\(Int(w.percent.rounded()))%").font(.caption.monospacedDigit().bold())
                                .foregroundStyle(alertColor(for: w.percent) ?? .primary)
                        }
                        ProgressView(value: min(w.percent, 100), total: 100).tint(alertColor(for: w.percent) ?? .gray)
                        Text(resetText(w.resetsAt, countdown: w.isSession)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if usage == nil {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showNotch") private var showNotch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(accounts) { acc in
                AccountView(account: acc, usage: store.usage[acc.id])
                if acc.id != accounts.last?.id { Divider() }
            }
            Divider()
            HStack {
                if let t = store.usage.values.compactMap(\.updatedAt).max() {
                    Text("\(L("Updated", "Atualizado", "Actualizado")) \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help(L("Refresh", "Atualizar", "Actualizar"))
            }
            HStack {
                Toggle(L("Launch at login", "Abrir no login", "Abrir al iniciar sesión"), isOn: $launchAtLogin)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Toggle("Notch", isOn: $showNotch)
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button(L("Quit", "Sair", "Salir")) { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { store.refreshIfStale() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { notch = NotchController(store: .shared) }
    }
}

@main
struct NotchLimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // some da barra enquanto o notch estiver visível
        MenuBarExtra(isInserted: Binding(get: { !appState.notchVisible }, set: { _ in })) {
            ContentView(store: store)
        } label: {
            Image(nsImage: store.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}
