import Foundation
import ScanCore

/// Conteúdo do `meta.json` de cada scan.
struct ScanMeta: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    var deviceModel: String
    var systemVersion: String
    var appVersion: String
    var durationSeconds: Double
    var anchorCount: Int
    var vertexCount: Int
    var faceCount: Int
    /// "meshWithClassification" ou "mesh".
    var reconstructionMode: String
    /// "bruto" ou "processado".
    var status: String
    /// Quantos keyframes foram salvos. Opcional: scans feitos antes do M2 não têm o campo.
    var keyframeCount: Int?
}

enum ScanStoreError: Error, LocalizedError {
    case emptyScan
    case scanNotFound

    var errorDescription: String? {
        switch self {
        case .emptyScan:
            return "Nenhuma malha foi capturada. Escaneie por mais tempo antes de finalizar."
        case .scanNotFound:
            return "Scan não encontrado no aparelho."
        }
    }
}

/// Guarda os scans em `Documents/Scans/<id>/`:
/// `meta.json`, `mesh.bin` (bruto, nunca sobrescrito) e `outputs/` (arquivos gerados).
final class ScanStore: ObservableObject {
    static let shared = ScanStore()

    @Published private(set) var scans: [ScanMeta] = []

    private init() {}

    // MARK: - Caminhos

    func directory(for id: String) -> URL {
        return AppPaths.scansRoot.appendingPathComponent(id, isDirectory: true)
    }

    func outputsDirectory(for id: String) -> URL {
        return directory(for: id).appendingPathComponent("outputs", isDirectory: true)
    }

    func rawMeshURL(for id: String) -> URL {
        return directory(for: id).appendingPathComponent("mesh.bin")
    }

    func metaURL(for id: String) -> URL {
        return directory(for: id).appendingPathComponent("meta.json")
    }

    func framesURL(for id: String) -> URL {
        return directory(for: id).appendingPathComponent("frames.json")
    }

    // MARK: - Leitura (chamar na thread principal)

    /// Relê a pasta de scans do disco e atualiza a lista publicada.
    func reload() {
        let fileManager = FileManager.default
        var loaded: [ScanMeta] = []
        let folders = (try? fileManager.contentsOfDirectory(at: AppPaths.scansRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let meta = loadMeta(id: folder.lastPathComponent) {
                loaded.append(meta)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        scans = loaded
    }

    func loadMeta(id: String) -> ScanMeta? {
        guard let data = try? Data(contentsOf: metaURL(for: id)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanMeta.self, from: data)
    }

    /// Arquivos gerados em `outputs/`, em ordem alfabética.
    func outputFiles(for id: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outputsDirectory(for: id), includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func diskSize(of id: String) -> Int64 {
        return AppPaths.directorySize(directory(for: id))
    }

    // MARK: - Escrita

    /// Cria a pasta do scan e grava `mesh.bin`, `meta.json` e, se houver keyframes,
    /// move `frames/` e `depth/` da pasta de captura e grava o `frames.json`.
    /// Só mexe em arquivos (não na lista publicada), então pode rodar em fila de background.
    func createScan(anchors: [MeshAnchorData],
                    durationSeconds: Double,
                    reconstructionMode: String,
                    captureDirectory: URL?,
                    keyframes: [KeyframeRecord]) throws -> ScanMeta {
        var vertexCount = 0
        var faceCount = 0
        for anchor in anchors {
            vertexCount += anchor.vertexCount
            faceCount += anchor.faceCount
        }
        guard faceCount > 0 else {
            throw ScanStoreError.emptyScan
        }

        let now = Date()
        let id = makeUniqueID(for: now)
        let folder = directory(for: id)

        do {
            try AppPaths.ensureDirectory(folder)
            try AppPaths.ensureDirectory(outputsDirectory(for: id))

            let sink = try FileSink(url: rawMeshURL(for: id))
            try RawMeshFile.write(anchors: anchors, to: sink)
            try sink.close()

            // Keyframes: mover (não copiar) da pasta de captura. No mesmo volume isso é
            // só uma troca de nome, instantânea mesmo com centenas de megabytes.
            var keyframeCount = 0
            if let captureDirectory = captureDirectory, !keyframes.isEmpty {
                let fileManager = FileManager.default
                for name in ["frames", "depth"] {
                    let source = captureDirectory.appendingPathComponent(name, isDirectory: true)
                    if fileManager.fileExists(atPath: source.path) {
                        try fileManager.moveItem(at: source, to: folder.appendingPathComponent(name, isDirectory: true))
                    }
                }
                try FramesFile(frames: keyframes).encoded().write(to: framesURL(for: id), options: .atomic)
                keyframeCount = keyframes.count
            }
            if let captureDirectory = captureDirectory {
                try? FileManager.default.removeItem(at: captureDirectory)
            }

            let nameFormatter = DateFormatter()
            nameFormatter.locale = Locale(identifier: "pt_BR")
            nameFormatter.dateFormat = "dd/MM/yyyy HH:mm"

            let meta = ScanMeta(id: id,
                                name: "Scan \(nameFormatter.string(from: now))",
                                createdAt: now,
                                deviceModel: DeviceInfo.modelIdentifier,
                                systemVersion: DeviceInfo.systemVersion,
                                appVersion: AppInfo.versionText,
                                durationSeconds: durationSeconds,
                                anchorCount: anchors.count,
                                vertexCount: vertexCount,
                                faceCount: faceCount,
                                reconstructionMode: reconstructionMode,
                                status: "bruto",
                                keyframeCount: keyframeCount)
            try saveMeta(meta)
            return meta
        } catch {
            // Não deixa uma pasta pela metade aparecendo na biblioteca.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func saveMeta(_ meta: ScanMeta) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: metaURL(for: meta.id), options: .atomic)
    }

    /// Renomeia o scan (chamar na thread principal).
    func rename(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var meta = loadMeta(id: id) else {
            return
        }
        meta.name = trimmed
        do {
            try saveMeta(meta)
            AppLog.info(.app, "Scan \(id) renomeado para \"\(trimmed)\"")
        } catch {
            AppLog.error(.app, "Falha ao renomear o scan \(id): \(error.localizedDescription)")
        }
        reload()
    }

    /// Apaga a pasta inteira do scan (chamar na thread principal).
    func delete(id: String) {
        do {
            try FileManager.default.removeItem(at: directory(for: id))
            AppLog.info(.app, "Scan \(id) apagado")
        } catch {
            AppLog.error(.app, "Falha ao apagar o scan \(id): \(error.localizedDescription)")
        }
        reload()
    }

    // MARK: - Interno

    /// Identificador legível e ordenável, por exemplo "20261115-173012".
    private func makeUniqueID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: date)

        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory(for: candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
