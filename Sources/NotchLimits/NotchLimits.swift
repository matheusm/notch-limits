import SwiftUI
import ServiceManagement

// MARK: - Contas
// Lidas de ~/.config/notch-limits/accounts.json; sem o arquivo, usa ~/.claude e ~/.codex

enum Provider {
    case claude(configDir: String)   // dir passado em CLAUDE_CONFIG_DIR (~/.claude = conta padrão)
    case codex(home: String)         // CODEX_HOME (~/.codex)
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

let accounts: [Account] = loadAccounts(from: configFile)

private func expand(_ path: String) -> String {
    var p = (path as NSString).expandingTildeInPath
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
}

func loadAccounts(from file: String) -> [Account] {
    var configs = [AccountConfig(name: "Claude", provider: "claude"), AccountConfig(name: "Codex", provider: "codex")]
    if let data = FileManager.default.contents(atPath: file),
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
            return Account(id: "\(i)", name: c.name, glyph: glyph, provider: .codex(home: expand(c.path ?? "~/.codex")))
        default:
            return nil
        }
    }
}

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

    /// Dado com mais de 15 min fica destacado na UI
    var isStale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 900 } ?? true }

    /// Mostra o erro só quando não há dado útil para exibir no lugar
    var visibleError: String? { windows.isEmpty || isStale ? error : nil }

    static func newest(_ a: Usage?, _ b: Usage?) -> Usage? {
        let candidates = [a, b].compactMap { $0 }.filter { !$0.windows.isEmpty && $0.updatedAt != nil }
        return candidates.max { $0.updatedAt! < $1.updatedAt! }
    }
}

/// "atualizado há 3 min" no idioma da interface
func ageText(_ date: Date?) -> String {
    guard let date else { return "" }
    if Date().timeIntervalSince(date) < 60 { return L("updated just now", "atualizado agora", "actualizado ahora") }
    let f = RelativeDateTimeFormatter()
    f.locale = uiLocale
    f.unitsStyle = .short
    return "\(L("updated", "atualizado", "actualizado")) \(f.localizedString(for: date, relativeTo: Date()))"
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var usage: [String: Usage] = [:]
    @Published var loading = false
    private var blockedUntil: [String: Date] = [:]   // backoff por conta após 429

    private let accounts: [Account]
    private let local: (Account) -> Usage?
    private let remote: (Account) async throws -> Usage

    /// Fontes injetáveis para teste; o app usa as contas do accounts.json e os leitores reais
    init(accounts: [Account] = NotchLimits.accounts,
         local: @escaping (Account) -> Usage? = localUsage,
         remote: @escaping (Account) async throws -> Usage = remoteUsage,
         autoRefresh: Bool = true) {
        self.accounts = accounts
        self.local = local
        self.remote = remote
        guard autoRefresh else { return }
        // a cada minuto relê os arquivos locais; a API só é chamada quando o dado local passa de 10 min
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// network: false só relê os arquivos locais (usado ao abrir o notch/menu, sem nenhuma requisição)
    /// force: consulta a API mesmo com dado fresco (botão de atualizar), respeitando o backoff
    func refresh(network: Bool = true, force: Bool = false) async {
        guard !loading else { return }
        loading = true
        let now = Date()
        let current = usage
        let blocked = blockedUntil
        let local = local, remote = remote

        await withTaskGroup(of: (id: String, usage: Usage?, error: Error?, calledAPI: Bool).self) { group in
            for acc in accounts {
                let previous = current[acc.id]
                let canCall = network && (blocked[acc.id] ?? .distantPast) <= now
                group.addTask {
                    let best = Usage.newest(previous, local(acc))
                    let fresh = best?.updatedAt.map { now.timeIntervalSince($0) < staleAfter } ?? false
                    guard canCall, force || !fresh else { return (acc.id, best, nil, false) }
                    do {
                        return (acc.id, try await remote(acc), nil, true)
                    } catch {
                        return (acc.id, best, error, true)
                    }
                }
            }
            for await r in group {
                var u = r.usage ?? Usage()
                if u.plan == nil { u.plan = current[r.id]?.plan }
                if r.calledAPI {
                    u.error = r.error?.localizedDescription
                    if let wait = (r.error as? UsageError)?.retryAfter {
                        blockedUntil[r.id] = Date().addingTimeInterval(wait)
                    }
                } else {
                    u.error = current[r.id]?.error   // sem nova tentativa, mantém o último erro conhecido
                }
                usage[r.id] = u
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
            if let at = usage?.updatedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(ageText(at)).font(.caption2).foregroundStyle(usage?.isStale == true ? .orange : .secondary)
                }
            }
            if let err = usage?.visibleError {
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
                Spacer()
                Button {
                    Task { await store.refresh(force: true) }
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
        .onAppear { Task { await store.refresh(network: false) } }
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
