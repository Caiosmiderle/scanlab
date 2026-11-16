import Foundation
import simd

/// STL binário (marco M6). Sem cor: o formato só tem triângulos.
///
/// 80 bytes de cabeçalho, `uint32` com o número de triângulos e, para cada um,
/// 50 bytes: normal (3 floats), três vértices (9 floats) e 2 bytes de atributo.
public enum STLWriter {
    public static let headerSize = 80
    public static let triangleRecordSize = 50

    public static func write(_ mesh: WorldMesh, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha com tamanhos incompatíveis")
        }
        let faceCount = mesh.faceCount
        var header = ByteBuffer(capacity: headerSize + 4)
        // O cabeçalho não pode começar com "solid", que é a marca do STL em texto.
        header.appendFixedASCII("ScanLab STL binario", length: headerSize)
        header.appendUInt32(UInt32(faceCount))
        try sink.write(header.data)

        var start = 0
        while start < faceCount {
            let end = min(start + 16384, faceCount)
            var buffer = ByteBuffer(capacity: (end - start) * triangleRecordSize)
            for face in start..<end {
                let ia = Int(mesh.indices[face * 3]) * 3
                let ib = Int(mesh.indices[face * 3 + 1]) * 3
                let ic = Int(mesh.indices[face * 3 + 2]) * 3
                let a = SIMD3<Float>(mesh.positions[ia], mesh.positions[ia + 1], mesh.positions[ia + 2])
                let b = SIMD3<Float>(mesh.positions[ib], mesh.positions[ib + 1], mesh.positions[ib + 2])
                let c = SIMD3<Float>(mesh.positions[ic], mesh.positions[ic + 1], mesh.positions[ic + 2])
                // Normal da face pela regra da mão direita (sentido anti-horário visto de fora).
                var normal = simd_cross(b - a, c - a)
                let length = simd_length(normal)
                if length.isFinite && length > 0 {
                    normal = normal / length
                } else {
                    normal = SIMD3<Float>(0, 0, 0)
                }
                buffer.appendFloat(normal.x)
                buffer.appendFloat(normal.y)
                buffer.appendFloat(normal.z)
                for vertex in [a, b, c] {
                    buffer.appendFloat(vertex.x)
                    buffer.appendFloat(vertex.y)
                    buffer.appendFloat(vertex.z)
                }
                buffer.appendUInt16(0)
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(start) / Double(max(1, faceCount)))
        }
        progress?(1.0)
    }
}

/// glTF 2.0 (marco M6): `.glb` (um arquivo binário) ou `.gltf` + `.bin`.
///
/// Atributos: `POSITION`, `NORMAL` e, se houver cor, `COLOR_0` (RGBA de 8 bits
/// normalizado). Índices de 32 bits. O padrão glTF exige Y para cima e metros, que é
/// exatamente o mundo do ARKit: passe a malha em Y-up, sem trocar eixos.
public enum GLTFWriter {
    /// Partes do arquivo, na ordem em que entram no buffer binário.
    struct Layout {
        var vertexCount: Int
        var indexCount: Int
        var hasColors: Bool
        var positionsOffset: Int { return 0 }
        var positionsLength: Int { return vertexCount * 12 }
        var normalsOffset: Int { return positionsLength }
        var normalsLength: Int { return vertexCount * 12 }
        var colorsOffset: Int { return normalsOffset + normalsLength }
        var colorsLength: Int { return hasColors ? vertexCount * 4 : 0 }
        var indicesOffset: Int { return colorsOffset + colorsLength }
        var indicesLength: Int { return indexCount * 4 }
        /// Todas as partes têm tamanho múltiplo de 4, então o total já sai alinhado.
        var totalLength: Int { return indicesOffset + indicesLength }
    }

    private static func number(_ value: Float) -> String {
        // Notação compacta e sem depender de localidade.
        return "\(value)"
    }

    /// Documento JSON do glTF.
    /// - Parameter binURI: nome do arquivo `.bin` (para `.gltf`), ou `nil` no `.glb`.
    static func json(mesh: WorldMesh, layout: Layout, binURI: String?) -> String {
        let limits = mesh.bounds()
        let lower = limits?.min ?? SIMD3<Float>(0, 0, 0)
        let upper = limits?.max ?? SIMD3<Float>(0, 0, 0)

        var attributes = "\"POSITION\":0,\"NORMAL\":1"
        var accessors: [String] = []
        var views: [String] = []

        views.append("{\"buffer\":0,\"byteOffset\":\(layout.positionsOffset),\"byteLength\":\(layout.positionsLength),\"target\":34962}")
        accessors.append("{\"bufferView\":0,\"componentType\":5126,\"count\":\(layout.vertexCount),\"type\":\"VEC3\",\"min\":[\(number(lower.x)),\(number(lower.y)),\(number(lower.z))],\"max\":[\(number(upper.x)),\(number(upper.y)),\(number(upper.z))]}")

        views.append("{\"buffer\":0,\"byteOffset\":\(layout.normalsOffset),\"byteLength\":\(layout.normalsLength),\"target\":34962}")
        accessors.append("{\"bufferView\":1,\"componentType\":5126,\"count\":\(layout.vertexCount),\"type\":\"VEC3\"}")

        var nextIndex = 2
        if layout.hasColors {
            views.append("{\"buffer\":0,\"byteOffset\":\(layout.colorsOffset),\"byteLength\":\(layout.colorsLength),\"target\":34962}")
            accessors.append("{\"bufferView\":\(nextIndex),\"componentType\":5121,\"normalized\":true,\"count\":\(layout.vertexCount),\"type\":\"VEC4\"}")
            attributes += ",\"COLOR_0\":\(nextIndex)"
            nextIndex += 1
        }

        views.append("{\"buffer\":0,\"byteOffset\":\(layout.indicesOffset),\"byteLength\":\(layout.indicesLength),\"target\":34963}")
        accessors.append("{\"bufferView\":\(nextIndex),\"componentType\":5125,\"count\":\(layout.indexCount),\"type\":\"SCALAR\"}")
        let indicesAccessor = nextIndex

        var buffer = "{\"byteLength\":\(layout.totalLength)"
        if let binURI = binURI {
            buffer += ",\"uri\":\"\(binURI)\""
        }
        buffer += "}"

        var text = "{"
        text += "\"asset\":{\"version\":\"2.0\",\"generator\":\"ScanLab\"},"
        text += "\"scene\":0,"
        text += "\"scenes\":[{\"nodes\":[0]}],"
        text += "\"nodes\":[{\"mesh\":0,\"name\":\"scan\"}],"
        // Material fosco e de dupla face: a malha de um cômodo é vista por dentro e por fora.
        text += "\"materials\":[{\"name\":\"scanlab\",\"doubleSided\":true,\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,1],\"metallicFactor\":0,\"roughnessFactor\":1}}],"
        text += "\"meshes\":[{\"name\":\"scan\",\"primitives\":[{\"attributes\":{\(attributes)},\"indices\":\(indicesAccessor),\"material\":0,\"mode\":4}]}],"
        text += "\"accessors\":[\(accessors.joined(separator: ","))],"
        text += "\"bufferViews\":[\(views.joined(separator: ","))],"
        text += "\"buffers\":[\(buffer)]"
        text += "}"
        return text
    }

    /// Grava o buffer binário (posições, normais, cores, índices) em blocos.
    private static func writeBinary(_ mesh: WorldMesh, layout: Layout, to sink: ByteSink, progress: ((Double) -> Void)?) throws {
        // Normais: o glTF exige vetores unitários; uma normal zerada vira +Y.
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

        var buffer = ByteBuffer(capacity: layout.positionsLength)
        buffer.appendFloats(mesh.positions)
        try sink.write(buffer.data)
        progress?(0.3)

        buffer = ByteBuffer(capacity: layout.normalsLength)
        buffer.appendFloats(normals)
        try sink.write(buffer.data)
        progress?(0.6)

        if let colors = mesh.colors {
            var rgba = [UInt8](repeating: 255, count: layout.vertexCount * 4)
            for vertex in 0..<layout.vertexCount {
                rgba[vertex * 4] = colors[vertex * 3]
                rgba[vertex * 4 + 1] = colors[vertex * 3 + 1]
                rgba[vertex * 4 + 2] = colors[vertex * 3 + 2]
            }
            buffer = ByteBuffer(capacity: rgba.count)
            buffer.appendBytes(rgba)
            try sink.write(buffer.data)
        }
        progress?(0.8)

        buffer = ByteBuffer(capacity: layout.indicesLength)
        buffer.appendUInt32s(mesh.indices)
        try sink.write(buffer.data)
        progress?(1.0)
    }

    private static func makeLayout(for mesh: WorldMesh) throws -> Layout {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha com tamanhos incompatíveis")
        }
        return Layout(vertexCount: mesh.vertexCount, indexCount: mesh.indices.count, hasColors: mesh.colors != nil)
    }

    /// `.glb`: cabeçalho de 12 bytes, bloco JSON e bloco BIN, cada um alinhado em 4 bytes.
    public static func writeGLB(_ mesh: WorldMesh, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        let layout = try makeLayout(for: mesh)
        var jsonBytes = Array(json(mesh: mesh, layout: layout, binURI: nil).utf8)
        // O bloco JSON é completado com espaços até um múltiplo de 4.
        while jsonBytes.count % 4 != 0 {
            jsonBytes.append(0x20)
        }
        let totalLength = 12 + 8 + jsonBytes.count + 8 + layout.totalLength

        var header = ByteBuffer(capacity: 20 + jsonBytes.count + 8)
        header.appendUInt32(0x46546C67)              // "glTF"
        header.appendUInt32(2)                       // versão
        header.appendUInt32(UInt32(totalLength))
        header.appendUInt32(UInt32(jsonBytes.count))
        header.appendUInt32(0x4E4F534A)              // "JSON"
        header.appendBytes(jsonBytes)
        header.appendUInt32(UInt32(layout.totalLength))
        header.appendUInt32(0x004E4942)              // "BIN\0"
        try sink.write(header.data)

        try writeBinary(mesh, layout: layout, to: sink, progress: progress)
    }

    /// `.gltf` (JSON) + `.bin` (dados), em dois destinos.
    public static func writeGLTF(_ mesh: WorldMesh,
                                 json jsonSink: ByteSink,
                                 binary binarySink: ByteSink,
                                 binaryFileName: String,
                                 progress: ((Double) -> Void)? = nil) throws {
        let layout = try makeLayout(for: mesh)
        try jsonSink.write(Data(json(mesh: mesh, layout: layout, binURI: binaryFileName).utf8))
        try writeBinary(mesh, layout: layout, to: binarySink, progress: progress)
    }
}

/// Collada 1.4.1 (`.dae`), para SketchUp e outros programas que não leem glTF.
/// Texto XML: posições, normais, cor por vértice opcional e triângulos.
public enum DAEWriter {
    private static func floats(_ values: [Float], sink: ByteSink) throws {
        var text = ""
        text.reserveCapacity(1_100_000)
        for value in values {
            text += String(format: "%.5f ", value)
            if text.utf8.count >= 1_000_000 {
                try sink.write(Data(text.utf8))
                text = ""
                text.reserveCapacity(1_100_000)
            }
        }
        if !text.isEmpty {
            try sink.write(Data(text.utf8))
        }
    }

    public static func write(_ mesh: WorldMesh, upAxis: UpAxis, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha com tamanhos incompatíveis")
        }
        let vertexCount = mesh.vertexCount
        let faceCount = mesh.faceCount
        let axisName = upAxis == .zUp ? "Z_UP" : "Y_UP"

        var head = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        head += "<COLLADA xmlns=\"http://www.collada.org/2005/11/COLLADASchema\" version=\"1.4.1\">\n"
        head += "<asset><contributor><authoring_tool>ScanLab</authoring_tool></contributor>"
        head += "<unit name=\"meter\" meter=\"1\"/><up_axis>\(axisName)</up_axis></asset>\n"
        head += "<library_effects><effect id=\"scanlab-effect\"><profile_COMMON><technique sid=\"common\"><lambert>"
        head += "<diffuse><color sid=\"diffuse\">0.8 0.8 0.8 1</color></diffuse></lambert></technique></profile_COMMON></effect></library_effects>\n"
        head += "<library_materials><material id=\"scanlab-material\" name=\"scanlab\"><instance_effect url=\"#scanlab-effect\"/></material></library_materials>\n"
        head += "<library_geometries><geometry id=\"scan-mesh\" name=\"scan\"><mesh>\n"
        head += "<source id=\"scan-positions\"><float_array id=\"scan-positions-array\" count=\"\(vertexCount * 3)\">"
        try sink.write(Data(head.utf8))
        try floats(mesh.positions, sink: sink)
        progress?(0.3)

        var middle = "</float_array><technique_common><accessor source=\"#scan-positions-array\" count=\"\(vertexCount)\" stride=\"3\">"
        middle += "<param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>\n"
        middle += "<source id=\"scan-normals\"><float_array id=\"scan-normals-array\" count=\"\(vertexCount * 3)\">"
        try sink.write(Data(middle.utf8))
        try floats(mesh.normals, sink: sink)
        progress?(0.55)

        var afterNormals = "</float_array><technique_common><accessor source=\"#scan-normals-array\" count=\"\(vertexCount)\" stride=\"3\">"
        afterNormals += "<param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>\n"
        try sink.write(Data(afterNormals.utf8))

        if let colors = mesh.colors {
            try sink.write(Data("<source id=\"scan-colors\"><float_array id=\"scan-colors-array\" count=\"\(vertexCount * 3)\">".utf8))
            var normalized = [Float](repeating: 0, count: colors.count)
            for index in 0..<colors.count {
                normalized[index] = Float(colors[index]) / 255
            }
            try floats(normalized, sink: sink)
            var afterColors = "</float_array><technique_common><accessor source=\"#scan-colors-array\" count=\"\(vertexCount)\" stride=\"3\">"
            afterColors += "<param name=\"R\" type=\"float\"/><param name=\"G\" type=\"float\"/><param name=\"B\" type=\"float\"/></accessor></technique_common></source>\n"
            try sink.write(Data(afterColors.utf8))
        }
        progress?(0.75)

        // Posição, normal e cor usam o mesmo índice (offset 0): um número por canto.
        var triangles = "<vertices id=\"scan-vertices\"><input semantic=\"POSITION\" source=\"#scan-positions\"/></vertices>\n"
        triangles += "<triangles material=\"scanlab-material\" count=\"\(faceCount)\">"
        triangles += "<input semantic=\"VERTEX\" source=\"#scan-vertices\" offset=\"0\"/>"
        triangles += "<input semantic=\"NORMAL\" source=\"#scan-normals\" offset=\"0\"/>"
        if mesh.colors != nil {
            triangles += "<input semantic=\"COLOR\" source=\"#scan-colors\" offset=\"0\"/>"
        }
        triangles += "<p>"
        try sink.write(Data(triangles.utf8))

        var text = ""
        text.reserveCapacity(1_100_000)
        for index in mesh.indices {
            text += "\(index) "
            if text.utf8.count >= 1_000_000 {
                try sink.write(Data(text.utf8))
                text = ""
                text.reserveCapacity(1_100_000)
            }
        }
        if !text.isEmpty {
            try sink.write(Data(text.utf8))
        }

        var tail = "</p></triangles>\n</mesh></geometry></library_geometries>\n"
        tail += "<library_visual_scenes><visual_scene id=\"Scene\" name=\"Scene\"><node id=\"scan\" name=\"scan\" type=\"NODE\">"
        tail += "<instance_geometry url=\"#scan-mesh\"><bind_material><technique_common>"
        tail += "<instance_material symbol=\"scanlab-material\" target=\"#scanlab-material\"/></technique_common></bind_material></instance_geometry>"
        tail += "</node></visual_scene></library_visual_scenes>\n"
        tail += "<scene><instance_visual_scene url=\"#Scene\"/></scene>\n</COLLADA>\n"
        try sink.write(Data(tail.utf8))
        progress?(1.0)
    }
}
