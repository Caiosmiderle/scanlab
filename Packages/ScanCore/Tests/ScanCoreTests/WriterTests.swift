import XCTest
import simd
@testable import ScanCore

final class PLYWriterTests: XCTestCase {

    private func sampleMesh() -> WorldMesh {
        let anchors = [
            TestMeshes.triangleAnchor(transform: TestMeshes.translation(10, 20, 30), classification: 7),
            TestMeshes.quadAnchor()
        ]
        return MeshBuilder.worldMesh(from: anchors)
    }

    func testMeshHeaderAndTotalSize() throws {
        let mesh = sampleMesh()
        let sink = MemorySink()
        try PLYWriter.writeMesh(mesh, to: sink)

        let header = PLYWriter.header(vertexCount: 7, faceCount: 3, hasColors: false, includeFaces: true)
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        XCTAssertTrue(header.contains("element vertex 7\n"))
        XCTAssertTrue(header.contains("element face 3\n"))
        XCTAssertTrue(header.contains("property list uchar int vertex_indices\n"))
        XCTAssertTrue(header.contains("property uchar classification\n"))
        XCTAssertFalse(header.contains("red"))
        XCTAssertTrue(header.hasSuffix("end_header\n"))

        let headerSize = header.utf8.count
        XCTAssertEqual(Array(sink.data.prefix(headerSize)), Array(header.utf8))
        XCTAssertEqual(sink.data.count, headerSize + 7 * 24 + 3 * 14)
    }

    func testMeshBodyValues() throws {
        let mesh = sampleMesh()
        let sink = MemorySink()
        try PLYWriter.writeMesh(mesh, to: sink)
        let data = sink.data
        let headerSize = PLYWriter.header(vertexCount: 7, faceCount: 3, hasColors: false, includeFaces: true).utf8.count

        // Primeiro vértice: posição (10, 20, 30), normal (0, 0, 1).
        XCTAssertEqual(TestMeshes.float(in: data, at: headerSize), 10)
        XCTAssertEqual(TestMeshes.float(in: data, at: headerSize + 4), 20)
        XCTAssertEqual(TestMeshes.float(in: data, at: headerSize + 8), 30)
        XCTAssertEqual(TestMeshes.float(in: data, at: headerSize + 20), 1)

        // Primeira face: contagem 3, índices 0 1 2, classificação 7.
        let faceStart = headerSize + 7 * 24
        XCTAssertEqual(data[data.startIndex + faceStart], 3)
        XCTAssertEqual(TestMeshes.int32(in: data, at: faceStart + 1), 0)
        XCTAssertEqual(TestMeshes.int32(in: data, at: faceStart + 5), 1)
        XCTAssertEqual(TestMeshes.int32(in: data, at: faceStart + 9), 2)
        XCTAssertEqual(data[data.startIndex + faceStart + 13], 7)

        // Segunda face: índices do quadrado deslocados por 3.
        let secondFace = faceStart + 14
        XCTAssertEqual(TestMeshes.int32(in: data, at: secondFace + 1), 3)
        XCTAssertEqual(TestMeshes.int32(in: data, at: secondFace + 5), 5)
        XCTAssertEqual(TestMeshes.int32(in: data, at: secondFace + 9), 4)
        XCTAssertEqual(data[data.startIndex + secondFace + 13], 2)
    }

    func testColorsAddThreeBytesPerVertex() throws {
        var mesh = sampleMesh()
        mesh.colors = [UInt8](repeating: 128, count: mesh.vertexCount * 3)
        mesh.colors?[0] = 255
        let sink = MemorySink()
        try PLYWriter.writeMesh(mesh, to: sink)

        let header = PLYWriter.header(vertexCount: 7, faceCount: 3, hasColors: true, includeFaces: true)
        XCTAssertTrue(header.contains("property uchar red\nproperty uchar green\nproperty uchar blue\n"))
        XCTAssertEqual(sink.data.count, header.utf8.count + 7 * 27 + 3 * 14)
        // Vermelho do primeiro vértice logo depois dos 6 floats.
        XCTAssertEqual(sink.data[sink.data.startIndex + header.utf8.count + 24], 255)
    }

    func testPointCloudHasNoFaceElement() throws {
        let mesh = sampleMesh()
        let sink = MemorySink()
        try PLYWriter.writePointCloud(mesh, to: sink)

        let header = PLYWriter.header(vertexCount: 7, faceCount: 0, hasColors: false, includeFaces: false)
        XCTAssertFalse(header.contains("element face"))
        XCTAssertEqual(sink.data.count, header.utf8.count + 7 * 24)
    }

    func testProgressReachesOne() throws {
        var last = 0.0
        try PLYWriter.writeMesh(sampleMesh(), to: MemorySink()) { fraction in
            XCTAssertGreaterThanOrEqual(fraction, last)
            last = fraction
        }
        XCTAssertEqual(last, 1.0)
    }

    func testInconsistentMeshIsRejected() {
        var mesh = sampleMesh()
        mesh.classifications.removeLast()
        XCTAssertThrowsError(try PLYWriter.writeMesh(mesh, to: MemorySink()))
    }
}

final class OBJWriterTests: XCTestCase {

    private func lines(of mesh: WorldMesh, material: String?) throws -> [String] {
        let sink = MemorySink()
        try OBJWriter.write(mesh, to: sink, materialLibraryName: material)
        let text = String(decoding: sink.data, as: UTF8.self)
        return text.split(separator: "\n").map { String($0) }
    }

    func testLineCountsAndIndices() throws {
        let mesh = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor(), TestMeshes.quadAnchor()])
        let all = try lines(of: mesh, material: "scan.mtl")

        XCTAssertEqual(all.filter { $0.hasPrefix("v ") }.count, 7)
        XCTAssertEqual(all.filter { $0.hasPrefix("vn ") }.count, 7)
        let faces = all.filter { $0.hasPrefix("f ") }
        XCTAssertEqual(faces.count, 3)
        // OBJ conta a partir de 1 e cada vértice usa a normal de mesmo número.
        XCTAssertEqual(faces[0], "f 1//1 2//2 3//3")
        XCTAssertEqual(faces[1], "f 4//4 6//6 5//5")
        XCTAssertTrue(all.contains("mtllib scan.mtl"))
        XCTAssertTrue(all.contains("usemtl scanlab"))
    }

    func testVertexFormatting() throws {
        let mesh = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor(transform: TestMeshes.translation(1.5, -2, 0.25))])
        let all = try lines(of: mesh, material: nil)

        XCTAssertTrue(all.contains("v 1.5000 -2.0000 0.2500"))
        XCTAssertTrue(all.contains("vn 0.0000 0.0000 1.0000"))
        XCTAssertFalse(all.contains { $0.hasPrefix("mtllib") })
        XCTAssertFalse(all.contains { $0.hasPrefix("usemtl") })
    }

    func testVertexColorsAreAppended() throws {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor()])
        mesh.colors = [255, 0, 0,
                       0, 255, 0,
                       0, 0, 255]
        let all = try lines(of: mesh, material: nil)
        XCTAssertTrue(all.contains("v 0.0000 0.0000 0.0000 1.0000 0.0000 0.0000"))
    }

    func testMaterialFileDeclaresMaterial() {
        let text = OBJWriter.materialFileContents()
        XCTAssertTrue(text.contains("newmtl scanlab\n"))
        XCTAssertTrue(text.contains("Kd "))
    }
}
