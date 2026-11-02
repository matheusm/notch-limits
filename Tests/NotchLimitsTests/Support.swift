import Foundation
@testable import NotchLimits

/// Diretório temporário isolado por teste, apagado ao sair do escopo
final class TempDir {
    let path: String

    init() {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("notch-limits-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func write(_ relative: String, _ contents: String, modified: Date? = nil) -> String {
        let file = (path as NSString).appendingPathComponent(relative)
        try! FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! contents.write(toFile: file, atomically: true, encoding: .utf8)
        if let modified {
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file)
        }
        return file
    }
}

extension TempDir {
    /// Home falsa: cria cada arquivo (e as pastas no caminho) com "{}", o bastante para a descoberta
    convenience init(files: [String]) {
        self.init()
        for file in files { write(file, "{}") }
    }
}

func window(_ kind: WindowKind, _ percent: Double = 10) -> LimitWindow {
    LimitWindow(kind: kind, percent: percent, resetsAt: nil)
}

func usage(minutesAgo: Double, percent: Double = 10) -> Usage {
    Usage(windows: [window(.weekly, percent)], updatedAt: Date().addingTimeInterval(-minutesAgo * 60))
}
