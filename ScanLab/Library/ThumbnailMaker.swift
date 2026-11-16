import Foundation
import CoreGraphics
import ImageIO
import ScanCore

/// Miniatura de um scan para a lista da biblioteca.
///
/// Usamos uma das fotos do próprio scan (a do meio da captura), reduzida. É barato,
/// não precisa renderizar o modelo 3D e deixa o scan reconhecível na lista.
enum ThumbnailMaker {
    static let fileName = "thumb.jpg"
    private static let maxPixelSize = 360

    /// Reduz `source` e grava como JPEG em `destination`. Devolve `false` se falhar.
    static func write(from source: URL, to destination: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return false
        }
        // "public.jpeg" é o identificador de tipo do JPEG.
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.jpeg" as CFString, 1, nil) else {
            return false
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        return CGImageDestinationFinalize(output)
    }

    /// Cria a miniatura do scan a partir do `frames.json`, se ainda não existir.
    /// Só mexe em arquivos: pode rodar em fila de background.
    static func ensureThumbnail(scanFolder: URL) {
        let destination = scanFolder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }
        guard let data = try? Data(contentsOf: scanFolder.appendingPathComponent("frames.json")),
              let frames = try? FramesFile.decode(data),
              !frames.frames.isEmpty else {
            return
        }
        let middle = frames.frames[frames.frames.count / 2]
        _ = write(from: scanFolder.appendingPathComponent(middle.imageFile), to: destination)
    }
}
