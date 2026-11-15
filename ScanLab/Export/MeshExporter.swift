import Foundation
import ScanCore

struct ExportResult {
    var files: [URL]
    var seconds: Double
    var vertexCount: Int
    var faceCount: Int
}

enum ExportError: Error, LocalizedError {
    case rawMeshMissing
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .rawMeshMissing:
            return "O arquivo bruto (mesh.bin) deste scan não foi encontrado."
        case .emptyMesh:
            return "A malha deste scan está vazia."
        }
    }
}

/// Gera os arquivos de saída a partir do bruto (`mesh.bin`).
/// Função síncrona e pesada: chamar sempre fora da thread principal.
enum MeshExporter {
    /// Gera PLY binário, OBJ e MTL em `outputs/`.
    /// - Parameter progress: fração de 0 a 1 e texto da etapa. Chamado na fila de trabalho.
    static func exportPLYAndOBJ(scanID: String,
                                axis: UpAxis,
                                colorize: Bool,
                                progress: @escaping (Double, String) -> Void) throws -> ExportResult {
        let started = Date()
        let store = ScanStore.shared
        let rawURL = store.rawMeshURL(for: scanID)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            throw ExportError.rawMeshMissing
        }

        progress(0.02, "Lendo dados brutos...")
        let anchors = try RawMeshFile.read(contentsOf: rawURL)

        progress(0.10, "Montando a malha...")
        var mesh = MeshBuilder.worldMesh(from: anchors)
        // O bruto fica como o sensor entregou; a limpeza acontece só na saída.
        let cleanup = mesh.removeUnusedAndInvalid()
        if cleanup.changedSomething {
            AppLog.info(.export, "Limpeza do scan \(scanID): vértices soltos removidos=\(cleanup.removedVertices) faces inválidas removidas=\(cleanup.removedFaces) normais refeitas=\(cleanup.repairedNormals)")
        }
        guard mesh.faceCount > 0 else {
            throw ExportError.emptyMesh
        }

        // Cor por vértice. Tem de acontecer ANTES da troca de eixo: as poses das
        // câmeras estão no mundo do ARKit (Y-up), o mesmo da malha neste ponto.
        var colored = false
        if colorize {
            progress(0.12, "Colorindo a malha...")
            let report = ColorProcessor.colorize(mesh: &mesh, scanID: scanID) { fraction in
                progress(0.12 + 0.43 * fraction, "Colorindo a malha...")
            }
            colored = report != nil
        }

        mesh.applyAxis(axis)

        let outputs = store.outputsDirectory(for: scanID)
        try AppPaths.ensureDirectory(outputs)

        let axisSuffix = (axis == .zUp) ? "zup" : "yup"
        let baseName = "scan-\(scanID)-\(axisSuffix)"
        let plyURL = outputs.appendingPathComponent(baseName + ".ply")
        let objURL = outputs.appendingPathComponent(baseName + ".obj")
        let mtlURL = outputs.appendingPathComponent(baseName + ".mtl")

        do {
            let plySink = try FileSink(url: plyURL)
            try PLYWriter.writeMesh(mesh, to: plySink) { fraction in
                progress(0.56 + 0.14 * fraction, "Gravando PLY...")
            }
            try plySink.close()

            let objSink = try FileSink(url: objURL)
            try OBJWriter.write(mesh, to: objSink, materialLibraryName: mtlURL.lastPathComponent) { fraction in
                progress(0.70 + 0.28 * fraction, "Gravando OBJ...")
            }
            try objSink.close()

            try Data(OBJWriter.materialFileContents().utf8).write(to: mtlURL, options: .atomic)
        } catch {
            // Arquivo pela metade engana quem abre no computador: melhor não deixar.
            try? FileManager.default.removeItem(at: plyURL)
            try? FileManager.default.removeItem(at: objURL)
            try? FileManager.default.removeItem(at: mtlURL)
            throw error
        }

        let seconds = Date().timeIntervalSince(started)
        let plySize = AppPaths.formatBytes(AppPaths.fileSize(plyURL))
        let objSize = AppPaths.formatBytes(AppPaths.fileSize(objURL))
        AppLog.info(.export, "Export do scan \(scanID): eixo=\(axis.rawValue) cor=\(colored ? "sim" : "não") vértices=\(mesh.vertexCount) faces=\(mesh.faceCount) ply=\(plySize) obj=\(objSize) tempo=\(String(format: "%.1f", seconds))s")

        progress(1.0, "Concluído")
        return ExportResult(files: [plyURL, objURL, mtlURL],
                            seconds: seconds,
                            vertexCount: mesh.vertexCount,
                            faceCount: mesh.faceCount)
    }
}
