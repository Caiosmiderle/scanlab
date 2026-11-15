import Foundation
import CoreGraphics
import ImageIO
import ScanCore

/// Decodifica um JPEG de keyframe para RGBA em memória.
enum ImageDecoder {
    /// - Parameter maxPixelSize: lado maior máximo da imagem decodificada. A foto original
    ///   tem 1920 x 1440; para cor por vértice (um ponto a cada poucos centímetros) uma
    ///   versão menor dá o mesmo resultado, decodifica mais rápido e ocupa menos memória.
    static func loadRGBA(url: URL, maxPixelSize: Int) -> RGBAImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Sem aplicar rotação: a imagem tem de continuar na orientação do sensor.
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            // Num contexto de bitmap, a primeira linha da memória é o topo da imagem.
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn {
            return nil
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
