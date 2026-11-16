import Foundation
import ScanCore

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

    /// Pasta das capturas em andamento. Fica FORA de Documents de propósito: não aparece
    /// no app Arquivos e, diferente da pasta temporária, o sistema não a limpa sozinho.
    /// Ao finalizar o scan, o conteúdo é movido para `Documents/Scans/<id>/`.
    static var captureRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CaptureInProgress", isDirectory: true)
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
    /// Colorir a malha com os keyframes ao exportar.
    static let colorizeOnExport = "colorizeOnExport"
    /// Usar o mapa de profundidade para descartar fotos que não enxergam o vértice.
    static let useOcclusion = "useOcclusion"
    /// Salvar o mapa de profundidade junto de cada keyframe.
    static let saveDepth = "saveDepth"
    static let keyframeInterval = "keyframeInterval"
    static let keyframeDistanceCm = "keyframeDistanceCm"
    static let keyframeAngle = "keyframeAngle"
    static let keyframeMaxCount = "keyframeMaxCount"
    /// Formatos marcados para exportar: nomes de `ExportFormat` separados por vírgula.
    static let exportFormats = "exportFormats"
    /// Valor bruto de `CloudDensity`.
    static let cloudDensity = "cloudDensity"
    static let weldVertices = "weldVertices"
    static let removeSmallComponents = "removeSmallComponents"
}

/// Leitura dos ajustes com os valores padrão da especificação.
enum AppSettings {
    static let defaultKeyframeInterval: Double = 0.4
    static let defaultKeyframeDistanceCm: Double = 15
    static let defaultKeyframeAngle: Double = 15
    static let defaultKeyframeMaxCount: Double = 400

    private static func double(_ key: String, _ fallback: Double) -> Double {
        // object(forKey:) devolve nil quando o usuário nunca mexeu no ajuste.
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return fallback
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return fallback
    }

    static var keyframeSettings: KeyframeSettings {
        return KeyframeSettings(minInterval: double(SettingsKeys.keyframeInterval, defaultKeyframeInterval),
                                minDistance: Float(double(SettingsKeys.keyframeDistanceCm, defaultKeyframeDistanceCm) / 100),
                                minAngleDegrees: Float(double(SettingsKeys.keyframeAngle, defaultKeyframeAngle)),
                                maxCount: Int(double(SettingsKeys.keyframeMaxCount, defaultKeyframeMaxCount)))
    }

    static var saveDepth: Bool {
        return bool(SettingsKeys.saveDepth, true)
    }

    static var colorizeOnExport: Bool {
        return bool(SettingsKeys.colorizeOnExport, true)
    }

    static var useOcclusion: Bool {
        return bool(SettingsKeys.useOcclusion, true)
    }
}
