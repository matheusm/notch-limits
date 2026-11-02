import Foundation

// Interface em inglês, português e espanhol, seguindo a ordem de idiomas do sistema (padrão: inglês)

enum Lang: String {
    case en, pt, es
}

/// Primeiro idioma suportado da lista de preferências do sistema, junto com o identificador original (ex.: "pt-BR")
private let preferred: (lang: Lang, id: String) = {
    for id in Locale.preferredLanguages {
        if let lang = Lang(rawValue: String(id.prefix(2))) { return (lang, id) }
    }
    return (.en, "en")
}()

let lang = preferred.lang
let uiLocale = Locale(identifier: preferred.id)

/// Escolhe o texto do idioma atual
func L(_ en: String, _ pt: String, _ es: String) -> String {
    switch lang {
    case .en: en
    case .pt: pt
    case .es: es
    }
}
