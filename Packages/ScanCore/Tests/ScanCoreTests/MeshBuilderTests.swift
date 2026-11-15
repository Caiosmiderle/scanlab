import XCTest
import simd
@testable import ScanCore

final class MeshBuilderTests: XCTestCase {

    func testTranslationMovesVerticesButNotNormals() {
        let anchor = TestMeshes.triangleAnchor(transform: TestMeshes.translation(10, 20, 30))
        let mesh = MeshBuilder.worldMesh(from: [anchor])

        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.positions, [10, 20, 30,
                                        11, 20, 30,
                                        10, 21, 30])
        // Normal é direção: a translação não pode mexer nela.
        XCTAssertEqual(mesh.normals, [0, 0, 1,
                                      0, 0, 1,
                                      0, 0, 1])
        XCTAssertNil(mesh.colors)
    }

    func testRotationAppliesToVerticesAndNormals() {
        let transform = TestMeshes.rotationY90(translation: SIMD3<Float>(1, 0, 0))
        let anchor = TestMeshes.triangleAnchor(transform: transform)
        let mesh = MeshBuilder.worldMesh(from: [anchor])

        // Vértice local (1, 0, 0) → rotação leva +X para -Z → (0, 0, -1) + translação (1, 0, 0).
        XCTAssertEqual(mesh.positions[3], 1, accuracy: 1e-6)
        XCTAssertEqual(mesh.positions[4], 0, accuracy: 1e-6)
        XCTAssertEqual(mesh.positions[5], -1, accuracy: 1e-6)
        // Normal local +Z → +X do mundo, sem somar a translação.
        XCTAssertEqual(mesh.normals[0], 1, accuracy: 1e-6)
        XCTAssertEqual(mesh.normals[1], 0, accuracy: 1e-6)
        XCTAssertEqual(mesh.normals[2], 0, accuracy: 1e-6)
    }

    func testIndicesAreOffsetPerAnchor() {
        let first = TestMeshes.triangleAnchor(classification: 1)
        let second = TestMeshes.quadAnchor()
        let mesh = MeshBuilder.worldMesh(from: [first, second])

        XCTAssertEqual(mesh.vertexCount, 7)
        XCTAssertEqual(mesh.faceCount, 3)
        // Os índices do segundo bloco são deslocados pelos 3 vértices do primeiro.
        XCTAssertEqual(mesh.indices, [0, 1, 2,
                                      3, 5, 4,
                                      3, 6, 5])
        XCTAssertEqual(mesh.classifications, [1, 2, 2])
        XCTAssertTrue(mesh.isConsistent)
    }

    func testInconsistentAnchorIsSkipped() {
        var broken = TestMeshes.triangleAnchor()
        broken.normals = [0, 0, 1]
        let mesh = MeshBuilder.worldMesh(from: [broken, TestMeshes.quadAnchor()])

        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.faceCount, 2)
        XCTAssertEqual(mesh.indices, [0, 2, 1,
                                      0, 3, 2])
    }

    func testApplyAxisConvertsToZUp() {
        var mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        mesh.applyAxis(.zUp)

        // O quadrado estava no chão (plano XZ, normal +Y). Em Z-up a normal vira +Z
        // e o vértice (1, 0, 1) vira (1, -1, 0).
        XCTAssertEqual(Array(mesh.normals[0..<3]), [0, 0, 1])
        XCTAssertEqual(Array(mesh.positions[6..<9]), [1, -1, 0])
    }

    func testApplyAxisYUpChangesNothing() {
        let original = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        var mesh = original
        mesh.applyAxis(.yUp)
        XCTAssertEqual(mesh.positions, original.positions)
        XCTAssertEqual(mesh.normals, original.normals)
    }

    func testBounds() {
        let anchor = TestMeshes.quadAnchor(transform: TestMeshes.translation(2, 3, 4))
        let mesh = MeshBuilder.worldMesh(from: [anchor])
        let bounds = mesh.bounds()

        XCTAssertEqual(bounds?.min, SIMD3<Float>(2, 3, 4))
        XCTAssertEqual(bounds?.max, SIMD3<Float>(3, 3, 5))
        XCTAssertNil(MeshBuilder.worldMesh(from: []).bounds())
    }
}
