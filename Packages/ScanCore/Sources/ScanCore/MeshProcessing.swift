import Foundation
import simd

/// Operações de processamento do marco M7 que mexem só na geometria:
/// reduzir a malha e suavizar. As duas partem de uma malha e devolvem outra; o bruto
/// do scan nunca é alterado.
public enum MeshProcessing {

    // MARK: - Redução por agrupamento de vértices

    /// Junta todos os vértices que caem na mesma célula de uma grade de lado `cellSize`
    /// num vértice só, na posição média. É a redução mais simples e robusta: não cria
    /// buracos nem faces invertidas, só perde detalhe menor que a célula.
    public static func cluster(_ mesh: WorldMesh, cellSize: Float) -> WorldMesh {
        let vertexCount = mesh.vertexCount
        if vertexCount == 0 || !(cellSize > 0) {
            return mesh
        }
        let colors = mesh.colors

        var cellToNewIndex: [VoxelKey: UInt32] = [:]
        cellToNewIndex.reserveCapacity(vertexCount / 2)
        var remap = [UInt32](repeating: 0, count: vertexCount)
        var positionSums: [Float] = []
        var normalSums: [Float] = []
        var colorSums: [Float] = []
        var counts: [Float] = []

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            let point = SIMD3<Float>(mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
            let key = VoxelKey(point, cellSize: cellSize)
            var target: Int
            if let existing = cellToNewIndex[key] {
                target = Int(existing)
            } else {
                target = counts.count
                cellToNewIndex[key] = UInt32(target)
                counts.append(0)
                positionSums.append(contentsOf: [0, 0, 0])
                normalSums.append(contentsOf: [0, 0, 0])
                if colors != nil {
                    colorSums.append(contentsOf: [0, 0, 0])
                }
            }
            remap[vertex] = UInt32(target)
            counts[target] += 1
            for axis in 0..<3 {
                positionSums[target * 3 + axis] += mesh.positions[offset + axis]
                normalSums[target * 3 + axis] += mesh.normals[offset + axis]
                if let colors = colors {
                    colorSums[target * 3 + axis] += Float(colors[offset + axis])
                }
            }
        }

        let newVertexCount = counts.count
        var newPositions = [Float](repeating: 0, count: newVertexCount * 3)
        var newNormals = [Float](repeating: 0, count: newVertexCount * 3)
        var newColors = [UInt8](repeating: 0, count: colors == nil ? 0 : newVertexCount * 3)
        for vertex in 0..<newVertexCount {
            let offset = vertex * 3
            let weight = counts[vertex]
            var normal = SIMD3<Float>(normalSums[offset], normalSums[offset + 1], normalSums[offset + 2])
            let length = simd_length(normal)
            if length.isFinite && length > 0 {
                normal = normal / length
            }
            for axis in 0..<3 {
                newPositions[offset + axis] = positionSums[offset + axis] / weight
                if colors != nil {
                    newColors[offset + axis] = VertexColorizer.byte(colorSums[offset + axis] / weight)
                }
            }
            newNormals[offset] = normal.x
            newNormals[offset + 1] = normal.y
            newNormals[offset + 2] = normal.z
        }

        // Faces: renumera e descarta as que colapsaram.
        var newIndices: [UInt32] = []
        var newClassifications: [UInt8] = []
        newIndices.reserveCapacity(mesh.indices.count / 2)
        for face in 0..<mesh.faceCount {
            let a = remap[Int(mesh.indices[face * 3])]
            let b = remap[Int(mesh.indices[face * 3 + 1])]
            let c = remap[Int(mesh.indices[face * 3 + 2])]
            if a == b || b == c || a == c {
                continue
            }
            newIndices.append(a)
            newIndices.append(b)
            newIndices.append(c)
            newClassifications.append(mesh.classifications[face])
        }

        return WorldMesh(positions: newPositions,
                         normals: newNormals,
                         indices: newIndices,
                         classifications: newClassifications,
                         colors: colors == nil ? nil : newColors)
    }

    /// Comprimento médio das arestas, medido numa amostra das faces.
    public static func averageEdgeLength(_ mesh: WorldMesh) -> Float {
        let faceCount = mesh.faceCount
        if faceCount == 0 {
            return 0
        }
        let step = max(1, faceCount / 20000)
        var total: Float = 0
        var edges: Float = 0
        var face = 0
        while face < faceCount {
            let ia = Int(mesh.indices[face * 3]) * 3
            let ib = Int(mesh.indices[face * 3 + 1]) * 3
            let ic = Int(mesh.indices[face * 3 + 2]) * 3
            let a = SIMD3<Float>(mesh.positions[ia], mesh.positions[ia + 1], mesh.positions[ia + 2])
            let b = SIMD3<Float>(mesh.positions[ib], mesh.positions[ib + 1], mesh.positions[ib + 2])
            let c = SIMD3<Float>(mesh.positions[ic], mesh.positions[ic + 1], mesh.positions[ic + 2])
            let sum = simd_distance(a, b) + simd_distance(b, c) + simd_distance(a, c)
            if sum.isFinite {
                total += sum
                edges += 3
            }
            face += step
        }
        return edges > 0 ? total / edges : 0
    }

    /// Reduz a malha para perto de `targetRatio` do número de faces original (0,5 = metade).
    ///
    /// Procura, por bisseção, o tamanho de célula que dá a quantidade pedida. O resultado
    /// é aproximado: o agrupamento em grade não permite acertar um número exato de faces.
    public static func reduce(_ mesh: WorldMesh, targetRatio: Float) -> WorldMesh {
        let originalFaces = mesh.faceCount
        let edge = averageEdgeLength(mesh)
        if originalFaces == 0 || !(edge > 0) || !(targetRatio > 0 && targetRatio < 1) {
            return mesh
        }
        let target = Float(originalFaces) * targetRatio

        // Células menores que a aresta quase não reduzem; muito maiores reduzem demais.
        var low = edge * 0.5
        var high = edge * 6
        var best = cluster(mesh, cellSize: edge * 1.5)
        var bestDistance = abs(Float(best.faceCount) - target)

        for _ in 0..<6 {
            let middle = (low + high) / 2
            let candidate = cluster(mesh, cellSize: middle)
            let distance = abs(Float(candidate.faceCount) - target)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
            if Float(candidate.faceCount) > target {
                // Ainda tem faces demais: célula maior.
                low = middle
            } else {
                high = middle
            }
        }
        return best
    }

    // MARK: - Suavização

    /// Chave de uma aresta sem direção: os dois índices em ordem crescente.
    private static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        let low = UInt64(min(a, b))
        let high = UInt64(max(a, b))
        return (high << 32) | low
    }

    /// Suavização Laplaciana: cada vértice anda um pouco em direção à média dos vizinhos.
    ///
    /// Os vértices de borda (em arestas que pertencem a uma face só) ficam parados, para
    /// o contorno da malha não encolher. Poucas iterações bastam para tirar o ruído do
    /// sensor; muitas arredondam as quinas.
    /// - Parameter factor: fração do caminho até a média dos vizinhos (0 a 1).
    public static func smooth(_ mesh: WorldMesh, iterations: Int = 3, factor: Float = 0.5) -> WorldMesh {
        let vertexCount = mesh.vertexCount
        let faceCount = mesh.faceCount
        if vertexCount == 0 || faceCount == 0 || iterations <= 0 {
            return mesh
        }

        // Quantas faces usam cada aresta.
        var edgeUse: [UInt64: UInt8] = [:]
        edgeUse.reserveCapacity(faceCount * 2)
        for face in 0..<faceCount {
            let a = mesh.indices[face * 3]
            let b = mesh.indices[face * 3 + 1]
            let c = mesh.indices[face * 3 + 2]
            for key in [edgeKey(a, b), edgeKey(b, c), edgeKey(a, c)] {
                let current = edgeUse[key] ?? 0
                if current < 255 {
                    edgeUse[key] = current + 1
                }
            }
        }
        var isBoundary = [Bool](repeating: false, count: vertexCount)
        for (key, use) in edgeUse where use == 1 {
            isBoundary[Int(key & 0xFFFF_FFFF)] = true
            isBoundary[Int(key >> 32)] = true
        }

        var result = mesh
        for _ in 0..<iterations {
            var sums = [Float](repeating: 0, count: vertexCount * 3)
            var counts = [Float](repeating: 0, count: vertexCount)
            for face in 0..<faceCount {
                let corners = [Int(result.indices[face * 3]), Int(result.indices[face * 3 + 1]), Int(result.indices[face * 3 + 2])]
                for position in 0..<3 {
                    let vertex = corners[position]
                    // Os outros dois cantos da face são vizinhos deste vértice.
                    for other in 1..<3 {
                        let neighbor = corners[(position + other) % 3]
                        sums[vertex * 3] += result.positions[neighbor * 3]
                        sums[vertex * 3 + 1] += result.positions[neighbor * 3 + 1]
                        sums[vertex * 3 + 2] += result.positions[neighbor * 3 + 2]
                        counts[vertex] += 1
                    }
                }
            }
            for vertex in 0..<vertexCount where counts[vertex] > 0 && !isBoundary[vertex] {
                for axis in 0..<3 {
                    let average = sums[vertex * 3 + axis] / counts[vertex]
                    let current = result.positions[vertex * 3 + axis]
                    result.positions[vertex * 3 + axis] = current + (average - current) * factor
                }
            }
        }
        result.recomputeNormals()
        return result
    }
}

extension WorldMesh {
    /// Refaz as normais dos vértices a partir das faces, ponderando pela área de cada uma.
    /// Usado depois de mexer nas posições (suavização).
    public mutating func recomputeNormals() {
        let vertexCount = self.vertexCount
        var sums = [Float](repeating: 0, count: vertexCount * 3)
        for face in 0..<faceCount {
            let ia = Int(indices[face * 3])
            let ib = Int(indices[face * 3 + 1])
            let ic = Int(indices[face * 3 + 2])
            let a = SIMD3<Float>(positions[ia * 3], positions[ia * 3 + 1], positions[ia * 3 + 2])
            let b = SIMD3<Float>(positions[ib * 3], positions[ib * 3 + 1], positions[ib * 3 + 2])
            let c = SIMD3<Float>(positions[ic * 3], positions[ic * 3 + 1], positions[ic * 3 + 2])
            // Produto vetorial sem normalizar: o tamanho é o dobro da área da face.
            let normal = simd_cross(b - a, c - a)
            if !(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite) {
                continue
            }
            for vertex in [ia, ib, ic] {
                sums[vertex * 3] += normal.x
                sums[vertex * 3 + 1] += normal.y
                sums[vertex * 3 + 2] += normal.z
            }
        }
        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            let normal = SIMD3<Float>(sums[offset], sums[offset + 1], sums[offset + 2])
            let length = simd_length(normal)
            if length.isFinite && length > 1e-12 {
                normals[offset] = normal.x / length
                normals[offset + 1] = normal.y / length
                normals[offset + 2] = normal.z / length
            }
            // Vértice sem face aproveitável: mantém a normal que já tinha.
        }
    }
}
