import Foundation
import os

/// Categorias de log (seção 6.5).
enum LogCategory: String {
    case app = "app"
    case capture = "captura"
    case processing = "processamento"
    case export = "export"
}

/// Log do app. Cada evento vai para o `os.Logger` (Console do macOS, se um dia houver)
/// e para um arquivo de texto em Documents/Logs, porque não há debugger neste projeto:
/// o arquivo é o que o Caio exporta em Ajustes → Logs para diagnosticar um problema.
final class AppLog {
    static let shared = AppLog()

    let fileURL: URL
    private let previousFileURL: URL
    /// Fila serial: garante a ordem das linhas e tira a escrita em disco da thread principal.
    private let queue = DispatchQueue(label: "com.caio.scanlab.log")
    private let formatter: DateFormatter
    private let loggers: [LogCategory: Logger]
    private static let maxFileBytes: Int64 = 1_000_000

    private init() {
        fileURL = AppPaths.logsRoot.appendingPathComponent("scanlab-log.txt")
        previousFileURL = AppPaths.logsRoot.appendingPathComponent("scanlab-log-anterior.txt")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter = dateFormatter

        let subsystem = "com.caio.scanlab"
        loggers = [
            .app: Logger(subsystem: subsystem, category: LogCategory.app.rawValue),
            .capture: Logger(subsystem: subsystem, category: LogCategory.capture.rawValue),
            .processing: Logger(subsystem: subsystem, category: LogCategory.processing.rawValue),
            .export: Logger(subsystem: subsystem, category: LogCategory.export.rawValue)
        ]

        prepareFile()
    }

    static func info(_ category: LogCategory, _ message: String) {
        shared.write(category, level: "INFO", message)
    }

    static func warning(_ category: LogCategory, _ message: String) {
        shared.write(category, level: "AVISO", message)
    }

    static func error(_ category: LogCategory, _ message: String) {
        shared.write(category, level: "ERRO", message)
    }

    /// Últimas linhas do arquivo, para a tela de Logs.
    func readTail(maxLines: Int) -> String {
        // sync na mesma fila: espera as escritas pendentes antes de ler.
        return queue.sync { () -> String in
            guard let data = try? Data(contentsOf: fileURL) else {
                return ""
            }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync {
            try? Data().write(to: fileURL)
        }
    }

    // MARK: - Interno

    private func write(_ category: LogCategory, level: String, _ message: String) {
        if let logger = loggers[category] {
            if level == "ERRO" {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.info("\(message, privacy: .public)")
            }
        }

        let now = Date()
        queue.async {
            let line = "\(self.formatter.string(from: now)) [\(level)] [\(category.rawValue)] \(message)\n"
            self.append(line)
        }
    }

    private func prepareFile() {
        let fileManager = FileManager.default
        try? AppPaths.ensureDirectory(AppPaths.logsRoot)

        // Rotação simples: se o arquivo passou do limite, vira "anterior" e começa outro.
        if AppPaths.fileSize(fileURL) > AppLog.maxFileBytes {
            try? fileManager.removeItem(at: previousFileURL)
            try? fileManager.moveItem(at: fileURL, to: previousFileURL)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        defer {
            try? handle.close()
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Sem onde registrar a falha do próprio log; o os.Logger já recebeu a mensagem.
        }
    }
}
