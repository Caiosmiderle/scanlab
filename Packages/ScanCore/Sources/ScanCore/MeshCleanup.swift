import Foundation
import simd

/// Célula de uma grade regular no espaço. Usada para juntar pontos próximos.
struct VoxelKey: Hashable {
    var x: Int32
    var y: Int32
    var z: Int32

    init(_ point: SIMD3<Float>, cellSize: Float) {
        x = VoxelKey.cell(point.x, cellSize)
        y = VoxelKey.cell(point.y, cellSize)
        z = VoxelKey.cell(point.z, cellSize)
    }

    private static func cell(_ value: Float, _ cellSize: Float) -> Int32 {
        let scaled = (value / cellSize).rounded(.down)
        // Protege contra valores fora do alcance do Int32 (não acontece em interiores).
        if scaled >= 2_000_000_000 {
            return 2_000_000_000
        }
        if scaled <= -2_000_000_000 {
            return -2_000_000_000
        }
        return Int32(scaled)
    }
}

public struct ComponentCleanupReport: Equatable {
    public var componentCount: Int
    public var removedComponents: Int
    public var removedFaces: Int
}

/// Limpeza simples no aparelho (marco M4): soldar vértices duplicados e remover
/// pedaços soltos minúsculos. Decimação de verdade fica para o CloudCompare e o Blender.
extension WorldMesh {
    /// Junta vértices que caem na mesma célula de uma grade de lado `tolerance`.
    ///
    /// O ARKit entrega a malha em blocos independentes: na divisa entre dois blocos
    /// os mesmos pontos existem duas vezes, e a malha fica "descosturada". Soldar
    /// reduz o arquivo e é pré-requisito para achar componentes conexos.
    /// - Returns: quantos vértices foram eliminados.
    @discardableResult
    public mutating func weldVertices(tolerance: Float = 0.001) -> Int {
        let oldVertexCount = vertexCount
        if oldVertexCount == 0 || !(tolerance > 0) {
            return 0
        }

        var cellToNewIndex: [VoxelKey: UInt32] = [:]
        cellToNewIndex.reserveCapacity(oldVertexCount)
        var remap = [UInt32](repeating: 0, count: oldVertexCount)
        var newPositions: [Float] = []
        var normalSums: [Float] = []
        var newColors: [UInt8] = []
        newPositions.reserveCapacity(positions.count)
        normalSums.reserveCapacity(normals.count)

        for vertex in 0..<oldVertexCount {
            let offset = vertex * 3
            let point = SIMD3<Float>(positions[offset], positions[offset + 1], positions[offset + 2])
            let key = VoxelKey(point, cellSize: tolerance)
            if let existing = cellToNewIndex[key] {
                remap[vertex] = existing
                // Soma as normais; a média sai na normalização do fim.
                let target = Int(existing) * 3
                normalSums[target] += normals[offset]
                normalSums[target + 1] += normals[offset + 1]
                normalSums[target + 2] += normals[offset + 2]
            } else {
                let newIndex = UInt32(newPositions.count / 3)
                cellToNewIndex[key] = newIndex
                remap[vertex] = newIndex
                newPositions.append(point.x)
                newPositions.append(point.y)
                newPositions.append(point.z)
                normalSums.append(normals[offset])
                normalSums.append(normals[offset + 1])
                normalSums.append(normals[offset + 2])
                if let colors = colors {
                    newColors.append(colors[offset])
                    newColors.append(colors[offset + 1])
                    newColors.append(colors[offset + 2])
                }
            }
        }

        let newVertexCount = newPositions.count / 3
        for vertex in 0..<newVertexCount {
            let offset = vertex * 3
            let normal = SIMD3<Float>(normalSums[offset], normalSums[offset + 1], normalSums[offset + 2])
            let length = simd_length(normal)
            if length.isFinite && length > 0 {
                normalSums[offset] = normal.x / length
                normalSums[offset + 1] = normal.y / length
                normalSums[offset + 2] = normal.z / length
            }
        }

        // Renumera as faces e descarta as que colapsaram (dois cantos no mesmo vértice).
        var newIndices: [UInt32] = []
        var newClassifications: [UInt8] = []
        newIndices.reserveCapacity(indices.count)
        newClassifications.reserveCapacity(classifications.count)
        for face in 0..<faceCount {
            let a = remap[Int(indices[face * 3])]
            let b = remap[Int(indices[face * 3 + 1])]
            let c = remap[Int(indices[face * 3 + 2])]
            if a == b || b == c || a == c {
                continue
            }
            newIndices.append(a)
            newIndices.append(b)
            newIndices.append(c)
            newClassifications.append(classifications[face])
        }

        let hadColors = colors != nil
        positions = newPositions
        normals = normalSums
        indices = newIndices
        classifications = newClassifications
        colors = hadColors ? newColors : nil
        return oldVertexCount - newVertexCount
    }

    /// Remove componentes conexos com menos de `minFaces` triângulos (pedacinhos
    /// flutuando que o sensor inventa em vidros, reflexos e bordas).
    /// Chamar depois de `weldVertices`, senão cada bloco do ARKit conta como um pedaço.
    @discardableResult
    public mutating func removeSmallComponents(minFaces: Int) -> ComponentCleanupReport {
        let vertexTotal = vertexCount
        let faceTotal = faceCount
        if faceTotal == 0 {
            return ComponentCleanupReport(componentCount: 0, removedComponents: 0, removedFaces: 0)
        }

        // Union-find sobre os vértices: cada face une os seus três cantos.
        var parent = [Int32](repeating: 0, count: vertexTotal)
        for vertex in 0..<vertexTotal {
            parent[vertex] = Int32(vertex)
        }
        func find(_ start: Int) -> Int {
            var root = start
            while Int(parent[root]) != root {
                root = Int(parent[root])
            }
            // Compressão de caminho.
            var node = start
            while Int(parent[node]) != node {
                let next = Int(parent[node])
                parent[node] = Int32(root)
                node = next
            }
            return root
        }
        for face in 0..<faceTotal {
            let a = find(Int(indices[face * 3]))
            let b = find(Int(indices[face * 3 + 1]))
            let c = find(Int(indices[face * 3 + 2]))
            if a != b {
                parent[b] = Int32(a)
            }
            let ab = find(a)
            if ab != c {
                parent[find(c)] = Int32(ab)
            }
        }

        var facesPerRoot = [Int32](repeating: 0, count: vertexTotal)
        var rootOfFace = [Int32](repeating: 0, count: faceTotal)
        for face in 0..<faceTotal {
            let root = find(Int(indices[face * 3]))
            rootOfFace[face] = Int32(root)
            facesPerRoot[root] += 1
        }

        var componentCount = 0
        var removedComponents = 0
        for vertex in 0..<vertexTotal where facesPerRoot[vertex] > 0 {
            componentCount += 1
            if Int(facesPerRoot[vertex]) < minFaces {
                removedComponents += 1
            }
        }
        if removedComponents == 0 {
            return ComponentCleanupReport(componentCount: componentCount, removedComponents: 0, removedFaces: 0)
        }

        var keptIndices: [UInt32] = []
        var keptClassifications: [UInt8] = []
        keptIndices.reserveCapacity(indices.count)
        keptClassifications.reserveCapacity(classifications.count)
        for face in 0..<faceTotal {
            if Int(facesPerRoot[Int(rootOfFace[face])]) < minFaces {
                continue
            }
            keptIndices.append(indices[face * 3])
            keptIndices.append(indices[face * 3 + 1])
            keptIndices.append(indices[face * 3 + 2])
            keptClassifications.append(classifications[face])
        }
        let removedFaces = faceTotal - keptClassifications.count
        indices = keptIndices
        classifications = keptClassifications
        // Tira os vértices que ficaram sem face.
        removeUnusedAndInvalid()
        return ComponentCleanupReport(componentCount: componentCount,
                                      removedComponents: removedComponents,
                                      removedFaces: removedFaces)
    }
}
