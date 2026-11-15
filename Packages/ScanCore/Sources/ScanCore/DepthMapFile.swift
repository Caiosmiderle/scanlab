import Foundation

/// Mapa de profundidade de um keyframe, já em formato compacto.
public struct DepthMap: Equatable {
    public var width: Int
    public var height: Int
    /// Profundidade em milímetros, linha a linha. 0 = sem medida.
    public var depthMillimeters: [UInt16]
    /// Confiança do ARKit por pixel: 0 baixa, 1 média, 2 alta. Vazio se não houver.
    public var confidence: [UInt8]

    public init(width: Int, height: Int, depthMillimeters: [UInt16], confidence: [UInt8]) {
        self.width = width
        self.height = height
        self.depthMillimeters = depthMillimeters
        self.confidence = confidence
    }

    /// Converte metros (Float32 do ARKit) para milímetros em 16 bits.
    /// O LiDAR alcança cerca de 5 m, então 16 bits (até 65 m) sobram, e o arquivo
    /// fica com metade do tamanho do Float32 sem perder nada que o sensor mede.
    public static func millimeters(fromMeters meters: [Float]) -> [UInt16] {
        var result = [UInt16](repeating: 0, count: meters.count)
        for index in 0..<meters.count {
            let value = meters[index]
            if value.isFinite && value > 0 {
                let mm = (value * 1000).rounded()
                result[index] = mm >= 65535 ? 65535 : UInt16(mm)
            }
        }
        return result
    }

    /// Profundidade em metros no pixel (coluna, linha). `nil` se fora do mapa ou sem medida.
    public func meters(column: Int, row: Int) -> Float? {
        if column < 0 || row < 0 || column >= width || row >= height {
            return nil
        }
        let value = depthMillimeters[row * width + column]
        if value == 0 {
            return nil
        }
        return Float(value) / 1000
    }
}

/// Arquivo `depth/NNNNNN.bin`. Little-endian:
/// magic `SLDEPTH1`, `uint16 width`, `uint16 height`, `uint8 hasConfidence`,
/// `uint16[width*height]` profundidade em mm e, se houver, `uint8[width*height]` confiança.
public enum DepthMapFile {
    public static let magic = "SLDEPTH1"

    public static func encode(_ map: DepthMap) throws -> Data {
        let count = map.width * map.height
        guard map.width > 0, map.height > 0, map.width <= 65535, map.height <= 65535,
              map.depthMillimeters.count == count,
              map.confidence.isEmpty || map.confidence.count == count else {
            throw ScanCoreError.inconsistentMesh("mapa de profundidade com tamanho incompatível")
        }
        var buffer = ByteBuffer(capacity: 13 + count * 3)
        buffer.appendASCII(magic)
        buffer.appendUInt16(UInt16(map.width))
        buffer.appendUInt16(UInt16(map.height))
        buffer.appendUInt8(map.confidence.isEmpty ? 0 : 1)
        buffer.appendUInt16s(map.depthMillimeters)
        buffer.appendBytes(map.confidence)
        return buffer.data
    }

    public static func decode(_ data: Data) throws -> DepthMap {
        var reader = BinaryReader(data)
        guard try reader.readBytes(8) == Array(magic.utf8) else {
            throw ScanCoreError.invalidMagic
        }
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        let flags = try reader.readBytes(1)
        let count = width * height
        let depth = try reader.readUInt16s(count)
        var confidence: [UInt8] = []
        if flags[0] != 0 {
            confidence = try reader.readBytes(count)
        }
        return DepthMap(width: width, height: height, depthMillimeters: depth, confidence: confidence)
    }
}
