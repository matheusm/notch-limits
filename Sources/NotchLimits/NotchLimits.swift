import SwiftUI
import ServiceManagement

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
    var isStale: Bool { isStale(at: Date()) }

    func isStale(at now: Date) -> Bool { updatedAt.map { now.timeIntervalSince($0) > 900 } ?? true }

    /// Dado que a UI mostra sem aviso: tem janelas e no máximo 15 min (os alertas só olham esse dado)
    func isUsable(at now: Date) -> Bool { !windows.isEmpty && !isStale(at: now) }

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
    static let shared = Store(onRefresh: LimitNotifier.shared.update)

    @Published private(set) var accounts: [Account]   // só as visíveis, na ordem dos Ajustes
    @Published var usage: [String: Usage] = [:]          // por Account.id (provider:path)
    @Published var loading = false
    private var blockedUntil: [String: Date] = [:]   // backoff por conta após 429
    private var localPending = false                 // releitura local pedida durante outra atualização

    private let local: (Account) -> Usage?
    private let remote: (Account) async throws -> Usage
    private let onRefresh: @MainActor ([Account], [String: Usage]) -> Void

    /// Fontes injetáveis para teste; o app usa as contas encontradas na home e do accounts.json e os leitores reais.
    /// onRefresh recebe o uso final uma vez ao fim de cada atualização (o app passa o notificador, R-06)
    init(accounts: [Account] = loadAccounts(from: configFile, home: home),
         local: @escaping (Account) -> Usage? = localUsage,
         remote: @escaping (Account) async throws -> Usage = remoteUsage,
         onRefresh: @escaping @MainActor ([Account], [String: Usage]) -> Void = { _, _ in },
         autoRefresh: Bool = true) {
        self.accounts = accounts.filter(\.enabled)
        self.local = local
        self.remote = remote
        self.onRefresh = onRefresh
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
        guard !loading else {
            if !network { localPending = true }   // roda quando a atual terminar (ex.: conta nova nos Ajustes)
            return
        }
        loading = true
        let now = Date()
        let current = usage
        let blocked = blockedUntil
        let local = local, remote = remote

        await withTaskGroup(of: Outcome.self) { group in
            for acc in accounts {
                let previous = current[acc.id]
                let canCall = network && (blocked[acc.id] ?? .distantPast) <= now
                group.addTask {
                    let best = Usage.newest(previous, local(acc))
                    let fresh = best?.updatedAt.map { now.timeIntervalSince($0) < staleAfter } ?? false
                    guard canCall, force || !fresh else { return Outcome(id: acc.id, usage: best, error: nil, calledAPI: false) }
                    do {
                        return Outcome(id: acc.id, usage: try await remote(acc), error: nil, calledAPI: true)
                    } catch {
                        return Outcome(id: acc.id, usage: best, error: error, calledAPI: true)
                    }
                }
            }
            for await outcome in group {
                record(outcome, previous: current[outcome.id])
            }
        }
        loading = false
        onRefresh(accounts, usage)
        if localPending {
            localPending = false
            await refresh(network: false)
        }
    }

    /// Resultado de uma conta numa atualização
    private struct Outcome {
        let id: String
        let usage: Usage?
        let error: Error?
        let calledAPI: Bool
    }

    /// O Retry-After vale mesmo se a conta foi escondida durante a chamada (D-005);
    /// o uso só é gravado se a conta ainda está na lista
    private func record(_ outcome: Outcome, previous: Usage?) {
        if outcome.calledAPI, let wait = (outcome.error as? UsageError)?.retryAfter {
            blockedUntil[outcome.id] = Date().addingTimeInterval(wait)
        }
        guard accounts.contains(where: { $0.id == outcome.id }) else { return }
        var updated = outcome.usage ?? Usage()
        if updated.plan == nil { updated.plan = previous?.plan }
        // sem nova tentativa, mantém o último erro conhecido
        updated.error = outcome.calledAPI ? outcome.error?.localizedDescription : previous?.error
        usage[outcome.id] = updated
    }

    /// Troca a lista na hora (Ajustes) e só relê os arquivos locais, sem nenhuma requisição (D-002).
    /// O uso de contas que saíram é descartado; o backoff fica, para esconder e mostrar não furar o Retry-After (D-005)
    @discardableResult
    func setAccounts(_ list: [Account]) -> Task<Void, Never> {
        accounts = list.filter(\.enabled)
        let ids = Set(accounts.map(\.id))
        usage = usage.filter { ids.contains($0.key) }
        return Task { await refresh(network: false) }
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

/// Níveis de alerta: laranja a partir de 70%; vermelho e notificação (R-06) a partir de 90%
let warningLevel: Double = 70
let nearLimitLevel: Double = 90

/// Cor só para alerta; abaixo de warningLevel fica neutro
func alertColor(for pct: Double) -> Color? {
    pct >= nearLimitLevel ? .red : pct >= warningLevel ? .orange : nil
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
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name).font(.headline)
                if let plan = usage?.plan, !plan.isEmpty {
                    Text(plan).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if isBest {
                    Text(bestNowLabel).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(bestNowHelp(account.provider))
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
        let best = bestAccountIDs(accounts: store.accounts, usage: store.usage, now: Date())
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.accounts) { acc in
                AccountView(account: acc, usage: store.usage[acc.id], isBest: best.contains(acc.id))
                if acc.id != store.accounts.last?.id { Divider() }
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    SettingsWindow.shared.show(store: store)
                } label: {
                    Image(systemName: "gearshape").accessibilityLabel(tr("Settings", "Ajustes", "Ajustes"))
                }
                .buttonStyle(.borderless)
                .help(tr("Settings", "Ajustes", "Ajustes"))
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
