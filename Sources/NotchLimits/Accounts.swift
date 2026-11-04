import Foundation

// MARK: - Contas
// Encontradas em ~/.claude* e ~/.codex* e mescladas com ~/.config/notch-limits/accounts.json,
// que os Ajustes também gravam

enum Provider {
    case claude(configDir: String)   // dir passado em CLAUDE_CONFIG_DIR (~/.claude = conta padrão)
    case codex(home: String)         // CODEX_HOME (~/.codex)

    /// Valor de "provider" no accounts.json
    var name: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// Nome exibido (não traduzido)
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var path: String {
        switch self {
        case .claude(let dir): dir
        case .codex(let home): home
        }
    }
}

struct Account: Identifiable {
    var name: String
    var glyph: Glyph                 // ícone no meio do anel
    let provider: Provider
    var enabled = true               // false = escondida nos Ajustes

    /// provider:path, estável ao renomear, reordenar ou esconder: uso e backoff nunca passam de uma conta para outra
    var id: String { "\(provider.name):\(provider.path)" }
}

struct AccountConfig: Codable {
    let name: String
    let provider: String             // "claude" | "codex"
    var path: String?                // claude: CLAUDE_CONFIG_DIR (padrão ~/.claude) · codex: CODEX_HOME (padrão ~/.codex)
    var icon: String?                // "claude", "codex" ou nome de um SF Symbol
    var enabled: Bool?               // ausente = visível; o app só grava false
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configFile = "\(home)/.config/notch-limits/accounts.json"

/// Rodízio de ícones das contas além da primeira de cada provedor; o menu de ícones dos Ajustes usa a mesma lista
let extraIcons: [(symbol: String, label: String)] = [
    ("leaf.fill", tr("Leaf", "Folha", "Hoja")),
    ("briefcase.fill", tr("Briefcase", "Maleta", "Maletín")),
    ("building.2.fill", tr("Building", "Prédio", "Edificio")),
    ("house.fill", tr("House", "Casa", "Casa")),
    ("star.fill", tr("Star", "Estrela", "Estrella")),
    ("bolt.fill", tr("Bolt", "Raio", "Rayo")),
]

/// Troca o ~ inicial pela home injetada e tira barras finais (expandingTildeInPath leria a home real)
func expand(_ path: String, home: String) -> String {
    var expanded = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
    while expanded.count > 1 && expanded.hasSuffix("/") { expanded.removeLast() }
    return expanded
}

/// Inverso de expand, para gravar e exibir: caminhos dentro da home viram ~/…
func abbreviate(_ path: String, home: String) -> String {
    path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// A conta padrão guarda o estado em ~/.claude.json, fora de ~/.claude; com CLAUDE_CONFIG_DIR ele fica dentro do dir
func claudeStateFile(configDir: String, home: String) -> String {
    configDir == "\(home)/.claude" ? "\(home)/.claude.json" : "\(configDir)/.claude.json"
}

extension Account {
    /// Entrada do accounts.json; nil para provider desconhecido
    init?(config: AccountConfig, home: String) {
        let provider: Provider
        switch config.provider {
        case "claude": provider = .claude(configDir: expand(config.path ?? "~/.claude", home: home))
        case "codex": provider = .codex(home: expand(config.path ?? "~/.codex", home: home))
        default: return nil
        }
        let glyph = Glyph(name: config.icon ?? config.provider)
        self.init(name: config.name, glyph: glyph, provider: provider, enabled: config.enabled ?? true)
    }

    func config(home: String) -> AccountConfig {
        AccountConfig(
            name: name,
            provider: provider.name,
            path: abbreviate(provider.path, home: home),
            icon: glyph.name,
            enabled: enabled ? nil : false
        )
    }
}

// MARK: - Descoberta

/// Só olha os filhos diretos da home e checa se os arquivos-marca existem:
/// não lê conteúdo, rc do shell nem Keychain
func discoverAccounts(home: String) -> [Account] {
    let fm = FileManager.default
    func exists(_ path: String, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue == directory
    }
    let children = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted()
    func folders(_ prefix: String, marker: String) -> [String] {
        children.filter { name in
            name.hasPrefix(prefix) && exists("\(home)/\(name)", directory: true) && exists("\(home)/\(name)/\(marker)", directory: false)
        }
    }

    var found: [(folder: String, provider: Provider)] = []
    if exists(claudeStateFile(configDir: "\(home)/.claude", home: home), directory: false) {
        found.append((".claude", .claude(configDir: "\(home)/.claude")))
    }
    found += folders(".claude", marker: ".claude.json").filter { $0 != ".claude" }.map { ($0, .claude(configDir: "\(home)/\($0)")) }
    found += folders(".codex", marker: "auth.json").map { ($0, .codex(home: "\(home)/\($0)")) }

    var firsts: Set<String> = []
    var extras = 0
    return found.map { folder, provider in
        // a primeira de cada provedor leva o glifo dele; as demais seguem um rodízio único, sem repetir entre provedores
        let glyph: Glyph
        if firsts.insert(provider.name).inserted {
            glyph = Glyph(name: provider.name)
        } else {
            glyph = .symbol(extraIcons[extras % extraIcons.count].symbol)
            extras += 1
        }
        return Account(name: accountName(folder: folder, provider: provider), glyph: glyph, provider: provider)
    }
}

/// ".claude-work" → "Claude Work" (só a primeira letra do sufixo vira maiúscula);
/// sufixo só de separadores (".codex-") fica com o nome da pasta, para não repetir o nome da conta padrão
private func accountName(folder: String, provider: Provider) -> String {
    let rest = folder.dropFirst(provider.name.count + 1)   // tira "." + nome do provedor
    guard !rest.isEmpty else { return provider.title }
    let suffix = rest.drop { "-_.".contains($0) }
    guard !suffix.isEmpty else { return String(folder.dropFirst()) }
    return "\(provider.title) \(suffix.prefix(1).uppercased())\(suffix.dropFirst())"
}

// MARK: - accounts.json

/// Lista completa para os Ajustes (visíveis e escondidas); o Store fica só com as visíveis
func mergeAccounts(saved: [AccountConfig]?, discovered: [Account], home: String) -> [Account] {
    var list: [Account] = []
    for config in saved ?? [] {
        guard let account = Account(config: config, home: home), !list.contains(where: { $0.id == account.id }) else { continue }
        list.append(account)
    }
    // sem arquivo (ou sem entrada válida) vale a descoberta, tudo visível; sem nada encontrado, os padrões de sempre
    guard !list.isEmpty else {
        return discovered.isEmpty ? [
            Account(name: "Claude", glyph: .claude, provider: .claude(configDir: "\(home)/.claude")),
            Account(name: "Codex", glyph: .codex, provider: .codex(home: "\(home)/.codex")),
        ] : discovered
    }
    // com arquivo, ele manda: o que a descoberta achar a mais entra escondido, para não mudar um setup feito à mão
    for var account in discovered where !list.contains(where: { $0.id == account.id }) {
        account.enabled = false
        list.append(account)
    }
    if !list.contains(where: \.enabled) { list[0].enabled = true }
    return list
}

func loadAccounts(from file: String, home: String) -> [Account] {
    let saved = FileManager.default.contents(atPath: file).flatMap { try? JSONDecoder().decode([AccountConfig].self, from: $0) }
    return mergeAccounts(saved: saved, discovered: discoverAccounts(home: home), home: home)
}

/// Grava a lista completa. Antes de sobrescrever pela primeira vez um arquivo escrito ou editado à mão, guarda os bytes
/// dele em .bak (um .bak existente nunca é trocado). Um accounts.json ligado por symlink continua link: grava no destino
func saveAccounts(_ accounts: [Account], to file: String, home: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let backup = "\(file).bak"
    if let current = fm.contents(atPath: file), !fm.fileExists(atPath: backup), !isAppWritten(current) {
        try current.write(to: URL(fileURLWithPath: backup))
    }
    let target = URL(fileURLWithPath: file).resolvingSymlinksInPath()
    try encodeAccounts(accounts.map { $0.config(home: home) }).write(to: target, options: .atomic)
}

private func encodeAccounts(_ configs: [AccountConfig]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(configs)
}

/// Arquivo que o próprio app gravou: relido e regravado dá exatamente os mesmos bytes
private func isAppWritten(_ data: Data) -> Bool {
    guard let configs = try? JSONDecoder().decode([AccountConfig].self, from: data) else { return false }
    return (try? encodeAccounts(configs)) == data
}
