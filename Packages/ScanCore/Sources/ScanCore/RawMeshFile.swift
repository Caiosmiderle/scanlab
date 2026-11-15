import Foundation
import simd

/// Leitura e escrita do `mesh.bin`, o formato bruto do ScanLab (seção 6.3).
///
/// Little-endian:
/// - magic `SLMESH01` (8 bytes ASCII; os dois últimos dígitos são a versão)
/// - `uint32 anchorCount`
/// - para cada âncora:
///   - `uuid` (16 bytes)
///   - `float32[16] transform` (por colunas: coluna 0, 1, 2, 3)
///   - `uint32 vertexCount`, `uint32 faceCount`
///   - `float32[vertexCount*3]` vértices no espaço local da âncora
///   - `float32[vertexCount*3]` normais
///   - `uint32[faceCount*3]` faces
///   - `uint8[faceCount]` classificação por face
public enum RawMeshFile {
    public static let magic = "SLMESH01"

    public static func write(anchors: [MeshAnchorData], to sink: ByteSink) throws {
        var header = ByteBuffer(capacity: 12)
        header.appendASCII(magic)
        header.appendUInt32(UInt32(anchors.count))
        try sink.write(header.data)

        // Um bloco por âncora: mantém o pico de memória pequeno em scans grandes.
        for anchor in anchors {
            guard anchor.isConsistent else {
                throw ScanCoreError.inconsistentMesh("âncora \(anchor.id.uuidString) com vetores de tamanhos incompatíveis")
            }
            let byteCount = 16 + 64 + 8
                + anchor.positions.count * 4
                + anchor.normals.count * 4
                + anchor.indices.count * 4
                + anchor.classifications.count
            var buffer = ByteBuffer(capacity: byteCount)

            withUnsafeBytes(of: anchor.id.uuid) { bytes in
                buffer.appendBytes(Array(bytes))
            }
            buffer.appendFloats(transformToArray(anchor.transform))
            buffer.appendUInt32(UInt32(anchor.vertexCount))
            buffer.appendUInt32(UInt32(anchor.faceCount))
            buffer.appendFloats(anchor.positions)
            buffer.appendFloats(anchor.normals)
            buffer.appendUInt32s(anchor.indices)
            buffer.appendBytes(anchor.classifications)
            try sink.write(buffer.data)
        }
    }

    public static func read(from data: Data) throws -> [MeshAnchorData] {
        var reader = BinaryReader(data)

        let magicBytes = try reader.readBytes(8)
        guard magicBytes == Array(magic.utf8) else {
            throw ScanCoreError.invalidMagic
        }

        let anchorCount = Int(try reader.readUInt32())
        var anchors: [MeshAnchorData] = []
        // Cada âncora ocupa no mínimo 88 bytes; limita a reserva se a contagem for lixo.
        anchors.reserveCapacity(min(anchorCount, reader.remaining / 88))

        for _ in 0..<anchorCount {
            let uuidBytes = try reader.readBytes(16)
            let transformValues = try reader.readFloats(16)
            let vertexCount = Int(try reader.readUInt32())
            let faceCount = Int(try reader.readUInt32())
            let positions = try reader.readFloats(vertexCount * 3)
            let normals = try reader.readFloats(vertexCount * 3)
            let indices = try reader.readUInt32s(faceCount * 3)
            let classifications = try reader.readBytes(faceCount)

            let anchor = MeshAnchorData(id: uuidFromBytes(uuidBytes),
                                        transform: transformFromArray(transformValues),
                                        positions: positions,
                                        normals: normals,
                                        indices: indices,
                                        classifications: classifications)
            guard anchor.isConsistent else {
                throw ScanCoreError.inconsistentMesh("âncora \(anchor.id.uuidString) com índice fora do intervalo")
            }
            anchors.append(anchor)
        }
        return anchors
    }

    public static func read(contentsOf url: URL) throws -> [MeshAnchorData] {
        // Mapeado em memória: o sistema carrega as páginas sob demanda em vez de
        // copiar o arquivo inteiro para a RAM antes de começarmos a ler.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(from: data)
    }

    // MARK: - Conversões auxiliares

    static func transformToArray(_ matrix: simd_float4x4) -> [Float] {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2
        let c3 = matrix.columns.3
        return [c0.x, c0.y, c0.z, c0.w,
                c1.x, c1.y, c1.z, c1.w,
                c2.x, c2.y, c2.z, c2.w,
                c3.x, c3.y, c3.z, c3.w]
    }

    static func transformFromArray(_ v: [Float]) -> simd_float4x4 {
        let c0 = SIMD4<Float>(v[0], v[1], v[2], v[3])
        let c1 = SIMD4<Float>(v[4], v[5], v[6], v[7])
        let c2 = SIMD4<Float>(v[8], v[9], v[10], v[11])
        let c3 = SIMD4<Float>(v[12], v[13], v[14], v[15])
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    static func uuidFromBytes(_ b: [UInt8]) -> UUID {
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
