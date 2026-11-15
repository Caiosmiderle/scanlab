import Foundation

/// Escritor de PLY binário little-endian (seção 6.2).
///
/// Vértice: `float x y z`, `float nx ny nz` e, se a malha tiver cor, `uchar red green blue`.
/// Face: `list uchar int vertex_indices` + `uchar classification`.
/// Sem cor (antes do M2) as três propriedades de cor ficam fora do cabeçalho, para os
/// visualizadores sombrearem pela normal em vez de pintar tudo de uma cor só.
public enum PLYWriter {
    /// Quantos vértices (ou faces) vão em cada bloco gravado.
    static let chunkCount = 32768

    public static func header(vertexCount: Int, faceCount: Int, hasColors: Bool, includeFaces: Bool) -> String {
        var lines: [String] = []
        lines.append("ply")
        lines.append("format binary_little_endian 1.0")
        lines.append("comment Gerado pelo ScanLab")
        lines.append("element vertex \(vertexCount)")
        lines.append("property float x")
        lines.append("property float y")
        lines.append("property float z")
        lines.append("property float nx")
        lines.append("property float ny")
        lines.append("property float nz")
        if hasColors {
            lines.append("property uchar red")
            lines.append("property uchar green")
            lines.append("property uchar blue")
        }
        if includeFaces {
            lines.append("element face \(faceCount)")
            lines.append("property list uchar int vertex_indices")
            lines.append("property uchar classification")
        }
        lines.append("end_header")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Bytes de um vértice no arquivo.
    public static func vertexRecordSize(hasColors: Bool) -> Int {
        return hasColors ? 27 : 24
    }

    /// Bytes de uma face no arquivo: 1 (contagem) + 12 (três int32) + 1 (classificação).
    public static let faceRecordSize = 14

    /// Malha completa (vértices e faces).
    public static func writeMesh(_ mesh: WorldMesh, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try write(mesh, includeFaces: true, to: sink, progress: progress)
    }

    /// Versão "nuvem": só o elemento `vertex`.
    public static func writePointCloud(_ mesh: WorldMesh, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try write(mesh, includeFaces: false, to: sink, progress: progress)
    }

    private static func write(_ mesh: WorldMesh, includeFaces: Bool, to sink: ByteSink, progress: ((Double) -> Void)?) throws {
        guard mesh.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da malha com tamanhos incompatíveis")
        }

        let vertexCount = mesh.vertexCount
        let faceCount = includeFaces ? mesh.faceCount : 0
        let colors = mesh.colors
        let hasColors = colors != nil
        let totalItems = Double(max(1, vertexCount + faceCount))

        let headerText = header(vertexCount: vertexCount, faceCount: faceCount, hasColors: hasColors, includeFaces: includeFaces)
        try sink.write(Data(headerText.utf8))

        let vertexSize = vertexRecordSize(hasColors: hasColors)
        var start = 0
        while start < vertexCount {
            let end = min(start + chunkCount, vertexCount)
            var buffer = ByteBuffer(capacity: (end - start) * vertexSize)
            for vertex in start..<end {
                let offset = vertex * 3
                buffer.appendFloat(mesh.positions[offset])
                buffer.appendFloat(mesh.positions[offset + 1])
                buffer.appendFloat(mesh.positions[offset + 2])
                buffer.appendFloat(mesh.normals[offset])
                buffer.appendFloat(mesh.normals[offset + 1])
                buffer.appendFloat(mesh.normals[offset + 2])
                if let colors = colors {
                    buffer.appendUInt8(colors[offset])
                    buffer.appendUInt8(colors[offset + 1])
                    buffer.appendUInt8(colors[offset + 2])
                }
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(start) / totalItems)
        }

        start = 0
        while start < faceCount {
            let end = min(start + chunkCount, faceCount)
            var buffer = ByteBuffer(capacity: (end - start) * faceRecordSize)
            for face in start..<end {
                let offset = face * 3
                buffer.appendUInt8(3)
                buffer.appendInt32(Int32(bitPattern: mesh.indices[offset]))
                buffer.appendInt32(Int32(bitPattern: mesh.indices[offset + 1]))
                buffer.appendInt32(Int32(bitPattern: mesh.indices[offset + 2]))
                buffer.appendUInt8(mesh.classifications[face])
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(vertexCount + start) / totalItems)
        }

        progress?(1.0)
    }
}
