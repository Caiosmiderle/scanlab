import XCTest
import simd
@testable import ScanCore

/// Lê inteiros e doubles little-endian de dentro de um Data.
private enum Bytes {
    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let b = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 2)])
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(bitPattern: TestMeshes.int32(in: data, at: offset))
    }

    static func double(_ data: Data, _ offset: Int) -> Double {
        let b = [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + 8)])
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(b[index]) << UInt64(8 * index)
        }
        return Double(bitPattern: bits)
    }
}

final class MeshCleanupOperationsTests: XCTestCase {

    /// Dois triângulos que formam um quadrado, mas com os vértices da diagonal
    /// duplicados, como na divisa entre dois blocos do ARKit.
    private func unweldedQuad() -> WorldMesh {
        return WorldMesh(positions: [0, 0, 0, 1, 0, 0, 1, 0, 1,
                                     0, 0, 0, 1, 0, 1, 0, 0, 1],
                         normals: [0, 1, 0, 0, 1, 0, 0, 1, 0,
                                   0, 1, 0, 0, 1, 0, 0, 1, 0],
                         indices: [0, 2, 1, 3, 5, 4],
                         classifications: [2, 2],
                         colors: nil)
    }

    func testWeldMergesDuplicatedVertices() {
        var mesh = unweldedQuad()
        let removed = mesh.weldVertices()

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.faceCount, 2)
        XCTAssertEqual(mesh.indices, [0, 2, 1, 0, 3, 2])
        XCTAssertTrue(mesh.isConsistent)
        for value in mesh.normals {
            XCTAssertTrue(value.isFinite)
        }
    }

    func testWeldKeepsVerticesThatAreApart() {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        XCTAssertEqual(mesh.weldVertices(), 0)
        XCTAssertEqual(mesh.vertexCount, 4)
    }

    func testWeldDropsCollapsedFaces() {
        // Dois cantos do triângulo a menos de 1 mm: a face some.
        var mesh = WorldMesh(positions: [0, 0, 0, 0.0001, 0, 0, 0, 1, 0],
                             normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
                             indices: [0, 1, 2],
                             classifications: [1])
        mesh.weldVertices()
        XCTAssertEqual(mesh.faceCount, 0)
        XCTAssertEqual(mesh.classifications, [])
    }

    func testSmallComponentsAreRemoved() {
        // Um quadrado (2 faces) e, longe dele, um triângulo solto (1 face).
        var mesh = MeshBuilder.worldMesh(from: [
            TestMeshes.quadAnchor(),
            TestMeshes.triangleAnchor(transform: TestMeshes.translation(10, 0, 0))
        ])
        mesh.weldVertices()
        let report = mesh.removeSmallComponents(minFaces: 2)

        XCTAssertEqual(report, ComponentCleanupReport(componentCount: 2, removedComponents: 1, removedFaces: 1))
        XCTAssertEqual(mesh.faceCount, 2)
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertTrue(mesh.isConsistent)
    }

    func testNothingIsRemovedWhenAllComponentsAreBigEnough() {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        let report = mesh.removeSmallComponents(minFaces: 2)
        XCTAssertEqual(report, ComponentCleanupReport(componentCount: 1, removedComponents: 0, removedFaces: 0))
        XCTAssertEqual(mesh.faceCount, 2)
    }
}

final class PointCloudTests: XCTestCase {

    private func coloredQuad() -> WorldMesh {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        mesh.colors = [200, 0, 0, 200, 0, 0, 200, 0, 0, 200, 0, 0]
        return mesh
    }

    func testCloudFromVertices() {
        let cloud = PointCloudBuilder.fromVertices(coloredQuad())
        XCTAssertEqual(cloud.count, 4)
        XCTAssertTrue(cloud.hasNormals)
        XCTAssertTrue(cloud.hasColors)
        XCTAssertFalse(cloud.hasClassifications)
        XCTAssertTrue(cloud.isConsistent)
    }

    func testSurfaceSamplingFillsTheFaces() throws {
        // Quadrado de 1 m amostrado a cada 25 cm: grade de 5 x 5 = 25 pontos.
        let cloud = PointCloudBuilder.sampleSurface(coloredQuad(), spacing: 0.25)
        XCTAssertEqual(cloud.count, 25)
        XCTAssertTrue(cloud.isConsistent)
        XCTAssertTrue(cloud.hasClassifications)
        XCTAssertEqual(Set(cloud.classifications), [2])
        // Cor e normal interpoladas de vértices iguais continuam iguais.
        XCTAssertEqual(Array(cloud.colors[0..<3]), [200, 0, 0])
        XCTAssertEqual(Array(cloud.normals[0..<3]), [0, 1, 0])
        // Cada ponto é a média da sua célula, então a nuvem fica dentro do quadrado.
        let limits = try XCTUnwrap(cloud.bounds())
        XCTAssertGreaterThanOrEqual(limits.min.x, 0)
        XCTAssertLessThan(limits.min.x, 0.25)
        XCTAssertLessThanOrEqual(limits.max.x, 1)
        XCTAssertGreaterThan(limits.max.x, 0.75)
        XCTAssertEqual(limits.min.y, 0)
        XCTAssertEqual(limits.max.y, 0)
    }

    func testVoxelDownsampleAveragesPointsInTheSameCell() {
        // Três pontos: dois na mesma célula de 10 cm e um longe.
        let cloud = PointCloud(positions: [0.01, 0.01, 0.01, 0.03, 0.03, 0.03, 5, 5, 5],
                               colors: [100, 0, 0, 200, 0, 0, 0, 0, 50])
        let reduced = PointCloudBuilder.voxelDownsample(cloud, voxelSize: 0.1)

        XCTAssertEqual(reduced.count, 2)
        XCTAssertEqual(reduced.positions[0], 0.02, accuracy: 1e-6)
        XCTAssertEqual(reduced.colors[0], 150)
        XCTAssertEqual(Array(reduced.positions[3..<6]), [5, 5, 5])
        XCTAssertEqual(Array(reduced.colors[3..<6]), [0, 0, 50])
        XCTAssertFalse(reduced.hasNormals)
    }

    func testVoxelDownsampleWithZeroSizeChangesNothing() {
        let cloud = PointCloud(positions: [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(PointCloudBuilder.voxelDownsample(cloud, voxelSize: 0), cloud)
    }

    func testApplyAxis() {
        var cloud = PointCloud(positions: [1, 2, 3], normals: [0, 1, 0])
        cloud.applyAxis(.zUp)
        XCTAssertEqual(cloud.positions, [1, -3, 2])
        XCTAssertEqual(cloud.normals, [0, 0, 1])
    }
}

final class CloudWriterTests: XCTestCase {

    private func sampleCloud() -> PointCloud {
        return PointCloud(positions: [1, 2, 3, -1.5, 0.25, 4],
                          normals: [0, 0, 1, 0, 1, 0],
                          colors: [255, 0, 0, 10, 20, 30],
                          classifications: [1, 2])
    }

    private func text(_ write: (MemorySink) throws -> Void) throws -> String {
        let sink = MemorySink()
        try write(sink)
        return String(decoding: sink.data, as: UTF8.self)
    }

    func testPLYCloud() throws {
        let cloud = sampleCloud()
        let sink = MemorySink()
        try CloudWriters.writePLY(cloud, to: sink)

        let header = CloudWriters.plyHeader(cloud)
        XCTAssertTrue(header.contains("element vertex 2\n"))
        XCTAssertFalse(header.contains("element face"))
        XCTAssertTrue(header.contains("property uchar classification\n"))
        // 6 floats + 3 bytes de cor + 1 de classificação = 28 bytes por ponto.
        XCTAssertEqual(sink.data.count, header.utf8.count + 2 * 28)
        XCTAssertEqual(TestMeshes.float(in: sink.data, at: header.utf8.count + 28), -1.5)
    }

    func testPTS() throws {
        let output = try text { try CloudWriters.writePTS(sampleCloud(), to: $0) }
        let lines = output.split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "2")
        // Brilho do vermelho puro: 255 * 299 / 1000 = 76.
        XCTAssertEqual(lines[1], "1.0000 2.0000 3.0000 76 255 0 0")
    }

    func testXYZWithAndWithoutColor() throws {
        let colored = try text { try CloudWriters.writeXYZ(sampleCloud(), to: $0) }
        XCTAssertEqual(colored.split(separator: "\n").map { String($0) }[1], "-1.5000 0.2500 4.0000 10 20 30")

        let plain = try text { try CloudWriters.writeXYZ(PointCloud(positions: [1, 2, 3]), to: $0) }
        XCTAssertEqual(plain, "1.0000 2.0000 3.0000\n")
    }

    func testPCDAscii() throws {
        let output = try text { try CloudWriters.writePCD(sampleCloud(), binary: false, to: $0) }
        XCTAssertTrue(output.hasPrefix("# .PCD v0.7"))
        XCTAssertTrue(output.contains("FIELDS x y z normal_x normal_y normal_z rgb\n"))
        XCTAssertTrue(output.contains("WIDTH 2\n"))
        XCTAssertTrue(output.contains("POINTS 2\n"))
        XCTAssertTrue(output.contains("DATA ascii\n"))
        // Vermelho puro empacotado: 255 << 16 = 16711680.
        XCTAssertTrue(output.contains("1.0000 2.0000 3.0000 0.0000 0.0000 1.0000 16711680\n"))
    }

    func testPCDBinary() throws {
        let cloud = sampleCloud()
        let sink = MemorySink()
        try CloudWriters.writePCD(cloud, binary: true, to: sink)
        let header = CloudWriters.pcdHeader(cloud, binary: true)
        XCTAssertTrue(header.hasSuffix("DATA binary\n"))
        // 7 campos de 4 bytes por ponto.
        XCTAssertEqual(sink.data.count, header.utf8.count + 2 * 28)
        XCTAssertEqual(Bytes.uint32(sink.data, header.utf8.count + 24), 16711680)
    }

    func testLASHeaderAndPoints() throws {
        let cloud = sampleCloud()
        let sink = MemorySink()
        try LASWriter.write(cloud, to: sink)
        let data = sink.data

        XCTAssertEqual(data.count, 227 + 2 * 26)
        XCTAssertEqual(Array(data.prefix(4)), Array("LASF".utf8))
        XCTAssertEqual(data[data.startIndex + 24], 1)   // versão 1
        XCTAssertEqual(data[data.startIndex + 25], 2)   // .2
        XCTAssertEqual(Bytes.uint16(data, 94), 227)     // tamanho do cabeçalho
        XCTAssertEqual(Bytes.uint32(data, 96), 227)     // início dos pontos
        XCTAssertEqual(data[data.startIndex + 104], 2)  // formato de ponto 2
        XCTAssertEqual(Bytes.uint16(data, 105), 26)     // bytes por ponto
        XCTAssertEqual(Bytes.uint32(data, 107), 2)      // número de pontos
        XCTAssertEqual(Bytes.double(data, 131), 0.001)  // escala X
        XCTAssertEqual(Bytes.double(data, 155), -1.5)   // offset X = mínimo
        XCTAssertEqual(Bytes.double(data, 179), 1)      // máximo X
        XCTAssertEqual(Bytes.double(data, 187), -1.5)   // mínimo X
        XCTAssertEqual(Bytes.double(data, 211), 4)      // máximo Z

        // Primeiro ponto: x = 1 → (1 - (-1.5)) / 0.001 = 2500; y = 2 → (2 - 0.25) / 0.001 = 1750.
        XCTAssertEqual(TestMeshes.int32(in: data, at: 227), 2500)
        XCTAssertEqual(TestMeshes.int32(in: data, at: 231), 1750)
        XCTAssertEqual(TestMeshes.int32(in: data, at: 235), 0)
        XCTAssertEqual(data[data.startIndex + 227 + 14], 9)     // retorno 1 de 1
        XCTAssertEqual(data[data.startIndex + 227 + 17], 1)     // classificação do ARKit em "user data"
        XCTAssertEqual(Bytes.uint16(data, 227 + 20), 65535)     // vermelho em 16 bits
        XCTAssertEqual(Bytes.uint16(data, 227 + 22), 0)
        // Segundo ponto: azul 30 → 30 * 257.
        XCTAssertEqual(Bytes.uint16(data, 227 + 26 + 24), 7710)
    }
}

final class MeshFormatTests: XCTestCase {

    private func coloredMesh() -> WorldMesh {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor(), TestMeshes.quadAnchor(transform: TestMeshes.translation(2, 0, 0))])
        mesh.colors = [UInt8](repeating: 90, count: mesh.vertexCount * 3)
        mesh.colors?[0] = 250
        return mesh
    }

    func testSTL() throws {
        let mesh = coloredMesh()
        let sink = MemorySink()
        try STLWriter.write(mesh, to: sink)
        let data = sink.data

        XCTAssertEqual(data.count, 80 + 4 + 3 * 50)
        XCTAssertEqual(Bytes.uint32(data, 80), 3)
        XCTAssertFalse(String(decoding: data.prefix(5), as: UTF8.self).lowercased().hasPrefix("solid"))
        // Primeiro triângulo (0,0,0) (1,0,0) (0,1,0): normal +Z.
        XCTAssertEqual(TestMeshes.float(in: data, at: 84), 0)
        XCTAssertEqual(TestMeshes.float(in: data, at: 92), 1)
        // Segundo vértice do primeiro triângulo: x = 1.
        XCTAssertEqual(TestMeshes.float(in: data, at: 84 + 12 + 12), 1)
    }

    func testGLBStructure() throws {
        let mesh = coloredMesh()
        let sink = MemorySink()
        try GLTFWriter.writeGLB(mesh, to: sink)
        let data = sink.data

        XCTAssertEqual(Bytes.uint32(data, 0), 0x46546C67)
        XCTAssertEqual(Bytes.uint32(data, 4), 2)
        XCTAssertEqual(Int(Bytes.uint32(data, 8)), data.count)
        XCTAssertEqual(data.count % 4, 0)

        let jsonLength = Int(Bytes.uint32(data, 12))
        XCTAssertEqual(Bytes.uint32(data, 16), 0x4E4F534A)
        XCTAssertEqual(jsonLength % 4, 0)
        let jsonData = data.subdata(in: (data.startIndex + 20)..<(data.startIndex + 20 + jsonLength))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        // 7 vértices: posições (84) + normais (84) + cores RGBA (28) + 9 índices (36) = 232 bytes.
        let binStart = 20 + jsonLength
        XCTAssertEqual(Bytes.uint32(data, binStart), 232)
        XCTAssertEqual(Bytes.uint32(data, binStart + 4), 0x004E4942)
        XCTAssertEqual(data.count, binStart + 8 + 232)

        let buffers = try XCTUnwrap(object["buffers"] as? [[String: Any]])
        XCTAssertEqual(buffers[0]["byteLength"] as? Int, 232)
        XCTAssertNil(buffers[0]["uri"])
        let accessors = try XCTUnwrap(object["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors.count, 4)
        XCTAssertEqual(accessors[0]["count"] as? Int, 7)
        XCTAssertEqual(accessors[3]["count"] as? Int, 9)
        XCTAssertEqual(accessors[3]["componentType"] as? Int, 5125)
        let maxValues = try XCTUnwrap(accessors[0]["max"] as? [Double])
        XCTAssertEqual(maxValues, [3, 1, 1])
        let meshes = try XCTUnwrap(object["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes[0]["primitives"] as? [[String: Any]])
        let attributes = try XCTUnwrap(primitives[0]["attributes"] as? [String: Int])
        XCTAssertEqual(attributes, ["POSITION": 0, "NORMAL": 1, "COLOR_0": 2])
        XCTAssertEqual(primitives[0]["indices"] as? Int, 3)

        // Primeiro byte de cor (vermelho do vértice 0) e alfa cheio.
        let colorStart = binStart + 8 + 168
        XCTAssertEqual(data[data.startIndex + colorStart], 250)
        XCTAssertEqual(data[data.startIndex + colorStart + 3], 255)
    }

    func testGLTFWithExternalBuffer() throws {
        var mesh = coloredMesh()
        mesh.colors = nil
        let jsonSink = MemorySink()
        let binarySink = MemorySink()
        try GLTFWriter.writeGLTF(mesh, json: jsonSink, binary: binarySink, binaryFileName: "scan.bin")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonSink.data) as? [String: Any])
        let buffers = try XCTUnwrap(object["buffers"] as? [[String: Any]])
        XCTAssertEqual(buffers[0]["uri"] as? String, "scan.bin")
        // Sem cor: 84 + 84 + 36.
        XCTAssertEqual(buffers[0]["byteLength"] as? Int, 204)
        XCTAssertEqual(binarySink.data.count, 204)
        let accessors = try XCTUnwrap(object["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors.count, 3)
    }

    func testDAE() throws {
        let sink = MemorySink()
        try DAEWriter.write(coloredMesh(), upAxis: .zUp, to: sink)
        let text = String(decoding: sink.data, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<COLLADA "))
        XCTAssertTrue(text.hasSuffix("</COLLADA>\n"))
        XCTAssertTrue(text.contains("<up_axis>Z_UP</up_axis>"))
        XCTAssertTrue(text.contains("id=\"scan-positions-array\" count=\"21\""))
        XCTAssertTrue(text.contains("<triangles material=\"scanlab-material\" count=\"3\">"))
        XCTAssertTrue(text.contains("semantic=\"COLOR\""))
        XCTAssertTrue(text.contains("<p>0 1 2 3 5 4 3 6 5 </p>"))

        // XML bem formado.
        let parser = XMLParser(data: sink.data)
        XCTAssertTrue(parser.parse())
    }

    /// Grava um GLB de exemplo para o validador oficial do glTF rodar no CI.
    func testWritesSampleGLB() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCANLAB_SAMPLE_DIR"], !directory.isEmpty else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let colored = try FileSink(url: folder.appendingPathComponent("amostra-com-cor.glb"))
        try GLTFWriter.writeGLB(coloredMesh(), to: colored)
        try colored.close()

        var plainMesh = coloredMesh()
        plainMesh.colors = nil
        let plain = try FileSink(url: folder.appendingPathComponent("amostra-sem-cor.glb"))
        try GLTFWriter.writeGLB(plainMesh, to: plain)
        try plain.close()

        let json = try FileSink(url: folder.appendingPathComponent("amostra.gltf"))
        let binary = try FileSink(url: folder.appendingPathComponent("amostra.bin"))
        try GLTFWriter.writeGLTF(coloredMesh(), json: json, binary: binary, binaryFileName: "amostra.bin")
        try json.close()
        try binary.close()
    }
}
