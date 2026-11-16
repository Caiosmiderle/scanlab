import Foundation

/// Escritores de nuvem de pontos: PLY, PTS, XYZ e PCD (marco M6).
/// Todos gravam em blocos, para uma nuvem de milhões de pontos não precisar caber
/// inteira na memória como texto.
public enum CloudWriters {
    /// Pontos por bloco gravado.
    static let chunkCount = 32768

    private static func requireConsistent(_ cloud: PointCloud) throws {
        guard cloud.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da nuvem com tamanhos incompatíveis")
        }
    }

    // MARK: - PLY (nuvem)

    public static func plyHeader(_ cloud: PointCloud) -> String {
        var lines: [String] = []
        lines.append("ply")
        lines.append("format binary_little_endian 1.0")
        lines.append("comment Gerado pelo ScanLab")
        lines.append("element vertex \(cloud.count)")
        lines.append("property float x")
        lines.append("property float y")
        lines.append("property float z")
        if cloud.hasNormals {
            lines.append("property float nx")
            lines.append("property float ny")
            lines.append("property float nz")
        }
        if cloud.hasColors {
            lines.append("property uchar red")
            lines.append("property uchar green")
            lines.append("property uchar blue")
        }
        if cloud.hasClassifications {
            lines.append("property uchar classification")
        }
        lines.append("end_header")
        return lines.joined(separator: "\n") + "\n"
    }

    /// PLY binário só com o elemento `vertex`.
    public static func writePLY(_ cloud: PointCloud, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try requireConsistent(cloud)
        try sink.write(Data(plyHeader(cloud).utf8))
        let total = cloud.count
        var start = 0
        while start < total {
            let end = min(start + chunkCount, total)
            var buffer = ByteBuffer(capacity: (end - start) * 28)
            for point in start..<end {
                let offset = point * 3
                buffer.appendFloat(cloud.positions[offset])
                buffer.appendFloat(cloud.positions[offset + 1])
                buffer.appendFloat(cloud.positions[offset + 2])
                if cloud.hasNormals {
                    buffer.appendFloat(cloud.normals[offset])
                    buffer.appendFloat(cloud.normals[offset + 1])
                    buffer.appendFloat(cloud.normals[offset + 2])
                }
                if cloud.hasColors {
                    buffer.appendUInt8(cloud.colors[offset])
                    buffer.appendUInt8(cloud.colors[offset + 1])
                    buffer.appendUInt8(cloud.colors[offset + 2])
                }
                if cloud.hasClassifications {
                    buffer.appendUInt8(cloud.classifications[point])
                }
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(start) / Double(max(1, total)))
        }
        progress?(1.0)
    }

    // MARK: - Texto (PTS e XYZ)

    /// Gera o texto ponto a ponto e grava em blocos.
    private static func writeLines(_ cloud: PointCloud,
                                   to sink: ByteSink,
                                   header: String,
                                   progress: ((Double) -> Void)?,
                                   line: (Int) -> String) throws {
        var text = header
        text.reserveCapacity(1_100_000)
        let total = cloud.count
        for point in 0..<total {
            text += line(point)
            if text.utf8.count >= 1_000_000 {
                try sink.write(Data(text.utf8))
                text = ""
                text.reserveCapacity(1_100_000)
                progress?(Double(point) / Double(max(1, total)))
            }
        }
        if !text.isEmpty {
            try sink.write(Data(text.utf8))
        }
        progress?(1.0)
    }

    /// PTS: primeira linha com o número de pontos; depois `x y z intensidade r g b`.
    /// A intensidade não existe no LiDAR do iPad, então vai o brilho da cor (0 a 255).
    public static func writePTS(_ cloud: PointCloud, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try requireConsistent(cloud)
        try writeLines(cloud, to: sink, header: "\(cloud.count)\n", progress: progress) { point in
            let offset = point * 3
            var red = 128
            var green = 128
            var blue = 128
            if cloud.hasColors {
                red = Int(cloud.colors[offset])
                green = Int(cloud.colors[offset + 1])
                blue = Int(cloud.colors[offset + 2])
            }
            let intensity = (red * 299 + green * 587 + blue * 114) / 1000
            return String(format: "%.4f %.4f %.4f %d %d %d %d\n",
                          cloud.positions[offset], cloud.positions[offset + 1], cloud.positions[offset + 2],
                          intensity, red, green, blue)
        }
    }

    /// XYZ: uma linha por ponto, `x y z` ou `x y z r g b` se a nuvem tiver cor.
    public static func writeXYZ(_ cloud: PointCloud, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try requireConsistent(cloud)
        try writeLines(cloud, to: sink, header: "", progress: progress) { point in
            let offset = point * 3
            if cloud.hasColors {
                return String(format: "%.4f %.4f %.4f %d %d %d\n",
                              cloud.positions[offset], cloud.positions[offset + 1], cloud.positions[offset + 2],
                              Int(cloud.colors[offset]), Int(cloud.colors[offset + 1]), Int(cloud.colors[offset + 2]))
            }
            return String(format: "%.4f %.4f %.4f\n",
                          cloud.positions[offset], cloud.positions[offset + 1], cloud.positions[offset + 2])
        }
    }

    // MARK: - PCD

    /// Cabeçalho PCD 0.7. A cor vai no campo `rgb` como inteiro de 32 bits
    /// (vermelho nos bits 16 a 23, verde nos 8 a 15, azul nos 0 a 7).
    public static func pcdHeader(_ cloud: PointCloud, binary: Bool) -> String {
        var fields = "x y z"
        var sizes = "4 4 4"
        var types = "F F F"
        var counts = "1 1 1"
        if cloud.hasNormals {
            fields += " normal_x normal_y normal_z"
            sizes += " 4 4 4"
            types += " F F F"
            counts += " 1 1 1"
        }
        if cloud.hasColors {
            fields += " rgb"
            sizes += " 4"
            types += " U"
            counts += " 1"
        }
        var lines: [String] = []
        lines.append("# .PCD v0.7 - Point Cloud Data file format")
        lines.append("VERSION 0.7")
        lines.append("FIELDS \(fields)")
        lines.append("SIZE \(sizes)")
        lines.append("TYPE \(types)")
        lines.append("COUNT \(counts)")
        lines.append("WIDTH \(cloud.count)")
        lines.append("HEIGHT 1")
        lines.append("VIEWPOINT 0 0 0 1 0 0 0")
        lines.append("POINTS \(cloud.count)")
        lines.append("DATA \(binary ? "binary" : "ascii")")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func packedColor(_ cloud: PointCloud, _ offset: Int) -> UInt32 {
        return (UInt32(cloud.colors[offset]) << 16) | (UInt32(cloud.colors[offset + 1]) << 8) | UInt32(cloud.colors[offset + 2])
    }

    public static func writePCD(_ cloud: PointCloud, binary: Bool, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        try requireConsistent(cloud)
        let header = pcdHeader(cloud, binary: binary)

        if !binary {
            try writeLines(cloud, to: sink, header: header, progress: progress) { point in
                let offset = point * 3
                var text = String(format: "%.4f %.4f %.4f",
                                  cloud.positions[offset], cloud.positions[offset + 1], cloud.positions[offset + 2])
                if cloud.hasNormals {
                    text += String(format: " %.4f %.4f %.4f",
                                   cloud.normals[offset], cloud.normals[offset + 1], cloud.normals[offset + 2])
                }
                if cloud.hasColors {
                    text += " \(packedColor(cloud, offset))"
                }
                return text + "\n"
            }
            return
        }

        try sink.write(Data(header.utf8))
        let total = cloud.count
        var start = 0
        while start < total {
            let end = min(start + chunkCount, total)
            var buffer = ByteBuffer(capacity: (end - start) * 28)
            for point in start..<end {
                let offset = point * 3
                buffer.appendFloat(cloud.positions[offset])
                buffer.appendFloat(cloud.positions[offset + 1])
                buffer.appendFloat(cloud.positions[offset + 2])
                if cloud.hasNormals {
                    buffer.appendFloat(cloud.normals[offset])
                    buffer.appendFloat(cloud.normals[offset + 1])
                    buffer.appendFloat(cloud.normals[offset + 2])
                }
                if cloud.hasColors {
                    buffer.appendUInt32(packedColor(cloud, offset))
                }
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(start) / Double(max(1, total)))
        }
        progress?(1.0)
    }
}

/// LAS 1.2, formato de ponto 2 (XYZ + RGB de 16 bits), seção 6.2.
///
/// Cabeçalho de 227 bytes e 26 bytes por ponto. As coordenadas são inteiros de 32 bits:
/// `valor = (coordenada - offset) / scale`, com `scale` de 1 mm e `offset` no mínimo da
/// nuvem. CloudCompare e ReCap leem este formato.
public enum LASWriter {
    public static let headerSize = 227
    public static let pointRecordSize = 26
    public static let scale: Double = 0.001

    public static func write(_ cloud: PointCloud, to sink: ByteSink, progress: ((Double) -> Void)? = nil) throws {
        guard cloud.isConsistent else {
            throw ScanCoreError.inconsistentMesh("vetores da nuvem com tamanhos incompatíveis")
        }
        let total = cloud.count
        let limits = cloud.bounds()
        let lower = limits?.min ?? SIMD3<Float>(0, 0, 0)
        let upper = limits?.max ?? SIMD3<Float>(0, 0, 0)
        let offsetX = Double(lower.x)
        let offsetY = Double(lower.y)
        let offsetZ = Double(lower.z)

        var header = ByteBuffer(capacity: headerSize)
        header.appendASCII("LASF")
        header.appendUInt16(0)                       // File Source ID
        header.appendUInt16(0)                       // Global Encoding
        header.appendBytes([UInt8](repeating: 0, count: 16)) // Project ID (GUID)
        header.appendUInt8(1)                        // Version Major
        header.appendUInt8(2)                        // Version Minor
        header.appendFixedASCII("ScanLab", length: 32)   // System Identifier
        header.appendFixedASCII("ScanLab", length: 32)   // Generating Software
        header.appendUInt16(1)                       // File Creation Day of Year
        header.appendUInt16(2026)                    // File Creation Year
        header.appendUInt16(UInt16(headerSize))      // Header Size
        header.appendUInt32(UInt32(headerSize))      // Offset to point data
        header.appendUInt32(0)                       // Number of Variable Length Records
        header.appendUInt8(2)                        // Point Data Format ID
        header.appendUInt16(UInt16(pointRecordSize)) // Point Data Record Length
        header.appendUInt32(UInt32(total))           // Number of point records
        header.appendUInt32(UInt32(total))           // Number of points by return (1o retorno)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendDouble(scale)                   // X, Y, Z scale factor
        header.appendDouble(scale)
        header.appendDouble(scale)
        header.appendDouble(offsetX)                 // X, Y, Z offset
        header.appendDouble(offsetY)
        header.appendDouble(offsetZ)
        header.appendDouble(Double(upper.x))         // Max X, Min X
        header.appendDouble(Double(lower.x))
        header.appendDouble(Double(upper.y))         // Max Y, Min Y
        header.appendDouble(Double(lower.y))
        header.appendDouble(Double(upper.z))         // Max Z, Min Z
        header.appendDouble(Double(lower.z))
        try sink.write(header.data)

        var start = 0
        while start < total {
            let end = min(start + CloudWriters.chunkCount, total)
            var buffer = ByteBuffer(capacity: (end - start) * pointRecordSize)
            for point in start..<end {
                let offset = point * 3
                buffer.appendInt32(quantize(Double(cloud.positions[offset]), offsetX))
                buffer.appendInt32(quantize(Double(cloud.positions[offset + 1]), offsetY))
                buffer.appendInt32(quantize(Double(cloud.positions[offset + 2]), offsetZ))
                var red: UInt16 = 0
                var green: UInt16 = 0
                var blue: UInt16 = 0
                if cloud.hasColors {
                    // 8 bits → 16 bits: multiplicar por 257 leva 255 a 65535.
                    red = UInt16(cloud.colors[offset]) * 257
                    green = UInt16(cloud.colors[offset + 1]) * 257
                    blue = UInt16(cloud.colors[offset + 2]) * 257
                }
                // Intensidade: o LiDAR do iPad não fornece; usamos o brilho da cor.
                let intensity = UInt16((UInt32(red) * 299 + UInt32(green) * 587 + UInt32(blue) * 114) / 1000)
                buffer.appendUInt16(intensity)
                buffer.appendUInt8(0b0000_1001)      // retorno 1 de 1
                buffer.appendUInt8(1)                // classificação ASPRS: 1 = não classificado
                buffer.appendUInt8(0)                // ângulo de varredura
                // "User data": classificação do ARKit (0 nenhuma, 1 parede, 2 piso, 3 teto...).
                buffer.appendUInt8(cloud.hasClassifications ? cloud.classifications[point] : 0)
                buffer.appendUInt16(0)               // Point Source ID
                buffer.appendUInt16(red)
                buffer.appendUInt16(green)
                buffer.appendUInt16(blue)
            }
            try sink.write(buffer.data)
            start = end
            progress?(Double(start) / Double(max(1, total)))
        }
        progress?(1.0)
    }

    static func quantize(_ value: Double, _ offset: Double) -> Int32 {
        let scaled = ((value - offset) / scale).rounded()
        if scaled >= 2_147_483_647 {
            return Int32.max
        }
        if scaled <= -2_147_483_648 {
            return Int32.min
        }
        return Int32(scaled)
    }
}
