import ARKit
import Metal
import ScanCore

/// Copia a geometria de um `ARMeshAnchor` para tipos simples do ScanCore.
///
/// Os buffers do ARKit são `MTLBuffer` e NÃO são garantidamente compactos: cada
/// `ARGeometrySource` informa `offset` (onde começa o primeiro elemento) e `stride`
/// (distância em bytes entre um elemento e o próximo). Ler assumindo 12 bytes por
/// vértice funcionaria hoje e quebraria em silêncio no dia em que a Apple mudasse o
/// layout, então toda leitura aqui respeita `offset` e `stride` e confere os limites.
enum MeshExtractor {
    static func extract(_ anchor: ARMeshAnchor) -> MeshAnchorData? {
        let geometry = anchor.geometry

        guard let positions = readFloat3(geometry.vertices),
              let normals = readFloat3(geometry.normals),
              let indices = readTriangleIndices(geometry.faces) else {
            return nil
        }
        guard normals.count == positions.count else {
            return nil
        }

        let faceCount = indices.count / 3

        // A classificação do ARKit é POR FACE (um byte por triângulo). Ela é opcional:
        // no modo `.mesh` sem classificação o ARKit não entrega esse buffer, e aí
        // tudo fica 0, que é o valor de `ARMeshClassification.none`.
        var classifications = [UInt8](repeating: 0, count: faceCount)
        if let source = geometry.classification,
           let values = readBytes(source),
           values.count == faceCount {
            classifications = values
        }

        let data = MeshAnchorData(id: anchor.identifier,
                                  transform: anchor.transform,
                                  positions: positions,
                                  normals: normals,
                                  indices: indices,
                                  classifications: classifications)
        return data.isConsistent ? data : nil
    }

    /// Lê uma fonte de vetores de 3 floats (vértices ou normais).
    private static func readFloat3(_ source: ARGeometrySource) -> [Float]? {
        guard source.format == .float3, source.componentsPerVector == 3 else {
            return nil
        }
        let count = source.count
        if count == 0 {
            return []
        }

        let bytesPerVector = 3 * MemoryLayout<Float>.size
        let stride = source.stride
        guard stride >= bytesPerVector else {
            return nil
        }
        let lastByte = source.offset + (count - 1) * stride + bytesPerVector
        guard source.offset >= 0, lastByte <= source.buffer.length else {
            return nil
        }

        var result = [Float](repeating: 0, count: count * 3)
        let base = source.buffer.contents().advanced(by: source.offset)
        result.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else {
                return
            }
            if stride == bytesPerVector {
                // Buffer compacto: uma cópia só.
                memcpy(target, base, count * bytesPerVector)
            } else {
                for index in 0..<count {
                    memcpy(target.advanced(by: index * bytesPerVector),
                           base.advanced(by: index * stride),
                           bytesPerVector)
                }
            }
        }
        return result
    }

    /// Lê os índices das faces. Só aceita triângulos.
    private static func readTriangleIndices(_ element: ARGeometryElement) -> [UInt32]? {
        guard element.indexCountPerPrimitive == 3 else {
            return nil
        }
        let indexCount = element.count * 3
        if indexCount == 0 {
            return []
        }

        let bytesPerIndex = element.bytesPerIndex
        guard indexCount * bytesPerIndex <= element.buffer.length else {
            return nil
        }
        let base = element.buffer.contents()

        if bytesPerIndex == 4 {
            var result = [UInt32](repeating: 0, count: indexCount)
            result.withUnsafeMutableBytes { destination in
                if let target = destination.baseAddress {
                    memcpy(target, base, indexCount * 4)
                }
            }
            return result
        }

        if bytesPerIndex == 2 {
            var narrow = [UInt16](repeating: 0, count: indexCount)
            narrow.withUnsafeMutableBytes { destination in
                if let target = destination.baseAddress {
                    memcpy(target, base, indexCount * 2)
                }
            }
            return narrow.map { UInt32($0) }
        }

        return nil
    }

    /// Lê uma fonte de um byte por elemento (classificação por face).
    private static func readBytes(_ source: ARGeometrySource) -> [UInt8]? {
        guard source.componentsPerVector == 1 else {
            return nil
        }
        let count = source.count
        if count == 0 {
            return []
        }
        let stride = source.stride
        guard stride >= 1 else {
            return nil
        }
        let lastByte = source.offset + (count - 1) * stride + 1
        guard source.offset >= 0, lastByte <= source.buffer.length else {
            return nil
        }

        var result = [UInt8](repeating: 0, count: count)
        let base = source.buffer.contents().advanced(by: source.offset)
        for index in 0..<count {
            result[index] = base.load(fromByteOffset: index * stride, as: UInt8.self)
        }
        return result
    }
}
