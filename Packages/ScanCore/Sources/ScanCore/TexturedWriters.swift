import Foundation
import simd

/// Escritores da malha texturizada (marco M7): OBJ + MTL + JPG e GLB com a imagem embutida.
public enum TexturedWriters {

    // MARK: - OBJ

    /// Conteúdo do `.mtl` que aponta para a imagem do atlas.
    public static func materialFileContents(textureFileName: String) -> String {
        var lines: [String] = []
        lines.append("# ScanLab")
        lines.append("newmtl \(OBJWriter.materialName)")
        lines.append("Ka 0.000 0.000 0.000")
        lines.append("Kd 1.000 1.000 1.000")
        lines.append("Ks 0.000 0.000 0.000")
        lines.append("d 1.0")
        lines.append("illum 1")
        lines.append("map_Kd \(textureFileName)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// OBJ com `v`, `vt`, `vn` e faces `f a/a/a b/b/b c/c/c`.
    /// O OBJ mede o V a partir de baixo, então gravamos `1 - v`.
    public static func writeOBJ(_ mesh: TexturedMesh,
                                to sink: ByteSink,
                                materialLibraryName: String,
                                progress: ((Double) -> Void)? = nil) throws {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha texturizada com tamanhos incompatíveis")
        }
        let vertexCount = mesh.vertexCount
        let faceCount = mesh.faceCount
        let totalItems = Double(max(1, vertexCount * 3 + faceCount))
        var doneItems = 0

        var text = "# ScanLab\n# vertices: \(vertexCount) faces: \(faceCount)\nmtllib \(materialLibraryName)\no scan\n"
        text.reserveCapacity(1_100_000)

        func flushIfNeeded() throws {
            if text.utf8.count >= 1_000_000 {
                try sink.write(Data(text.utf8))
                text = ""
                text.reserveCapacity(1_100_000)
                progress?(Double(doneItems) / totalItems)
            }
        }

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            text += String(format: "v %.4f %.4f %.4f\n", mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
            doneItems += 1
            try flushIfNeeded()
        }
        for vertex in 0..<vertexCount {
            text += String(format: "vt %.5f %.5f\n", mesh.uvs[vertex * 2], 1 - mesh.uvs[vertex * 2 + 1])
            doneItems += 1
            try flushIfNeeded()
        }
        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            text += String(format: "vn %.4f %.4f %.4f\n", mesh.normals[offset], mesh.normals[offset + 1], mesh.normals[offset + 2])
            doneItems += 1
            try flushIfNeeded()
        }

        text += "usemtl \(OBJWriter.materialName)\n"
        for face in 0..<faceCount {
            let a = mesh.indices[face * 3] + 1
            let b = mesh.indices[face * 3 + 1] + 1
            let c = mesh.indices[face * 3 + 2] + 1
            text += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            doneItems += 1
            try flushIfNeeded()
        }
        if !text.isEmpty {
            try sink.write(Data(text.utf8))
        }
        progress?(1.0)
    }

    // MARK: - GLB

    /// GLB com `POSITION`, `NORMAL`, `TEXCOORD_0` e a imagem do atlas embutida.
    /// A malha deve estar em Y-up. O UV já está na convenção do glTF (origem no topo).
    /// - Parameter imageData: a imagem do atlas já codificada.
    /// - Parameter imageMimeType: `image/jpeg` ou `image/png`.
    public static func writeGLB(_ mesh: TexturedMesh,
                                imageData: Data,
                                imageMimeType: String = "image/jpeg",
                                to sink: ByteSink,
                                progress: ((Double) -> Void)? = nil) throws {
        guard mesh.isConsistent, !imageData.isEmpty else {
            throw ScanCoreError.inconsistentMesh("malha texturizada inconsistente ou imagem vazia")
        }
        let vertexCount = mesh.vertexCount
        let indexCount = mesh.indices.count

        // Ordem no buffer: posições, normais, UVs, índices e, por último, a imagem.
        let positionsLength = vertexCount * 12
        let normalsOffset = positionsLength
        let uvsOffset = normalsOffset + vertexCount * 12
        let uvsLength = vertexCount * 8
        let indicesOffset = uvsOffset + uvsLength
        let indicesLength = indexCount * 4
        let imageOffset = indicesOffset + indicesLength
        let imagePadding = (4 - imageData.count % 4) % 4
        let totalLength = imageOffset + imageData.count + imagePadding

        let limits = mesh.bounds()
        let lower = limits?.min ?? SIMD3<Float>(0, 0, 0)
        let upper = limits?.max ?? SIMD3<Float>(0, 0, 0)

        var json = "{"
        json += "\"asset\":{\"version\":\"2.0\",\"generator\":\"ScanLab\"},"
        json += "\"scene\":0,\"scenes\":[{\"nodes\":[0]}],\"nodes\":[{\"mesh\":0,\"name\":\"scan\"}],"
        json += "\"samplers\":[{\"magFilter\":9729,\"minFilter\":9987,\"wrapS\":33071,\"wrapT\":33071}],"
        json += "\"images\":[{\"bufferView\":4,\"mimeType\":\"\(imageMimeType)\"}],"
        json += "\"textures\":[{\"sampler\":0,\"source\":0}],"
        json += "\"materials\":[{\"name\":\"scanlab\",\"doubleSided\":true,\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0},\"metallicFactor\":0,\"roughnessFactor\":1}}],"
        json += "\"meshes\":[{\"name\":\"scan\",\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":1,\"TEXCOORD_0\":2},\"indices\":3,\"material\":0,\"mode\":4}]}],"
        json += "\"accessors\":["
        json += "{\"bufferView\":0,\"componentType\":5126,\"count\":\(vertexCount),\"type\":\"VEC3\",\"min\":[\(lower.x),\(lower.y),\(lower.z)],\"max\":[\(upper.x),\(upper.y),\(upper.z)]},"
        json += "{\"bufferView\":1,\"componentType\":5126,\"count\":\(vertexCount),\"type\":\"VEC3\"},"
        json += "{\"bufferView\":2,\"componentType\":5126,\"count\":\(vertexCount),\"type\":\"VEC2\"},"
        json += "{\"bufferView\":3,\"componentType\":5125,\"count\":\(indexCount),\"type\":\"SCALAR\"}],"
        json += "\"bufferViews\":["
        json += "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":\(positionsLength),\"target\":34962},"
        json += "{\"buffer\":0,\"byteOffset\":\(normalsOffset),\"byteLength\":\(vertexCount * 12),\"target\":34962},"
        json += "{\"buffer\":0,\"byteOffset\":\(uvsOffset),\"byteLength\":\(uvsLength),\"target\":34962},"
        json += "{\"buffer\":0,\"byteOffset\":\(indicesOffset),\"byteLength\":\(indicesLength),\"target\":34963},"
        json += "{\"buffer\":0,\"byteOffset\":\(imageOffset),\"byteLength\":\(imageData.count)}],"
        json += "\"buffers\":[{\"byteLength\":\(totalLength)}]"
        json += "}"

        var jsonBytes = Array(json.utf8)
        while jsonBytes.count % 4 != 0 {
            jsonBytes.append(0x20)
        }

        var header = ByteBuffer(capacity: 28 + jsonBytes.count)
        header.appendUInt32(0x46546C67)              // "glTF"
        header.appendUInt32(2)
        header.appendUInt32(UInt32(12 + 8 + jsonBytes.count + 8 + totalLength))
        header.appendUInt32(UInt32(jsonBytes.count))
        header.appendUInt32(0x4E4F534A)              // "JSON"
        header.appendBytes(jsonBytes)
        header.appendUInt32(UInt32(totalLength))
        header.appendUInt32(0x004E4942)              // "BIN\0"
        try sink.write(header.data)

        // Normais unitárias (o glTF exige); uma normal zerada vira +Y.
        var normals = mesh.normals
        var offset = 0
        while offset + 2 < normals.count {
            let normal = SIMD3<Float>(normals[offset], normals[offset + 1], normals[offset + 2])
            let length = simd_length(normal)
            if length.isFinite && length > 1e-6 {
                normals[offset] = normal.x / length
                normals[offset + 1] = normal.y / length
                normals[offset + 2] = normal.z / length
            } else {
                normals[offset] = 0
                normals[offset + 1] = 1
                normals[offset + 2] = 0
            }
            offset += 3
        }

        var buffer = ByteBuffer(capacity: positionsLength)
        buffer.appendFloats(mesh.positions)
        try sink.write(buffer.data)
        progress?(0.25)

        buffer = ByteBuffer(capacity: normals.count * 4)
        buffer.appendFloats(normals)
        try sink.write(buffer.data)
        progress?(0.5)

        buffer = ByteBuffer(capacity: uvsLength)
        buffer.appendFloats(mesh.uvs)
        try sink.write(buffer.data)

        buffer = ByteBuffer(capacity: indicesLength)
        buffer.appendUInt32s(mesh.indices)
        try sink.write(buffer.data)
        progress?(0.75)

        try sink.write(imageData)
        if imagePadding > 0 {
            try sink.write(Data(repeating: 0, count: imagePadding))
        }
        progress?(1.0)
    }
}
