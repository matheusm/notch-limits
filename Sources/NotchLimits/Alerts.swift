import Foundation
import UserNotifications

// Avisos de limite (R-06, D-015): perto do limite (90%) e "disponível de novo" quando uma janela em 90%+ reseta.
// A regra é uma função pura; a Central de Notificações fica na borda, em SystemNotifications

struct AlertKey: Hashable {
    let account: String
    let window: WindowKind
}

/// percent guarda o nível efetivo (0 depois do horário de reset), para um reset ser anunciado uma vez só
struct AlertState: Equatable {
    var percent: Double
    var resetsAt: Date?
    var warned: Bool
}

enum LimitAlert: Equatable {
    case nearLimit(account: String, window: WindowKind)
    case availableAgain(account: String, window: WindowKind)
}

/// Compara o estado anterior com o uso atual e devolve os avisos e o novo estado.
/// Só conta com dado útil entra (fresco e com janelas); o resto sai do estado e volta depois como nova base, sem avisar
func limitAlerts(previous: [AlertKey: AlertState], accounts: [Account], usage: [String: Usage], now: Date)
    -> (alerts: [LimitAlert], state: [AlertKey: AlertState]) {
    var alerts: [LimitAlert] = []
    var state: [AlertKey: AlertState] = [:]
    for account in accounts {
        guard let current = usage[account.id], current.isUsable(at: now) else { continue }
        let result = accountAlerts(account.id, windows: current.windows, previous: previous, now: now)
        alerts += result.alerts
        state.merge(result.state) { _, new in new }
    }
    return (alerts, state)
}

/// No máximo um aviso de cada tipo por conta: o cruzamento mais alto e o reset que estava mais alto
private func accountAlerts(_ id: String, windows: [LimitWindow], previous: [AlertKey: AlertState], now: Date)
    -> (alerts: [LimitAlert], state: [AlertKey: AlertState]) {
    var state: [AlertKey: AlertState] = [:]
    var crossing: (window: WindowKind, level: Double)?
    var reset: (window: WindowKind, percent: Double)?
    for window in windows {
        let key = AlertKey(account: id, window: window.kind)
        // passado o horário de reset a janela zerou, mesmo que o snapshot ainda não mostre
        let level = window.resetsAt.map { $0 <= now } == true ? 0 : window.percent
        guard let old = previous[key] else {
            // primeira leitura (abrir o app, conta nova): só registra
            state[key] = AlertState(percent: level, resetsAt: window.resetsAt, warned: level >= nearLimitLevel)
            continue
        }
        // o reset vem do horário, não de uma queda do percentual: oscilação local/API (90.2 → 89.8) não conta
        let periodEnded = old.resetsAt.map { $0 <= now && !samePeriod(window.resetsAt, previous: $0, now: now) } ?? false
        if periodEnded, old.percent >= nearLimitLevel, reset.map({ old.percent > $0.percent }) ?? true {
            reset = (window.kind, old.percent)
        }
        // um aviso por período: fim do período rearma, mesmo se a janela já tinha caído abaixo de 90%
        var warned = old.warned && !periodEnded
        if level >= nearLimitLevel, !warned {
            warned = true
            if crossing.map({ level > $0.level }) ?? true { crossing = (window.kind, level) }
        }
        state[key] = AlertState(percent: level, resetsAt: window.resetsAt, warned: warned)
    }
    var alerts: [LimitAlert] = []
    if let crossing { alerts.append(.nearLimit(account: id, window: crossing.window)) }
    // disponível só quando nenhuma janela da conta continua em 90%+
    if let reset, state.values.allSatisfy({ $0.percent < nearLimitLevel }) {
        alerts.append(.availableAgain(account: id, window: reset.window))
    }
    return (alerts, state)
}

/// Local e API podem discordar do horário do reset por alguns segundos. Uma leitura que ainda não resetou, com horário
/// até 1 min depois do anterior, é o mesmo período visto pela fonte atrasada (senão avisaria 90% de novo antes do reset)
private func samePeriod(_ resetsAt: Date?, previous: Date, now: Date) -> Bool {
    guard let resetsAt, resetsAt > now else { return false }
    return resetsAt.timeIntervalSince(previous) <= 60
}

// MARK: - Texto

/// Uma notificação pronta; o id por conta e tipo faz a nova substituir a anterior na Central de Notificações
struct Notice: Equatable {
    let id: String
    let title: String
    let body: String
}

func notice(for alert: LimitAlert, accounts: [Account], usage: [String: Usage]) -> Notice? {
    func find(_ id: String, _ kind: WindowKind) -> (name: String, window: LimitWindow)? {
        guard let account = accounts.first(where: { $0.id == id }),
              let window = usage[id]?.windows.first(where: { $0.kind == kind }) else { return nil }
        return (account.name, window)
    }
    switch alert {
    case let .nearLimit(id, kind):
        guard let found = find(id, kind) else { return nil }
        let name = found.name, window = found.window
        var body = "\(window.label): \(Int(window.percent.rounded()))%"
        if window.resetsAt != nil { body += " · " + resetText(window.resetsAt, countdown: window.isSession) }
        return Notice(
            id: "\(id)#near",
            title: tr("\(name) is close to its limit", "\(name) está perto do limite", "\(name) está cerca del límite"),
            body: body
        )
    case let .availableAgain(id, kind):
        guard let found = find(id, kind) else { return nil }
        let name = found.name, label = found.window.label
        return Notice(
            id: "\(id)#available",
            title: tr("\(name) is available again", "\(name) está disponível de novo", "\(name) vuelve a estar disponible"),
            body: tr("\(label) has reset", "\(label) resetou", "\(label) se reinició")
        )
    }
}

// MARK: - Notificador

/// Chave do toggle nos Ajustes (UserDefaults, ao lado de showNotch); ausente = desligado (D-015)
let notifyLimitsKey = "notifyLimits"

/// Guarda o estado entre atualizações do Store e posta os avisos
@MainActor
final class LimitNotifier {
    static let shared = LimitNotifier(
        isOn: { UserDefaults.standard.bool(forKey: notifyLimitsKey) },
        deliver: { SystemNotifications.shared.post($0) }
    )

    private var state: [AlertKey: AlertState] = [:]
    private let isOn: () -> Bool
    private let deliver: (Notice) -> Void
    private let clock: () -> Date

    init(isOn: @escaping () -> Bool, deliver: @escaping (Notice) -> Void, clock: @escaping () -> Date = Date.init) {
        self.isOn = isOn
        self.deliver = deliver
        self.clock = clock
    }

    /// O estado anda sempre, mas só posta com o toggle ligado: ligar depois nunca repete um cruzamento antigo
    func update(accounts: [Account], usage: [String: Usage]) {
        let result = limitAlerts(previous: state, accounts: accounts, usage: usage, now: clock())
        state = result.state
        guard isOn() else { return }
        for alert in result.alerts {
            if let notice = notice(for: alert, accounts: accounts, usage: usage) { deliver(notice) }
        }
    }
}

// MARK: - Central de Notificações

@MainActor
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifications()

    /// UNUserNotificationCenter.current() lança uma exceção ObjC (e derruba o processo) sem bundle,
    /// como em swift run e swift test: aí não há notificação. O delegate entra antes do primeiro aviso
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    /// Só texto: sem som nem badge
    func post(_ notice: Notice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil), withCompletionHandler: nil)
    }

    /// Chamado só quando o usuário liga o toggle; negado, com erro ou sem bundle = false
    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    /// Sem bundle, conta como nunca respondida: não há como notificar
    func authorization() async -> UNAuthorizationStatus {
        guard let center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    /// Sem isso o banner some enquanto o app está ativo (por exemplo, com os Ajustes em foco)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
