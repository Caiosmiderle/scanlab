import Foundation
import CoreGraphics
import ImageIO
import ScanCore

/// Perfil de textura do processamento (marco M7).
enum TextureProfile: String, CaseIterable, Identifiable {
    /// Sem atlas: os arquivos saem com cor por vértice.
    case off
    /// Atlas de 4096 px, fotos lidas em resolução reduzida.
    case fast
    /// Atlas de 8192 px, fotos em resolução cheia.
    case hd

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .off: return "Sem textura"
        case .fast: return "Rápido"
        case .hd: return "HD"
        }
    }

    var atlasSize: Int {
        switch self {
        case .off: return 0
        case .fast: return 4096
        case .hd: return 8192
        }
    }

    /// Lado maior das fotos ao decodificar. A foto original tem 1920 px.
    var decodeSize: Int {
        switch self {
        case .off: return 0
        case .fast: return 1280
        case .hd: return 1920
        }
    }
}

struct TexturedOutput {
    var mesh: TexturedMesh
    /// Imagem do atlas em JPEG.
    var jpeg: Data
    var report: TextureAtlasReport
}

/// Codifica uma imagem RGBA em JPEG.
enum ImageEncoder {
    static func jpeg(from image: RGBAImage, quality: Double) -> Data? {
        let data = Data(image.pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: image.width,
                                    height: image.height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

/// Gera o atlas de textura de um scan. Síncrono e pesado: chamar fora da thread principal.
enum TextureProcessor {
    /// Devolve `nil` se o scan não tem fotos ou se a imagem não pôde ser codificada.
    /// A malha precisa estar em Y-up, o mundo do ARKit.
    static func texturize(mesh: WorldMesh,
                          scanID: String,
                          profile: TextureProfile,
                          useOcclusion: Bool,
                          progress: @escaping (Double) -> Void) -> TexturedOutput? {
        if profile == .off {
            return nil
        }
        let store = ScanStore.shared
        let folder = store.directory(for: scanID)
        guard let data = try? Data(contentsOf: store.framesURL(for: scanID)),
              let framesFile = try? FramesFile.decode(data) else {
            return nil
        }

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

        var depthMaps: [DepthMap?] = []
        if useOcclusion {
            var loaded = 0
            for record in records {
                var map: DepthMap? = nil
                if let depthFile = record.depthFile,
                   let depthData = try? Data(contentsOf: folder.appendingPathComponent(depthFile)) {
                    map = try? DepthMapFile.decode(depthData)
                }
                if map != nil {
                    loaded += 1
                }
                depthMaps.append(map)
            }
            if loaded == 0 {
                depthMaps = []
            }
        }

        let started = Date()
        let options = TextureAtlasOptions(atlasSize: profile.atlasSize)
        let decodeSize = profile.decodeSize
        let result = TextureAtlasBuilder.build(mesh: mesh, cameras: cameras, depthMaps: depthMaps, options: options, imageProvider: { index in
            return ImageDecoder.loadRGBA(url: folder.appendingPathComponent(records[index].imageFile), maxPixelSize: decodeSize)
        }, progress: { fraction in
            progress(0.9 * fraction)
        })

        guard let jpeg = ImageEncoder.jpeg(from: result.atlas, quality: 0.85) else {
            AppLog.error(.processing, "Textura do scan \(scanID): não foi possível codificar o atlas em JPEG")
            return nil
        }
        progress(1.0)

        let seconds = Date().timeIntervalSince(started)
        let report = result.report
        AppLog.info(.processing, "Textura do scan \(scanID): perfil=\(profile.rawValue) atlas=\(profile.atlasSize) px recortes=\(report.chartCount) faces com textura=\(report.texturedFaces) sem textura=\(report.untexturedFaces) fotos usadas=\(report.camerasUsed) escala=\(String(format: "%.2f", report.scale)) jpeg=\(AppPaths.formatBytes(Int64(jpeg.count))) tempo=\(String(format: "%.1f", seconds))s")
        return TexturedOutput(mesh: result.mesh, jpeg: jpeg, report: report)
    }
}
