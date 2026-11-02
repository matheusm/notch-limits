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
    var path: String?                // claude: CLAUDE_CONFIG_DIR (padrão ~/.claude) · codex: CODEX_HOME (padrão ~/.codex)
    var icon: String?                // "claude", "codex" ou nome de um SF Symbol
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configFile = "\(home)/.config/notch-limits/accounts.json"

let accounts: [Account] = loadAccounts(from: configFile)

private func expand(_ path: String) -> String {
    var expanded = (path as NSString).expandingTildeInPath
    while expanded.count > 1 && expanded.hasSuffix("/") { expanded.removeLast() }
    return expanded
}

func loadAccounts(from file: String) -> [Account] {
    var configs = [AccountConfig(name: "Claude", provider: "claude"), AccountConfig(name: "Codex", provider: "codex")]
    if let data = FileManager.default.contents(atPath: file),
       let parsed = try? JSONDecoder().decode([AccountConfig].self, from: data), !parsed.isEmpty {
        configs = parsed
    }
    return configs.enumerated().compactMap { index, config in
        let glyph: Glyph = switch config.icon ?? config.provider {
        case "claude": .claude
        case "codex": .codex
        case let symbol: .symbol(symbol)
        }
        switch config.provider {
        case "claude":
            let dir = expand(config.path ?? "~/.claude")
            return Account(id: "\(index)", name: config.name, glyph: glyph, provider: .claude(configDir: dir))
        case "codex":
            let dir = expand(config.path ?? "~/.codex")
            return Account(id: "\(index)", name: config.name, glyph: glyph, provider: .codex(home: dir))
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
        case .session(let hours): tr("\(hours)h session", "Sessão \(hours)h", "Sesión \(hours)h")
        case .weekly: tr("Weekly", "Semana", "Semanal")
        case .weeklyModel(let model): "\(tr("Weekly", "Semana", "Semanal")) · \(model)"
        case .days(let days): "\(days)d"
        }
    }

    /// Versão compacta usada no notch
    var shortLabel: String {
        switch kind {
        case .session(let hours): "\(hours)h"
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

    static func newest(_ first: Self?, _ second: Self?) -> Self? {
        [first, second]
            .compactMap { $0 }
            .filter { !$0.windows.isEmpty && $0.updatedAt != nil }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }
}

/// "atualizado há 3 min" no idioma da interface
func ageText(_ date: Date?) -> String {
    guard let date else { return "" }
    if Date().timeIntervalSince(date) < 60 { return tr("updated just now", "atualizado agora", "actualizado ahora") }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = uiLocale
    formatter.unitsStyle = .short
    return "\(tr("updated", "atualizado", "actualizado")) \(formatter.localizedString(for: date, relativeTo: Date()))"
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
            for await result in group {
                var updated = result.usage ?? Usage()
                if updated.plan == nil { updated.plan = current[result.id]?.plan }
                if result.calledAPI {
                    updated.error = result.error?.localizedDescription
                    if let wait = (result.error as? UsageError)?.retryAfter {
                        blockedUntil[result.id] = Date().addingTimeInterval(wait)
                    }
                } else {
                    updated.error = current[result.id]?.error   // sem nova tentativa, mantém o último erro conhecido
                }
                usage[result.id] = updated
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

/// Liga/desliga o app como item de login (falha silenciosa: o toggle reflete o pedido do usuário)
func setLaunchAtLogin(_ enabled: Bool) {
    if enabled {
        try? SMAppService.mainApp.register()
    } else {
        try? SMAppService.mainApp.unregister()
    }
}

/// Cor só para alerta (≥70% laranja, ≥90% vermelho); abaixo disso fica neutro
func alertColor(for pct: Double) -> Color? {
    pct >= 90 ? .red : pct >= 70 ? .orange : nil
}

/// Janela de sessão mostra contagem regressiva; as semanais mostram dia e hora do reset
func resetText(_ date: Date?, short: Bool = false, countdown: Bool = false) -> String {
    guard let date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return tr("reset", "resetou", "reiniciado") }
    if countdown {
        let hours = Int(secs) / 3600, minutes = Int(secs) % 3600 / 60
        let left = hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes)min"
        return short
            ? tr("in \(left)", "em \(left)", "en \(left)")
            : tr("resets in \(left)", "reseta em \(left)", "se reinicia en \(left)")
    }
    // arredonda pro minuto mais próximo (a API manda 00:59:59.9 para resets "às 01:00")
    let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = uiLocale
    formatter.dateFormat = "EEE"
    let day = calendar.isDateInToday(rounded) ? tr("today", "hoje", "hoy")
        : calendar.isDateInTomorrow(rounded) ? tr("tomorrow", "amanhã", "mañana") : formatter.string(from: rounded)
    formatter.setLocalizedDateFormatFromTemplate("jmm")   // respeita 12h/24h do idioma
    let when = "\(day) \(formatter.string(from: rounded))"
    return short ? when : tr("resets \(when)", "reseta \(when)", "se reinicia \(when)")
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
                ForEach(windows) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(limit.label).font(.caption)
                            Spacer()
                            Text("\(Int(limit.percent.rounded()))%").font(.caption.monospacedDigit().bold())
                                .foregroundStyle(alertColor(for: limit.percent) ?? .primary)
                        }
                        ProgressView(value: min(limit.percent, 100), total: 100).tint(alertColor(for: limit.percent) ?? .gray)
                        Text(resetText(limit.resetsAt, countdown: limit.isSession)).font(.caption2).foregroundStyle(.secondary)
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
                    if store.loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").accessibilityLabel(tr("Refresh", "Atualizar", "Actualizar"))
                    }
                }
                .buttonStyle(.borderless)
                .help(tr("Refresh", "Atualizar", "Actualizar"))
            }
            HStack {
                Toggle(tr("Launch at login", "Abrir no login", "Abrir al iniciar sesión"), isOn: $launchAtLogin)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Notch", isOn: $showNotch)
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button(tr("Quit", "Sair", "Salir")) { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
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
