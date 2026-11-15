import Foundation
import simd

/// Malha única, já no espaço do mundo, pronta para exportar.
public struct WorldMesh {
    /// 3 floats por vértice.
    public var positions: [Float]
    /// 3 floats por vértice.
    public var normals: [Float]
    /// 3 índices por face.
    public var indices: [UInt32]
    /// 1 byte por face (classificação do ARKit).
    public var classifications: [UInt8]
    /// 3 bytes por vértice (RGB). `nil` enquanto o scan não foi colorido (M2).
    public var colors: [UInt8]?

    public init(positions: [Float],
                normals: [Float],
                indices: [UInt32],
                classifications: [UInt8],
                colors: [UInt8]? = nil) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.classifications = classifications
        self.colors = colors
    }

    public var vertexCount: Int {
        return positions.count / 3
    }

    public var faceCount: Int {
        return indices.count / 3
    }

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
        if let colors = colors, colors.count != positions.count {
            return false
        }
        return true
    }

    /// Troca a convenção de eixos no lugar (sem criar uma segunda cópia da malha).
    /// A malha entra em Y-up, que é como o ARKit entrega.
    public mutating func applyAxis(_ axis: UpAxis) {
        if axis == .yUp {
            return
        }
        var offset = 0
        while offset + 2 < positions.count {
            let p = AxisConversion.yUpToZUp(SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2]))
            positions[offset] = p.x
            positions[offset + 1] = p.y
            positions[offset + 2] = p.z

            let n = AxisConversion.yUpToZUp(SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2]))
            normals[offset] = n.x
            normals[offset + 1] = n.y
            normals[offset + 2] = n.z

            offset += 3
        }
    }

    /// Caixa delimitadora (mínimo e máximo de cada eixo). `nil` se a malha estiver vazia.
    public func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        if vertexCount == 0 {
            return nil
        }
        var lower = SIMD3<Float>(positions[0], positions[1], positions[2])
        var upper = lower
        var offset = 3
        while offset + 2 < positions.count {
            let p = SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2])
            lower = simd_min(lower, p)
            upper = simd_max(upper, p)
            offset += 3
        }
        return (lower, upper)
    }
}

public enum MeshBuilder {
    /// Junta todas as âncoras numa malha só, levando vértices e normais para o mundo.
    ///
    /// Âncoras inconsistentes são ignoradas (em vez de derrubar a exportação inteira).
    public static func worldMesh(from anchors: [MeshAnchorData]) -> WorldMesh {
        var totalVertices = 0
        var totalFaces = 0
        for anchor in anchors where anchor.isConsistent {
            totalVertices += anchor.vertexCount
            totalFaces += anchor.faceCount
        }

        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        var classifications: [UInt8] = []
        positions.reserveCapacity(totalVertices * 3)
        normals.reserveCapacity(totalVertices * 3)
        indices.reserveCapacity(totalFaces * 3)
        classifications.reserveCapacity(totalFaces)

        var vertexBase: UInt32 = 0
        for anchor in anchors where anchor.isConsistent {
            let m = anchor.transform
            // Colunas da parte 3x3 (rotação) e a translação.
            let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

            var offset = 0
            while offset + 2 < anchor.positions.count {
                let x = anchor.positions[offset]
                let y = anchor.positions[offset + 1]
                let z = anchor.positions[offset + 2]
                let world = c0 * x + c1 * y + c2 * z + translation
                positions.append(world.x)
                positions.append(world.y)
                positions.append(world.z)

                // Normal: só a rotação (sem translação). A transformação das âncoras
                // do ARKit é rígida, então não precisa da inversa transposta.
                let nx = anchor.normals[offset]
                let ny = anchor.normals[offset + 1]
                let nz = anchor.normals[offset + 2]
                var normal = c0 * nx + c1 * ny + c2 * nz
                let length = simd_length(normal)
                if length > 0 {
                    normal = normal / length
                }
                normals.append(normal.x)
                normals.append(normal.y)
                normals.append(normal.z)

                offset += 3
            }

            // Os índices de cada âncora começam em zero; somamos quantos vértices
            // já entraram na malha única.
            for index in anchor.indices {
                indices.append(index + vertexBase)
            }
            classifications.append(contentsOf: anchor.classifications)
            vertexBase += UInt32(anchor.vertexCount)
        }

        return WorldMesh(positions: positions,
                         normals: normals,
                         indices: indices,
                         classifications: classifications,
                         colors: nil)
    }
}
