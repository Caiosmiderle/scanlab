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

    /// Limpeza mínima antes de exportar. Chamar com a malha ainda em Y-up.
    ///
    /// O ARKit entrega, em cada bloco, alguns vértices que nenhuma face usa, e eles vêm
    /// com normal `nan` (medido num scan real: 654 de 116 mil). Num OBJ isso vira a
    /// linha `vn nan nan nan`, que alguns programas recusam. Aqui:
    /// 1. faces com índice fora do intervalo ou com posição não finita são descartadas;
    /// 2. vértices que nenhuma face usa são removidos e os índices, renumerados;
    /// 3. um vértice usado que tenha normal inválida recebe a média das normais
    ///    geométricas das faces vizinhas.
    @discardableResult
    public mutating func removeUnusedAndInvalid() -> MeshCleanupReport {
        let oldVertexCount = vertexCount
        let oldFaceCount = faceCount

        var positionValid = [Bool](repeating: true, count: oldVertexCount)
        for vertex in 0..<oldVertexCount {
            let offset = vertex * 3
            if !(positions[offset].isFinite && positions[offset + 1].isFinite && positions[offset + 2].isFinite) {
                positionValid[vertex] = false
            }
        }

        // 1. Faces válidas e quais vértices elas usam.
        var used = [Bool](repeating: false, count: oldVertexCount)
        var keptIndices: [UInt32] = []
        var keptClassifications: [UInt8] = []
        keptIndices.reserveCapacity(indices.count)
        keptClassifications.reserveCapacity(classifications.count)
        for face in 0..<oldFaceCount {
            let a = Int(indices[face * 3])
            let b = Int(indices[face * 3 + 1])
            let c = Int(indices[face * 3 + 2])
            if a >= oldVertexCount || b >= oldVertexCount || c >= oldVertexCount {
                continue
            }
            if !positionValid[a] || !positionValid[b] || !positionValid[c] {
                continue
            }
            keptIndices.append(UInt32(a))
            keptIndices.append(UInt32(b))
            keptIndices.append(UInt32(c))
            keptClassifications.append(classifications[face])
            used[a] = true
            used[b] = true
            used[c] = true
        }

        // 2. Normais inválidas em vértices usados: zera e reconstrói pelas faces.
        var needsRepair = [Bool](repeating: false, count: oldVertexCount)
        var repairedNormals = 0
        for vertex in 0..<oldVertexCount where used[vertex] {
            let offset = vertex * 3
            let normal = SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2])
            let finite = normal.x.isFinite && normal.y.isFinite && normal.z.isFinite
            if !finite || simd_length_squared(normal) < 1e-12 {
                needsRepair[vertex] = true
                repairedNormals += 1
                normals[offset] = 0
                normals[offset + 1] = 0
                normals[offset + 2] = 0
            }
        }
        if repairedNormals > 0 {
            var face = 0
            while face * 3 + 2 < keptIndices.count {
                let a = Int(keptIndices[face * 3])
                let b = Int(keptIndices[face * 3 + 1])
                let c = Int(keptIndices[face * 3 + 2])
                face += 1
                if !(needsRepair[a] || needsRepair[b] || needsRepair[c]) {
                    continue
                }
                // Produto vetorial sem normalizar: faces maiores pesam mais na média.
                let geometric = simd_cross(position(b) - position(a), position(c) - position(a))
                if !(geometric.x.isFinite && geometric.y.isFinite && geometric.z.isFinite) {
                    continue
                }
                for vertex in [a, b, c] where needsRepair[vertex] {
                    normals[vertex * 3] += geometric.x
                    normals[vertex * 3 + 1] += geometric.y
                    normals[vertex * 3 + 2] += geometric.z
                }
            }
            for vertex in 0..<oldVertexCount where needsRepair[vertex] {
                let offset = vertex * 3
                var normal = SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2])
                let length = simd_length(normal)
                if length.isFinite && length > 0 {
                    normal = normal / length
                } else {
                    // Sem nenhuma face aproveitável: aponta para cima (Y-up do ARKit).
                    normal = SIMD3<Float>(0, 1, 0)
                }
                normals[offset] = normal.x
                normals[offset + 1] = normal.y
                normals[offset + 2] = normal.z
            }
        }

        // 3. Compacta: mantém só os vértices usados e renumera os índices.
        var remap = [UInt32](repeating: 0, count: oldVertexCount)
        var newPositions: [Float] = []
        var newNormals: [Float] = []
        var newColors: [UInt8] = []
        newPositions.reserveCapacity(positions.count)
        newNormals.reserveCapacity(normals.count)
        var nextIndex: UInt32 = 0
        for vertex in 0..<oldVertexCount where used[vertex] {
            let offset = vertex * 3
            remap[vertex] = nextIndex
            nextIndex += 1
            newPositions.append(positions[offset])
            newPositions.append(positions[offset + 1])
            newPositions.append(positions[offset + 2])
            newNormals.append(normals[offset])
            newNormals.append(normals[offset + 1])
            newNormals.append(normals[offset + 2])
            if let colors = colors {
                newColors.append(colors[offset])
                newColors.append(colors[offset + 1])
                newColors.append(colors[offset + 2])
            }
        }
        for slot in 0..<keptIndices.count {
            keptIndices[slot] = remap[Int(keptIndices[slot])]
        }

        let hadColors = colors != nil
        positions = newPositions
        normals = newNormals
        indices = keptIndices
        classifications = keptClassifications
        colors = hadColors ? newColors : nil

        return MeshCleanupReport(removedVertices: oldVertexCount - vertexCount,
                                 removedFaces: oldFaceCount - faceCount,
                                 repairedNormals: repairedNormals)
    }

    private func position(_ vertex: Int) -> SIMD3<Float> {
        let offset = vertex * 3
        return SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2])
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

/// O que `WorldMesh.removeUnusedAndInvalid()` mudou na malha (vai para o log).
public struct MeshCleanupReport: Equatable {
    public var removedVertices: Int
    public var removedFaces: Int
    public var repairedNormals: Int

    public init(removedVertices: Int, removedFaces: Int, repairedNormals: Int) {
        self.removedVertices = removedVertices
        self.removedFaces = removedFaces
        self.repairedNormals = repairedNormals
    }

    public var changedSomething: Bool {
        return removedVertices > 0 || removedFaces > 0 || repairedNormals > 0
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
