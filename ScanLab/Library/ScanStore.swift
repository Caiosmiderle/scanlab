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
    /// Tipo do item: `ScanKind.mesh` (malha LiDAR) ou `ScanKind.room` (RoomPlan).
    /// Opcional: itens antigos não têm o campo e são malha.
    var kind: String?
    /// Resumo dos cômodos de um item do RoomPlan.
    var rooms: [RoomSummary]?
    /// Parâmetros da última exportação (formatos, eixo, limpeza...).
    var lastExport: String?

    var isRoomScan: Bool {
        return kind == ScanKind.room
    }
}

enum ScanKind {
    static let mesh = "malha"
    static let room = "comodo"
}

/// Medidas aproximadas de um cômodo capturado com o RoomPlan.
struct RoomSummary: Codable, Equatable {
    var name: String
    /// m²; `nil` se o contorno do cômodo não fechou.
    var area: Double?
    /// Soma do comprimento das paredes, em metros.
    var perimeter: Double
    /// Pé-direito aproximado (média da altura das paredes), em metros.
    var ceilingHeight: Double?
    var wallCount: Int
    var doorCount: Int
    var windowCount: Int
}

enum ScanStoreError: Error, LocalizedError {
    case emptyScan
    case scanNotFound

    var errorDescription: String? {
        switch self {
        case .emptyScan:
            return "O LiDAR não gerou malha neste scan, então não há o que salvar. Confira se o sensor LiDAR (ao lado das câmeras) não estava coberto pela mão ou pela capa e tente de novo."
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
    /// Tamanho em disco de cada item, por identificador.
    @Published private(set) var sizes: [String: Int64] = [:]

    private init() {}

    func thumbnailURL(for id: String) -> URL {
        return directory(for: id).appendingPathComponent(ThumbnailMaker.fileName)
    }

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

        // Tamanhos e miniaturas exigem percorrer as pastas (centenas de fotos por
        // scan), então saem da thread principal e chegam um instante depois.
        let ids = loaded.map { $0.id }
        DispatchQueue.global(qos: .utility).async {
            var measured: [String: Int64] = [:]
            for id in ids {
                let folder = self.directory(for: id)
                ThumbnailMaker.ensureThumbnail(scanFolder: folder)
                measured[id] = AppPaths.directorySize(folder)
            }
            DispatchQueue.main.async {
                self.sizes = measured
            }
        }
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

    /// Cria uma pasta de scan vazia (com `outputs/`) e devolve o identificador.
    /// Usado pelo RoomPlan, que grava os próprios arquivos e depois o `meta.json`.
    /// Enquanto o `meta.json` não existir, a pasta não aparece na biblioteca.
    func prepareScanFolder() throws -> String {
        let id = makeUniqueID(for: Date())
        try AppPaths.ensureDirectory(directory(for: id))
        try AppPaths.ensureDirectory(outputsDirectory(for: id))
        return id
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
