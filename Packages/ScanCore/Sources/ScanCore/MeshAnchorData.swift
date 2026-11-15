import Foundation
import simd

/// Cópia dos dados de uma âncora de malha do ARKit, em tipos simples.
///
/// Os vértices e normais ficam no espaço LOCAL da âncora, exatamente como o ARKit
/// entrega; `transform` leva para o mundo. Guardamos assim (e não já no mundo) para o
/// bruto ser fiel ao sensor e permitir reprocessar depois com outra lógica.
public struct MeshAnchorData: Equatable {
    public var id: UUID
    /// Transformação local → mundo (matriz 4x4, colunas como no simd).
    public var transform: simd_float4x4
    /// 3 floats por vértice: x, y, z.
    public var positions: [Float]
    /// 3 floats por vértice: nx, ny, nz.
    public var normals: [Float]
    /// 3 índices por face (triângulos).
    public var indices: [UInt32]
    /// 1 byte por FACE. A classificação do ARKit (parede, piso, teto...) é dada por
    /// triângulo, não por vértice: um mesmo vértice pode pertencer a faces de classes
    /// diferentes numa quina.
    public var classifications: [UInt8]

    public init(id: UUID,
                transform: simd_float4x4,
                positions: [Float],
                normals: [Float],
                indices: [UInt32],
                classifications: [UInt8]) {
        self.id = id
        self.transform = transform
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.classifications = classifications
    }

    public var vertexCount: Int {
        return positions.count / 3
    }

    public var faceCount: Int {
        return indices.count / 3
    }

    /// Confere se os tamanhos dos vetores combinam entre si e se nenhum índice aponta
    /// para fora da lista de vértices.
    public var isConsistent: Bool {
        if positions.count % 3 != 0 || indices.count % 3 != 0 {
            return false
        }
        if normals.count != positions.count {
            return false
        }
        if classifications.count != faceCount {
            return false
        }
        let limit = UInt32(vertexCount)
        for index in indices {
            if index >= limit {
                return false
            }
        }
        return true
    }
}
