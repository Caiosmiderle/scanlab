import Foundation

/// Escritor de OBJ (texto) com `.mtl` simples (seção 6.2).
///
/// Linhas `v`, `vn` e `f a//a b//b c//c` (índices começam em 1; cada vértice usa a
/// normal de mesmo número). Se a malha tiver cor, o vértice sai como `v x y z r g b`
/// com cor de 0 a 1, extensão que MeshLab, CloudCompare e Blender entendem.
public enum OBJWriter {
    public static let materialName = "scanlab"

    /// Tamanho aproximado de cada bloco de texto gravado.
    static let chunkCharacters = 1_000_000

    /// Conteúdo do arquivo `.mtl` que acompanha o OBJ.
    public static func materialFileContents() -> String {
        var lines: [String] = []
        lines.append("# ScanLab")
        lines.append("newmtl \(materialName)")
        lines.append("Ka 0.000 0.000 0.000")
        lines.append("Kd 0.800 0.800 0.800")
        lines.append("Ks 0.000 0.000 0.000")
        lines.append("d 1.0")
        lines.append("illum 1")
        return lines.joined(separator: "\n") + "\n"
    }

    /// - Parameter materialLibraryName: nome do arquivo `.mtl` (por exemplo `scan.mtl`).
    ///   Passe `nil` para não referenciar material.
    public static func write(_ mesh: WorldMesh,
                             to sink: ByteSink,
                             materialLibraryName: String?,
                             progress: ((Double) -> Void)? = nil) throws {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha com tamanhos incompatíveis")
        }

        let vertexCount = mesh.vertexCount
        let faceCount = mesh.faceCount
        // Vértices, normais e faces: três passadas.
        let totalItems = Double(max(1, vertexCount * 2 + faceCount))
        var doneItems = 0

        var text = "# ScanLab\n"
        text += "# vertices: \(vertexCount) faces: \(faceCount)\n"
        if let library = materialLibraryName {
            text += "mtllib \(library)\n"
        }
        text += "o scan\n"

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            if let colors = mesh.colors {
                text += String(format: "v %.4f %.4f %.4f %.4f %.4f %.4f\n",
                               mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2],
                               Float(colors[offset]) / 255.0, Float(colors[offset + 1]) / 255.0, Float(colors[offset + 2]) / 255.0)
            } else {
                text += String(format: "v %.4f %.4f %.4f\n",
                               mesh.positions[offset], mesh.positions[offset + 1], mesh.positions[offset + 2])
            }
            doneItems += 1
            if text.utf8.count >= chunkCharacters {
                try flush(&text, to: sink)
                progress?(Double(doneItems) / totalItems)
            }
        }

        for vertex in 0..<vertexCount {
            let offset = vertex * 3
            text += String(format: "vn %.4f %.4f %.4f\n",
                           mesh.normals[offset], mesh.normals[offset + 1], mesh.normals[offset + 2])
            doneItems += 1
            if text.utf8.count >= chunkCharacters {
                try flush(&text, to: sink)
                progress?(Double(doneItems) / totalItems)
            }
        }

        if materialLibraryName != nil {
            text += "usemtl \(materialName)\n"
        }

        for face in 0..<faceCount {
            let offset = face * 3
            // OBJ conta a partir de 1.
            let a = mesh.indices[offset] + 1
            let b = mesh.indices[offset + 1] + 1
            let c = mesh.indices[offset + 2] + 1
            text += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            doneItems += 1
            if text.utf8.count >= chunkCharacters {
                try flush(&text, to: sink)
                progress?(Double(doneItems) / totalItems)
            }
        }

        try flush(&text, to: sink)
        progress?(1.0)
    }

    private static func flush(_ text: inout String, to sink: ByteSink) throws {
        if text.isEmpty {
            return
        }
        try sink.write(Data(text.utf8))
        text = ""
        text.reserveCapacity(chunkCharacters + 256)
    }
}
