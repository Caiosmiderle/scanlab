import Foundation
import ScanCore

/// Colore a malha de um scan usando os keyframes salvos (marco M2A).
/// Síncrono e pesado: chamar fora da thread principal.
enum ColorProcessor {
    /// Lado maior das fotos decodificadas para amostrar a cor.
    private static let decodeSize = 1280

    /// Devolve `nil` se o scan não tiver keyframes (scans feitos antes do M2).
    /// A malha precisa estar em Y-up, o mundo do ARKit.
    static func colorize(mesh: inout WorldMesh, scanID: String, progress: @escaping (Double) -> Void) -> ColorizeReport? {
        let store = ScanStore.shared
        let folder = store.directory(for: scanID)
        guard let data = try? Data(contentsOf: store.framesURL(for: scanID)),
              let framesFile = try? FramesFile.decode(data) else {
            return nil
        }

        // Câmeras e registros ficam em vetores paralelos (mesmo índice).
        var cameras: [CameraModel] = []
        var records: [KeyframeRecord] = []
        for record in framesFile.frames {
            if let camera = CameraModel(record: record) {
                cameras.append(camera)
                records.append(record)
            }
        }
        if cameras.isEmpty {
            return nil
        }

        let started = Date()
        var missingImages = 0
        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras, imageProvider: { index in
            let url = folder.appendingPathComponent(records[index].imageFile)
            let image = ImageDecoder.loadRGBA(url: url, maxPixelSize: decodeSize)
            if image == nil {
                missingImages += 1
            }
            return image
        }, progress: progress)

        let seconds = Date().timeIntervalSince(started)
        AppLog.info(.processing, "Coloração do scan \(scanID): keyframes=\(cameras.count) usados=\(report.framesUsed) vértices coloridos=\(report.coloredDirectly) preenchidos pelos vizinhos=\(report.filledFromNeighbors) sem cor=\(report.uncolored) imagens ilegíveis=\(missingImages) tempo=\(String(format: "%.1f", seconds))s")
        return report
    }
}
