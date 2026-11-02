import Foundation
import CryptoKit

// Fontes de dados de cada provedor:
// - local: o que o próprio CLI já gravou em disco (sem rede, sem consumir o rate limit)
// - remota: o endpoint de uso, só quando o dado local está velho

/// Dado local com menos de 10 min dispensa a consulta à API
let staleAfter: TimeInterval = 600

func localUsage(_ acc: Account) -> Usage? {
    switch acc.provider {
    case .claude(let dir): localClaude(configDir: dir)
    case .codex(let home): localCodex(codexHome: home)
    }
}

func remoteUsage(_ acc: Account) async throws -> Usage {
    switch acc.provider {
    case .claude(let dir): try await fetchClaude(configDir: dir)
    case .codex(let home): try await fetchCodex(codexHome: home)
    }
}

// MARK: - Utilitários

struct UsageError: LocalizedError {
    let errorDescription: String?
    var retryAfter: TimeInterval? = nil   // preenchido quando a API responde 429
    init(_ msg: String, retryAfter: TimeInterval? = nil) {
        errorDescription = msg
        self.retryAfter = retryAfter
    }
}

private var tokenExpired: UsageError {
    UsageError(L("Token expired — open the CLI to renew it", "Token expirado — abra o CLI para renovar", "Token expirado — abre la CLI para renovarlo"))
}

private func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

private func get(_ url: String, headers: [String: String]) async throws -> Any {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return try JSONSerialization.jsonObject(with: data)
    case 401, 403: throw tokenExpired
    case 429:
        let wait = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init) ?? 300
        let min = max(1, Int((wait / 60).rounded(.up)))
        throw UsageError(L("API rate limited — retrying in \(min) min", "A API limitou as consultas — tenta de novo em \(min) min",
                           "La API limitó las consultas — reintento en \(min) min"), retryAfter: wait)
    default: throw UsageError("HTTP \(status)")
    }
}

// MARK: - Claude

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
    guard p.terminationStatus == 0 else {
        throw UsageError(L("Credential not found in Keychain", "Credencial não encontrada no Keychain", "Credencial no encontrada en el Llavero"))
    }
    return data
}

/// Mesmo esquema do Claude Code: dir padrão sem sufixo, demais com sha256(path)[0..<8]
private func keychainService(for configDir: String) -> String {
    if configDir == "\(home)/.claude" { return "Claude Code-credentials" }
    let hash = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-\(hash.prefix(8))"
}

private func claudeCredentials(configDir: String) throws -> [String: Any] {
    let raw = try runSecurity(keychainService(for: configDir))
    guard let creds = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
    else { throw UsageError(L("Invalid credential", "Credencial inválida", "Credencial no válida")) }
    return creds
}

private func claudePlan(_ creds: [String: Any]) -> String {
    [creds["subscriptionType"] as? String,
     (creds["rateLimitTier"] as? String).flatMap { $0.split(separator: "_").last.map(String.init) }]
        .compactMap { $0 }.joined(separator: " ")
}

/// Converte a resposta de /api/oauth/usage (a mesma que o Claude Code guarda em cache)
private func claudeWindows(_ json: [String: Any]) -> [LimitWindow] {
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
    return windows
}

/// Cache `cachedUsageUtilization` que o Claude Code grava no seu .claude.json ao consultar o uso
private func localClaude(configDir: String) -> Usage? {
    // conta padrão usa ~/.claude.json; com CLAUDE_CONFIG_DIR o arquivo fica dentro do dir
    let state = configDir == "\(home)/.claude" ? "\(home)/.claude.json" : "\(configDir)/.claude.json"
    guard let cache = readJSON(state)?["cachedUsageUtilization"] as? [String: Any],
          let ms = cache["fetchedAtMs"] as? Double,
          let json = cache["utilization"] as? [String: Any]
    else { return nil }
    let plan = (try? claudeCredentials(configDir: configDir)).map(claudePlan)
    return Usage(windows: claudeWindows(json), plan: plan, updatedAt: Date(timeIntervalSince1970: ms / 1000))
}

private func fetchClaude(configDir: String) async throws -> Usage {
    let creds = try await Task.detached { try claudeCredentials(configDir: configDir) }.value
    guard let token = creds["accessToken"] as? String else {
        throw UsageError(L("Invalid credential", "Credencial inválida", "Credencial no válida"))
    }
    if let exp = creds["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 { throw tokenExpired }

    let json = try await get("https://api.anthropic.com/api/oauth/usage", headers: [
        "Authorization": "Bearer \(token)",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.0",
    ]) as? [String: Any] ?? [:]
    return Usage(windows: claudeWindows(json), plan: claudePlan(creds), updatedAt: Date())
}

// MARK: - Codex

private func codexWindow(_ w: [String: Any]?, minutesKey: String, secondsKey: String, resetKey: String) -> LimitWindow? {
    guard let w, let pct = w["used_percent"] as? Double else { return nil }
    let secs = (w[minutesKey] as? Int).map { $0 * 60 } ?? (w[secondsKey] as? Int) ?? 0
    let kind: WindowKind = secs >= 604_800 ? .weekly : secs >= 86_400 ? .days(secs / 86_400) : .session(hours: secs / 3600)
    let reset = (w[resetKey] as? Double).map { Date(timeIntervalSince1970: $0) }
    return LimitWindow(kind: kind, percent: pct, resetsAt: reset)
}

/// Último snapshot de `rate_limits` que o Codex grava nas sessões (sessions/AAAA/MM/DD/*.jsonl) a cada resposta
private func localCodex(codexHome: String) -> Usage? {
    let fm = FileManager.default
    func children(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >).map { "\(path)/\($0)" }
    }
    func mtime(_ path: String) -> Date {
        ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // só os 3 dias mais recentes com sessões
    var days: [String] = []
    outer: for year in children("\(codexHome)/sessions") {
        for month in children(year) {
            for day in children(month) {
                days.append(day)
                if days.count == 3 { break outer }
            }
        }
    }
    let files = days.flatMap { children($0).filter { $0.hasSuffix(".jsonl") } }.sorted { mtime($0) > mtime($1) }

    for file in files.prefix(5) {
        guard let handle = FileHandle(forReadingAtPath: file) else { continue }
        defer { try? handle.close() }
        // o snapshot mais novo está no fim do arquivo; lê só os últimos 512 KB
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let limits = (event["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
                  let at = parseISO(event["timestamp"] as? String)
            else { continue }
            let windows = ["primary", "secondary"].compactMap {
                codexWindow(limits[$0] as? [String: Any], minutesKey: "window_minutes", secondsKey: "", resetKey: "resets_at")
            }
            return Usage(windows: windows, plan: limits["plan_type"] as? String, updatedAt: at)
        }
    }
    return nil
}

private func fetchCodex(codexHome: String) async throws -> Usage {
    guard let tokens = readJSON("\(codexHome)/auth.json")?["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String
    else { throw UsageError(L("auth.json not found — log in to Codex", "auth.json não encontrado — faça login no Codex", "auth.json no encontrado — inicia sesión en Codex")) }

    var headers = ["Authorization": "Bearer \(token)", "User-Agent": "codex_cli_rs"]
    if let acc = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = acc }
    let json = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers) as? [String: Any] ?? [:]

    let rl = json["rate_limit"] as? [String: Any] ?? [:]
    let windows = ["primary_window", "secondary_window"].compactMap {
        codexWindow(rl[$0] as? [String: Any], minutesKey: "", secondsKey: "limit_window_seconds", resetKey: "reset_at")
    }
    return Usage(windows: windows, plan: json["plan_type"] as? String, updatedAt: Date())
}
