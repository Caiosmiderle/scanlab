import XCTest
import simd
@testable import ScanCore

final class MeshCleanupTests: XCTestCase {

    /// Triângulo nos vértices 1, 2 e 3; o vértice 0 não é usado por face nenhuma e
    /// tem normal `nan`, como o ARKit entrega na prática.
    private func meshWithOrphanVertex() -> WorldMesh {
        let anchor = MeshAnchorData(id: UUID(),
                                    transform: matrix_identity_float4x4,
                                    positions: [9, 9, 9,
                                                0, 0, 0,
                                                1, 0, 0,
                                                0, 1, 0],
                                    normals: [Float.nan, Float.nan, Float.nan,
                                              0, 0, 1,
                                              0, 0, 1,
                                              0, 0, 1],
                                    indices: [1, 2, 3],
                                    classifications: [4])
        return MeshBuilder.worldMesh(from: [anchor])
    }

    func testOrphanVertexIsRemovedAndIndicesAreRenumbered() {
        var mesh = meshWithOrphanVertex()
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertTrue(mesh.normals[0].isNaN)

        let report = mesh.removeUnusedAndInvalid()

        XCTAssertEqual(report, MeshCleanupReport(removedVertices: 1, removedFaces: 0, repairedNormals: 0))
        XCTAssertTrue(report.changedSomething)
        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.positions, [0, 0, 0,
                                        1, 0, 0,
                                        0, 1, 0])
        XCTAssertEqual(mesh.indices, [0, 1, 2])
        XCTAssertEqual(mesh.classifications, [4])
        XCTAssertTrue(mesh.isConsistent)
        for value in mesh.normals {
            XCTAssertTrue(value.isFinite)
        }
    }

    func testInvalidNormalOfUsedVertexIsRebuiltFromFaces() {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor()])
        mesh.normals[0] = Float.nan
        mesh.normals[1] = Float.nan
        mesh.normals[2] = Float.nan

        let report = mesh.removeUnusedAndInvalid()

        XCTAssertEqual(report, MeshCleanupReport(removedVertices: 0, removedFaces: 0, repairedNormals: 1))
        // Normal geométrica do triângulo (0,0,0) (1,0,0) (0,1,0) é +Z.
        XCTAssertEqual(Array(mesh.normals[0..<3]), [0, 0, 1])
        XCTAssertEqual(mesh.vertexCount, 3)
    }

    func testFaceWithInvalidPositionIsRemoved() {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        // Estraga a posição do vértice 3, usado só pela segunda face.
        mesh.positions[9] = Float.infinity

        let report = mesh.removeUnusedAndInvalid()

        XCTAssertEqual(report, MeshCleanupReport(removedVertices: 1, removedFaces: 1, repairedNormals: 0))
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.indices, [0, 2, 1])
        XCTAssertEqual(mesh.classifications, [2])
        XCTAssertTrue(mesh.isConsistent)
    }

    func testCleanMeshIsNotChanged() {
        let original = MeshBuilder.worldMesh(from: [TestMeshes.triangleAnchor(), TestMeshes.quadAnchor()])
        var mesh = original

        let report = mesh.removeUnusedAndInvalid()

        XCTAssertFalse(report.changedSomething)
        XCTAssertEqual(mesh.positions, original.positions)
        XCTAssertEqual(mesh.normals, original.normals)
        XCTAssertEqual(mesh.indices, original.indices)
    }

    func testColorsFollowTheirVertices() {
        var mesh = meshWithOrphanVertex()
        mesh.colors = [1, 1, 1,
                       10, 20, 30,
                       40, 50, 60,
                       70, 80, 90]

        mesh.removeUnusedAndInvalid()

        XCTAssertEqual(mesh.colors, [10, 20, 30,
                                     40, 50, 60,
                                     70, 80, 90])
    }

    func testOBJHasNoInvalidNumbersAfterCleanup() throws {
        var mesh = meshWithOrphanVertex()
        mesh.removeUnusedAndInvalid()
        let sink = MemorySink()
        try OBJWriter.write(mesh, to: sink, materialLibraryName: nil)
        let text = String(decoding: sink.data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("nan"))
    }
}
