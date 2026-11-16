import Foundation
import simd

/// Divide a malha em pedaços por região do espaço, para o visualizador.
///
/// Com um pedaço por célula de uma grade, o SceneKit consegue descartar de uma vez os
/// pedaços que estão fora da tela (frustum culling), o que mantém a taxa de quadros em
/// scans grandes. Cada face vai para a célula onde cai o seu centro.
public enum MeshChunker {
    public static func split(_ mesh: WorldMesh, cellSize: Float) -> [WorldMesh] {
        let faceCount = mesh.faceCount
        let vertexCount = mesh.vertexCount
        if faceCount == 0 || !(cellSize > 0) {
            return []
        }

        // 1. A que pedaço cada face pertence.
        var cellToChunk: [VoxelKey: Int] = [:]
        var facesByChunk: [[Int32]] = []
        for face in 0..<faceCount {
            let ia = Int(mesh.indices[face * 3]) * 3
            let ib = Int(mesh.indices[face * 3 + 1]) * 3
            let ic = Int(mesh.indices[face * 3 + 2]) * 3
            if ia + 2 >= mesh.positions.count || ib + 2 >= mesh.positions.count || ic + 2 >= mesh.positions.count {
                continue
            }
            let a = SIMD3<Float>(mesh.positions[ia], mesh.positions[ia + 1], mesh.positions[ia + 2])
            let b = SIMD3<Float>(mesh.positions[ib], mesh.positions[ib + 1], mesh.positions[ib + 2])
            let c = SIMD3<Float>(mesh.positions[ic], mesh.positions[ic + 1], mesh.positions[ic + 2])
            let key = VoxelKey((a + b + c) / 3, cellSize: cellSize)
            if let chunk = cellToChunk[key] {
                facesByChunk[chunk].append(Int32(face))
            } else {
                cellToChunk[key] = facesByChunk.count
                facesByChunk.append([Int32(face)])
            }
        }

        // 2. Monta cada pedaço com os seus próprios vértices, renumerando os índices.
        // `remap` é reaproveitado entre pedaços: só as posições tocadas são zeradas.
        var remap = [Int32](repeating: -1, count: vertexCount)
        var chunks: [WorldMesh] = []
        chunks.reserveCapacity(facesByChunk.count)

        for faces in facesByChunk {
            var positions: [Float] = []
            var normals: [Float] = []
            var colors: [UInt8] = []
            var indices: [UInt32] = []
            var classifications: [UInt8] = []
            var touched: [Int] = []
            indices.reserveCapacity(faces.count * 3)
            classifications.reserveCapacity(faces.count)

            for faceValue in faces {
                let face = Int(faceValue)
                for corner in 0..<3 {
                    let vertex = Int(mesh.indices[face * 3 + corner])
                    if remap[vertex] < 0 {
                        remap[vertex] = Int32(positions.count / 3)
                        touched.append(vertex)
                        let offset = vertex * 3
                        positions.append(mesh.positions[offset])
                        positions.append(mesh.positions[offset + 1])
                        positions.append(mesh.positions[offset + 2])
                        normals.append(mesh.normals[offset])
                        normals.append(mesh.normals[offset + 1])
                        normals.append(mesh.normals[offset + 2])
                        if let source = mesh.colors {
                            colors.append(source[offset])
                            colors.append(source[offset + 1])
                            colors.append(source[offset + 2])
                        }
                    }
                    indices.append(UInt32(remap[vertex]))
                }
                classifications.append(mesh.classifications[face])
            }
            for vertex in touched {
                remap[vertex] = -1
            }
            chunks.append(WorldMesh(positions: positions,
                                    normals: normals,
                                    indices: indices,
                                    classifications: classifications,
                                    colors: mesh.colors == nil ? nil : colors))
        }
        return chunks
    }
}
