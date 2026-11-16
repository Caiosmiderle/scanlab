import Foundation
import ScanCore

struct ExportResult {
    var files: [URL]
    var seconds: Double
    var vertexCount: Int
    var faceCount: Int
    var cloudPointCount: Int
    /// Formatos que falharam, com o motivo. Os outros foram gerados normalmente.
    var failures: [String]
}

enum ExportError: Error, LocalizedError {
    case rawMeshMissing
    case emptyMesh
    case noFormatSelected
    case cancelled
    case usdzFailed

    var errorDescription: String? {
        switch self {
        case .rawMeshMissing:
            return "O arquivo bruto (mesh.bin) deste scan não foi encontrado."
        case .emptyMesh:
            return "A malha deste scan está vazia."
        case .noFormatSelected:
            return "Nenhum formato foi escolhido. Marque ao menos um nas opções de exportação."
        case .cancelled:
            return "Exportação cancelada."
        case .usdzFailed:
            return "O sistema não conseguiu gravar o arquivo USDZ."
        }
    }
}

/// Pedido de cancelamento compartilhado entre a interface e a fila de trabalho.
final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

/// Gera os arquivos de saída a partir do bruto (`mesh.bin`).
/// Função síncrona e pesada: chamar sempre fora da thread principal.
enum MeshExporter {
    /// - Parameter progress: fração de 0 a 1 e texto da etapa. Chamado na fila de trabalho.
    static func export(scanID: String,
                       options: ExportOptions,
                       cancel: CancelFlag,
                       progress: @escaping (Double, String) -> Void) throws -> ExportResult {
        let started = Date()
        let store = ScanStore.shared
        guard !options.formats.isEmpty else {
            throw ExportError.noFormatSelected
        }
        let rawURL = store.rawMeshURL(for: scanID)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            throw ExportError.rawMeshMissing
        }
        AppLog.info(.export, "Export do scan \(scanID) iniciado: \(options.summary)")

        // 1. Bruto → malha única no mundo.
        progress(0.02, "Lendo dados brutos...")
        let anchors = try RawMeshFile.read(contentsOf: rawURL)
        progress(0.06, "Montando a malha...")
        var mesh = MeshBuilder.worldMesh(from: anchors)

        // 2. Limpeza. O bruto fica como o sensor entregou; a limpeza acontece só na saída.
        let cleanup = mesh.removeUnusedAndInvalid()
        var cleanupNotes = "vértices soltos=\(cleanup.removedVertices) faces inválidas=\(cleanup.removedFaces) normais refeitas=\(cleanup.repairedNormals)"
        if options.weld {
            let welded = mesh.weldVertices()
            cleanupNotes += " vértices soldados=\(welded)"
        }
        if options.removeSmallComponents {
            let report = mesh.removeSmallComponents(minFaces: ExportOptions.smallComponentFaces)
            cleanupNotes += " pedaços=\(report.componentCount) pedaços removidos=\(report.removedComponents) (\(report.removedFaces) faces)"
        }
        AppLog.info(.export, "Limpeza do scan \(scanID): \(cleanupNotes)")
        guard mesh.faceCount > 0 else {
            throw ExportError.emptyMesh
        }
        try check(cancel)

        // 3. Cor por vértice. Tem de acontecer ANTES da troca de eixo: as poses das
        // câmeras estão no mundo do ARKit (Y-up), o mesmo da malha neste ponto.
        var colored = false
        if options.colorize {
            progress(0.10, "Colorindo a malha...")
            let report = ColorProcessor.colorize(mesh: &mesh, scanID: scanID, useOcclusion: options.useOcclusion) { fraction in
                progress(0.10 + 0.38 * fraction, "Colorindo a malha...")
            }
            colored = report != nil
        }
        try check(cancel)

        let outputs = store.outputsDirectory(for: scanID)
        try AppPaths.ensureDirectory(outputs)
        let axisSuffix = (options.axis == .zUp) ? "zup" : "yup"
        let base = "scan-\(scanID)"

        // Cada formato ocupa uma fatia igual do progresso entre 0,50 e 0,98.
        let ordered = ExportFormat.allCases.filter { options.formats.contains($0) }
        let slice = 0.48 / Double(max(1, ordered.count))
        var done = 0
        var files: [URL] = []
        var failures: [String] = []

        func report(_ format: ExportFormat, _ fraction: Double) {
            progress(0.50 + slice * (Double(done) + fraction), "Gravando \(format.title)...")
        }

        /// Roda um formato. Se ele falhar, registra e segue para os outros: um formato
        /// com problema não pode impedir os demais de saírem.
        func run(_ format: ExportFormat, _ urls: [URL], _ body: () throws -> Void) throws {
            guard options.formats.contains(format) else {
                return
            }
            try check(cancel)
            report(format, 0)
            do {
                try body()
                files.append(contentsOf: urls)
            } catch {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
                failures.append("\(format.title): \(error.localizedDescription)")
                AppLog.error(.export, "Formato \(format.rawValue) falhou no scan \(scanID): \(error.localizedDescription)")
            }
            done += 1
        }

        // 4. Formatos que são sempre Y-up (glTF e USD definem o eixo no próprio padrão).
        let glbURL = outputs.appendingPathComponent(base + ".glb")
        try run(.glb, [glbURL]) {
            let sink = try FileSink(url: glbURL)
            try GLTFWriter.writeGLB(mesh, to: sink) { report(.glb, $0) }
            try sink.close()
        }

        let gltfURL = outputs.appendingPathComponent(base + ".gltf")
        let binURL = outputs.appendingPathComponent(base + ".bin")
        try run(.gltf, [gltfURL, binURL]) {
            let jsonSink = try FileSink(url: gltfURL)
            let binarySink = try FileSink(url: binURL)
            try GLTFWriter.writeGLTF(mesh, json: jsonSink, binary: binarySink, binaryFileName: binURL.lastPathComponent) { report(.gltf, $0) }
            try jsonSink.close()
            try binarySink.close()
        }

        let usdzURL = outputs.appendingPathComponent(base + ".usdz")
        try run(.usdz, [usdzURL]) {
            try USDZExporter.write(mesh, to: usdzURL)
        }

        // 5. Nuvem de pontos (montada em Y-up, convertida junto com a malha).
        var cloud = PointCloud(positions: [])
        let wantsCloud = ordered.contains { $0.isCloud }
        if wantsCloud {
            try check(cancel)
            if let spacing = options.cloudDensity.spacing {
                progress(0.50 + slice * Double(done), "Gerando nuvem densa...")
                cloud = PointCloudBuilder.sampleSurface(mesh, spacing: spacing)
            } else {
                cloud = PointCloudBuilder.fromVertices(mesh)
            }
            AppLog.info(.export, "Nuvem do scan \(scanID): densidade=\(options.cloudDensity.rawValue) pontos=\(cloud.count)")
        }

        // 6. Troca de eixo para os formatos em que o eixo é escolha do usuário.
        mesh.applyAxis(options.axis)
        cloud.applyAxis(options.axis)

        let plyURL = outputs.appendingPathComponent("\(base)-\(axisSuffix).ply")
        try run(.plyMesh, [plyURL]) {
            let sink = try FileSink(url: plyURL)
            try PLYWriter.writeMesh(mesh, to: sink) { report(.plyMesh, $0) }
            try sink.close()
        }

        let objURL = outputs.appendingPathComponent("\(base)-\(axisSuffix).obj")
        let mtlURL = outputs.appendingPathComponent("\(base)-\(axisSuffix).mtl")
        try run(.obj, [objURL, mtlURL]) {
            let sink = try FileSink(url: objURL)
            try OBJWriter.write(mesh, to: sink, materialLibraryName: mtlURL.lastPathComponent) { report(.obj, $0) }
            try sink.close()
            try Data(OBJWriter.materialFileContents().utf8).write(to: mtlURL, options: .atomic)
        }

        let stlURL = outputs.appendingPathComponent("\(base)-\(axisSuffix).stl")
        try run(.stl, [stlURL]) {
            let sink = try FileSink(url: stlURL)
            try STLWriter.write(mesh, to: sink) { report(.stl, $0) }
            try sink.close()
        }

        let daeURL = outputs.appendingPathComponent("\(base)-\(axisSuffix).dae")
        try run(.dae, [daeURL]) {
            let sink = try FileSink(url: daeURL)
            try DAEWriter.write(mesh, upAxis: options.axis, to: sink) { report(.dae, $0) }
            try sink.close()
        }

        let cloudBase = "\(base)-nuvem-\(axisSuffix)"
        let cloudPLYURL = outputs.appendingPathComponent(cloudBase + ".ply")
        try run(.plyCloud, [cloudPLYURL]) {
            let sink = try FileSink(url: cloudPLYURL)
            try CloudWriters.writePLY(cloud, to: sink) { report(.plyCloud, $0) }
            try sink.close()
        }

        let lasURL = outputs.appendingPathComponent(cloudBase + ".las")
        try run(.las, [lasURL]) {
            let sink = try FileSink(url: lasURL)
            try LASWriter.write(cloud, to: sink) { report(.las, $0) }
            try sink.close()
        }

        let ptsURL = outputs.appendingPathComponent(cloudBase + ".pts")
        try run(.pts, [ptsURL]) {
            let sink = try FileSink(url: ptsURL)
            try CloudWriters.writePTS(cloud, to: sink) { report(.pts, $0) }
            try sink.close()
        }

        let xyzURL = outputs.appendingPathComponent(cloudBase + ".xyz")
        try run(.xyz, [xyzURL]) {
            let sink = try FileSink(url: xyzURL)
            try CloudWriters.writeXYZ(cloud, to: sink) { report(.xyz, $0) }
            try sink.close()
        }

        let pcdURL = outputs.appendingPathComponent(cloudBase + ".pcd")
        try run(.pcdBinary, [pcdURL]) {
            let sink = try FileSink(url: pcdURL)
            try CloudWriters.writePCD(cloud, binary: true, to: sink) { report(.pcdBinary, $0) }
            try sink.close()
        }

        let pcdAsciiURL = outputs.appendingPathComponent(cloudBase + "-texto.pcd")
        try run(.pcdAscii, [pcdAsciiURL]) {
            let sink = try FileSink(url: pcdAsciiURL)
            try CloudWriters.writePCD(cloud, binary: false, to: sink) { report(.pcdAscii, $0) }
            try sink.close()
        }

        // 7. Registra no meta.json que o scan foi processado e com quais parâmetros.
        if var meta = store.loadMeta(id: scanID) {
            meta.status = "processado"
            meta.lastExport = options.summary
            try? store.saveMeta(meta)
        }

        let seconds = Date().timeIntervalSince(started)
        var sizes: [String] = []
        for file in files {
            sizes.append("\(file.pathExtension)=\(AppPaths.formatBytes(AppPaths.fileSize(file)))")
        }
        AppLog.info(.export, "Export do scan \(scanID) concluído: cor=\(colored ? "sim" : "não") vértices=\(mesh.vertexCount) faces=\(mesh.faceCount) pontos da nuvem=\(cloud.count) arquivos: \(sizes.joined(separator: " ")) falhas=\(failures.count) tempo=\(String(format: "%.1f", seconds))s")

        progress(1.0, "Concluído")
        return ExportResult(files: files,
                            seconds: seconds,
                            vertexCount: mesh.vertexCount,
                            faceCount: mesh.faceCount,
                            cloudPointCount: cloud.count,
                            failures: failures)
    }

    private static func check(_ cancel: CancelFlag) throws {
        if cancel.isCancelled {
            throw ExportError.cancelled
        }
    }
}
