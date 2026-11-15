import Foundation
import simd
@testable import ScanCore

/// Malhas pequenas e conhecidas, usadas por vários testes.
enum TestMeshes {
    /// Um triângulo no plano XY local, com normal +Z.
    static func triangleAnchor(transform: simd_float4x4 = matrix_identity_float4x4,
                               classification: UInt8 = 1) -> MeshAnchorData {
        return MeshAnchorData(id: UUID(),
                              transform: transform,
                              positions: [0, 0, 0,
                                          1, 0, 0,
                                          0, 1, 0],
                              normals: [0, 0, 1,
                                        0, 0, 1,
                                        0, 0, 1],
                              indices: [0, 1, 2],
                              classifications: [classification])
    }

    /// Um quadrado (dois triângulos) no plano XZ local, com normal +Y.
    static func quadAnchor(transform: simd_float4x4 = matrix_identity_float4x4) -> MeshAnchorData {
        return MeshAnchorData(id: UUID(),
                              transform: transform,
                              positions: [0, 0, 0,
                                          1, 0, 0,
                                          1, 0, 1,
                                          0, 0, 1],
                              normals: [0, 1, 0,
                                        0, 1, 0,
                                        0, 1, 0,
                                        0, 1, 0],
                              indices: [0, 2, 1,
                                        0, 3, 2],
                              classifications: [2, 2])
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(x, y, z, 1)
        return matrix
    }

    /// Rotação de +90 graus em torno de Y, seguida de translação.
    /// Leva o eixo local +X para -Z do mundo e o local +Z para +X do mundo.
    static func rotationY90(translation t: SIMD3<Float>) -> simd_float4x4 {
        let c0 = SIMD4<Float>(0, 0, -1, 0)
        let c1 = SIMD4<Float>(0, 1, 0, 0)
        let c2 = SIMD4<Float>(1, 0, 0, 0)
        let c3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    /// Lê um float32 little-endian de dentro de um Data.
    static func float(in data: Data, at offset: Int) -> Float {
        let bytes = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: bits)
    }

    /// Lê um int32 little-endian de dentro de um Data.
    static func int32(in data: Data, at offset: Int) -> Int32 {
        let bytes = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Int32(bitPattern: bits)
    }
}
