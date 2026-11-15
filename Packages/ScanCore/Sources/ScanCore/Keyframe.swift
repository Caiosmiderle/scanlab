import Foundation
import simd

/// Um keyframe salvo durante a captura: a foto e a pose da câmera naquele instante.
public struct KeyframeRecord: Codable, Equatable {
    public var index: Int
    /// `ARFrame.timestamp`, em segundos.
    public var timestamp: Double
    /// `ARCamera.transform` (câmera → mundo), 16 floats por colunas.
    public var transform: [Float]
    /// `ARCamera.intrinsics`, 9 floats por colunas: [fx 0 0] [0 fy 0] [cx cy 1].
    public var intrinsics: [Float]
    /// `ARCamera.imageResolution`: tamanho, em pixels, da imagem a que as intrínsecas se referem.
    public var imageWidth: Int
    public var imageHeight: Int
    /// Caminho relativo à pasta do scan, por exemplo "frames/000012.jpg".
    public var imageFile: String
    /// Caminho relativo do mapa de profundidade, se foi salvo.
    public var depthFile: String?

    public init(index: Int,
                timestamp: Double,
                transform: [Float],
                intrinsics: [Float],
                imageWidth: Int,
                imageHeight: Int,
                imageFile: String,
                depthFile: String?) {
        self.index = index
        self.timestamp = timestamp
        self.transform = transform
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageFile = imageFile
        self.depthFile = depthFile
    }

    public static func array(from matrix: simd_float4x4) -> [Float] {
        return RawMeshFile.transformToArray(matrix)
    }

    public static func array(from matrix: simd_float3x3) -> [Float] {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2
        return [c0.x, c0.y, c0.z,
                c1.x, c1.y, c1.z,
                c2.x, c2.y, c2.z]
    }
}

/// Conteúdo do `frames.json` de um scan.
public struct FramesFile: Codable, Equatable {
    public var version: Int
    public var frames: [KeyframeRecord]

    public init(frames: [KeyframeRecord]) {
        self.version = 1
        self.frames = frames
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FramesFile {
        return try JSONDecoder().decode(FramesFile.self, from: data)
    }
}

/// Limiares para decidir quando salvar um keyframe (ajustáveis em Ajustes).
public struct KeyframeSettings: Equatable {
    /// Tempo mínimo desde o último keyframe, em segundos.
    public var minInterval: Double
    /// Deslocamento mínimo da câmera, em metros.
    public var minDistance: Float
    /// Rotação mínima da câmera, em graus.
    public var minAngleDegrees: Float
    /// Teto de keyframes por scan.
    public var maxCount: Int

    public init(minInterval: Double = 0.4, minDistance: Float = 0.15, minAngleDegrees: Float = 15, maxCount: Int = 400) {
        self.minInterval = minInterval
        self.minDistance = minDistance
        self.minAngleDegrees = minAngleDegrees
        self.maxCount = maxCount
    }
}

/// Decide se um quadro vira keyframe: pelo menos `minInterval` desde o último E
/// (a câmera andou mais que `minDistance` OU girou mais que `minAngleDegrees`).
public struct KeyframePolicy {
    public private(set) var settings: KeyframeSettings
    private var lastTimestamp: Double?
    private var lastTransform: simd_float4x4 = matrix_identity_float4x4

    public init(settings: KeyframeSettings) {
        self.settings = settings
    }

    public func shouldCapture(timestamp: Double, transform: simd_float4x4) -> Bool {
        guard let last = lastTimestamp else {
            // Primeiro quadro do scan: sempre entra.
            return true
        }
        if timestamp - last < settings.minInterval {
            return false
        }
        if KeyframePolicy.distance(lastTransform, transform) > settings.minDistance {
            return true
        }
        return KeyframePolicy.angleDegrees(lastTransform, transform) > settings.minAngleDegrees
    }

    /// Registra que o quadro foi de fato salvo.
    public mutating func markCaptured(timestamp: Double, transform: simd_float4x4) {
        lastTimestamp = timestamp
        lastTransform = transform
    }

    /// Dobra os limiares de distância e ângulo. Chamado quando o scan atinge o teto de
    /// keyframes: os próximos passam a ser mais espaçados.
    public mutating func relax() {
        settings.minDistance *= 2
        settings.minAngleDegrees = min(settings.minAngleDegrees * 2, 90)
    }

    static func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb)
    }

    /// Ângulo da rotação que leva a orientação `a` até a `b`.
    /// Para matrizes de rotação, traço(Aᵀ·B) = 1 + 2·cos(ângulo).
    static func angleDegrees(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        var trace: Float = 0
        trace += simd_dot(rotationColumn(a, 0), rotationColumn(b, 0))
        trace += simd_dot(rotationColumn(a, 1), rotationColumn(b, 1))
        trace += simd_dot(rotationColumn(a, 2), rotationColumn(b, 2))
        let cosine = max(-1, min(1, (trace - 1) / 2))
        return acos(cosine) * 180 / Float.pi
    }

    private static func rotationColumn(_ m: simd_float4x4, _ index: Int) -> SIMD3<Float> {
        let column = m[index]
        return SIMD3<Float>(column.x, column.y, column.z)
    }
}
