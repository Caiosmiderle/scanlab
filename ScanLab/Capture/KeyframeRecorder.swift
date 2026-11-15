import ARKit
import CoreImage
import ImageIO
import ScanCore

/// Salva keyframes (foto JPEG, pose da câmera e, opcionalmente, mapa de profundidade)
/// durante a captura, para colorir a malha depois.
///
/// Regras que este tipo garante (seção 6.4):
/// - Nada de imagem acumulada em memória: cada keyframe vai direto para o disco.
/// - O `CVPixelBuffer` de `capturedImage` vem de um conjunto pequeno de buffers que o
///   ARKit reutiliza. Segurar vários deles trava a câmera, então só existe UM trabalho
///   de gravação por vez; se a fila estiver ocupada, o quadro é descartado.
/// - Nunca guardamos o `ARFrame` inteiro, só o buffer de imagem, e só até virar JPEG.
///
/// `consider`, `finalize` e `discard` devem ser chamados na thread principal.
final class KeyframeRecorder {
    /// Pasta temporária desta captura, com `frames/` e `depth/` dentro.
    let directory: URL

    private(set) var records: [KeyframeRecord] = []
    private(set) var droppedCount = 0
    private(set) var failedCount = 0

    private var policy: KeyframePolicy
    private let saveDepth: Bool
    private let queue = DispatchQueue(label: "com.caio.scanlab.keyframes", qos: .userInitiated)
    private let ciContext = CIContext(options: nil)
    private let colorSpace: CGColorSpace
    private var isBusy = false
    private var nextIndex = 0
    private var loggedDepthFormat = false

    private static let jpegQuality: Double = 0.8

    init(settings: KeyframeSettings, saveDepth: Bool) throws {
        var adjusted = settings
        adjusted.maxCount = max(20, settings.maxCount)
        policy = KeyframePolicy(settings: adjusted)
        self.saveDepth = saveDepth
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        directory = AppPaths.captureRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try AppPaths.ensureDirectory(directory.appendingPathComponent("frames", isDirectory: true))
        try AppPaths.ensureDirectory(directory.appendingPathComponent("depth", isDirectory: true))
    }

    /// Apaga restos de capturas que não chegaram a ser finalizadas (app fechado à força).
    static func removeStaleCaptures() {
        try? FileManager.default.removeItem(at: AppPaths.captureRoot)
    }

    /// Avalia um quadro do ARKit e, se ele for um keyframe, grava em disco.
    func consider(_ frame: ARFrame) {
        let timestamp = frame.timestamp
        let transform = frame.camera.transform
        guard policy.shouldCapture(timestamp: timestamp, transform: transform) else {
            return
        }
        if isBusy {
            // A gravação anterior ainda não terminou: melhor perder este quadro do que
            // segurar mais um buffer da câmera.
            droppedCount += 1
            return
        }

        let index = nextIndex
        nextIndex += 1
        let imageFile = String(format: "frames/%06d.jpg", index)

        // A profundidade é pequena (256 x 192): copiamos já, aqui, e o buffer do ARKit
        // é liberado na hora.
        var depthMap: DepthMap? = nil
        var depthFile: String? = nil
        if saveDepth, let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth {
            depthMap = copyDepth(depthData)
            if depthMap != nil {
                depthFile = String(format: "depth/%06d.bin", index)
            }
        }

        let resolution = frame.camera.imageResolution
        let record = KeyframeRecord(index: index,
                                    timestamp: timestamp,
                                    transform: KeyframeRecord.array(from: transform),
                                    intrinsics: KeyframeRecord.array(from: frame.camera.intrinsics),
                                    imageWidth: Int(resolution.width),
                                    imageHeight: Int(resolution.height),
                                    imageFile: imageFile,
                                    depthFile: depthFile)
        policy.markCaptured(timestamp: timestamp, transform: transform)

        // Só o buffer da imagem atravessa para a fila, não o ARFrame.
        let pixelBuffer = frame.capturedImage
        let imageURL = directory.appendingPathComponent(imageFile)
        let depthURL = depthFile.map { directory.appendingPathComponent($0) }

        isBusy = true
        queue.async {
            let succeeded = self.write(pixelBuffer: pixelBuffer, imageURL: imageURL, depthMap: depthMap, depthURL: depthURL)
            DispatchQueue.main.async {
                self.isBusy = false
                if succeeded {
                    self.records.append(record)
                    self.thinIfNeeded()
                } else {
                    self.failedCount += 1
                }
            }
        }
    }

    /// Espera a gravação pendente terminar e entrega a lista final de keyframes.
    func finalize(completion: @escaping ([KeyframeRecord]) -> Void) {
        // A fila é serial e a principal é FIFO: este bloco só roda depois que o último
        // keyframe pendente tiver sido gravado e registrado.
        queue.async {
            DispatchQueue.main.async {
                completion(self.records)
            }
        }
    }

    /// Descarta tudo o que foi gravado (scan cancelado).
    func discard() {
        let folder = directory
        queue.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Interno

    /// Ao atingir o teto, mantém um keyframe sim, um não, e dobra os limiares de
    /// distância e ângulo. Assim um scan longo continua coberto do começo ao fim,
    /// só com keyframes mais espaçados, em vez de parar de registrar no meio.
    private func thinIfNeeded() {
        guard records.count >= policy.settings.maxCount else {
            return
        }
        var kept: [KeyframeRecord] = []
        var removed: [KeyframeRecord] = []
        for position in 0..<records.count {
            if position % 2 == 0 {
                kept.append(records[position])
            } else {
                removed.append(records[position])
            }
        }
        records = kept
        policy.relax()
        AppLog.info(.capture, "Teto de keyframes atingido: mantidos=\(kept.count) removidos=\(removed.count) novo limiar=\(policy.settings.minDistance) m / \(policy.settings.minAngleDegrees) graus")

        let folder = directory
        queue.async {
            for record in removed {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.imageFile))
                if let depthFile = record.depthFile {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(depthFile))
                }
            }
        }
    }

    /// Roda na fila de gravação.
    private func write(pixelBuffer: CVPixelBuffer, imageURL: URL, depthMap: DepthMap?, depthURL: URL?) -> Bool {
        do {
            // Sem rotação: o JPEG fica na orientação nativa do sensor, que é a mesma
            // das intrínsecas gravadas no frames.json.
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let options: [CIImageRepresentationOption: Any] = [qualityKey: KeyframeRecorder.jpegQuality]
            try ciContext.writeJPEGRepresentation(of: image, to: imageURL, colorSpace: colorSpace, options: options)

            if let depthMap = depthMap, let depthURL = depthURL {
                try DepthMapFile.encode(depthMap).write(to: depthURL)
            }
            return true
        } catch {
            AppLog.error(.capture, "Falha ao gravar keyframe \(imageURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Copia o mapa de profundidade (e a confiança) para vetores simples.
    private func copyDepth(_ depthData: ARDepthData) -> DepthMap? {
        let depthBuffer = depthData.depthMap
        let format = CVPixelBufferGetPixelFormatType(depthBuffer)
        guard format == kCVPixelFormatType_DepthFloat32 else {
            if !loggedDepthFormat {
                loggedDepthFormat = true
                AppLog.warning(.capture, "Formato de profundidade inesperado (\(format)); profundidade não será salva")
            }
            return nil
        }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        guard width > 0, height > 0 else {
            return nil
        }

        var meters = [Float](repeating: 0, count: width * height)
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(depthBuffer) {
            // As linhas do buffer podem ter bytes de preenchimento no fim: copiamos
            // linha a linha usando bytesPerRow.
            let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
            let rowBytes = width * MemoryLayout<Float>.size
            meters.withUnsafeMutableBytes { destination in
                if let target = destination.baseAddress {
                    for row in 0..<height {
                        memcpy(target.advanced(by: row * rowBytes), base.advanced(by: row * bytesPerRow), rowBytes)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)

        var confidence: [UInt8] = []
        if let confidenceBuffer = depthData.confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceBuffer) == width,
           CVPixelBufferGetHeight(confidenceBuffer) == height {
            var values = [UInt8](repeating: 0, count: width * height)
            CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(confidenceBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceBuffer)
                values.withUnsafeMutableBytes { destination in
                    if let target = destination.baseAddress {
                        for row in 0..<height {
                            memcpy(target.advanced(by: row * width), base.advanced(by: row * bytesPerRow), width)
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
            confidence = values
        }

        return DepthMap(width: width,
                        height: height,
                        depthMillimeters: DepthMap.millimeters(fromMeters: meters),
                        confidence: confidence)
    }
}
