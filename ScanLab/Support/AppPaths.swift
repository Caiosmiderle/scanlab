import Foundation

/// Caminhos do app. Tudo fica em Documents, que aparece no app Arquivos do iPad
/// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace no Info.plist).
enum AppPaths {
    static var documents: URL {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    static var scansRoot: URL {
        return documents.appendingPathComponent("Scans", isDirectory: true)
    }

    static var logsRoot: URL {
        return documents.appendingPathComponent("Logs", isDirectory: true)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Espaço livre no volume do app, em bytes. `nil` se o sistema não informar.
    static func freeDiskBytes() -> Int64? {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Soma do tamanho de todos os arquivos dentro de uma pasta.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Chaves do UserDefaults usadas em Ajustes.
enum SettingsKeys {
    /// Eixo "para cima" das exportações: valor bruto de `UpAxis` ("yUp" ou "zUp").
    static let exportUpAxis = "exportUpAxis"
}
