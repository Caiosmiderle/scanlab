import XCTest
import simd
@testable import ScanCore

final class MeshChunkerTests: XCTestCase {

    func testFacesAreSplitByRegion() {
        // Dois quadrados a 10 m um do outro e um triângulo perto do primeiro.
        var mesh = MeshBuilder.worldMesh(from: [
            TestMeshes.quadAnchor(),
            TestMeshes.quadAnchor(transform: TestMeshes.translation(10, 0, 0)),
            TestMeshes.triangleAnchor(transform: TestMeshes.translation(0.2, 0.1, 0.2), classification: 5)
        ])
        mesh.colors = [UInt8](repeating: 7, count: mesh.vertexCount * 3)

        let chunks = MeshChunker.split(mesh, cellSize: 4)

        XCTAssertEqual(chunks.count, 2)
        var totalFaces = 0
        var totalVertices = 0
        for chunk in chunks {
            XCTAssertTrue(chunk.isConsistent)
            XCTAssertNotNil(chunk.colors)
            totalFaces += chunk.faceCount
            totalVertices += chunk.vertexCount
            // Todo índice aponta para um vértice do próprio pedaço.
            for index in chunk.indices {
                XCTAssertLessThan(Int(index), chunk.vertexCount)
            }
        }
        XCTAssertEqual(totalFaces, mesh.faceCount)
        XCTAssertEqual(totalVertices, mesh.vertexCount)

        // O primeiro pedaço tem o quadrado da origem e o triângulo vizinho.
        XCTAssertEqual(chunks[0].faceCount, 3)
        XCTAssertEqual(chunks[0].classifications, [2, 2, 5])
        XCTAssertEqual(chunks[1].faceCount, 2)
        // O segundo pedaço guarda as posições deslocadas de 10 m.
        XCTAssertEqual(chunks[1].positions[0], 10)
    }

    func testSharedVertexIsCopiedToEachChunk() {
        // Dois triângulos compartilham um vértice mas caem em células diferentes.
        let mesh = WorldMesh(positions: [0, 0, 0, 0.9, 0, 0, 0, 0, 0.9,
                                         2.5, 0, 0, 0.9, 0, 2.5],
                             normals: [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0],
                             indices: [0, 1, 2, 1, 3, 4],
                             classifications: [1, 1])
        let chunks = MeshChunker.split(mesh, cellSize: 1)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].vertexCount, 3)
        XCTAssertEqual(chunks[1].vertexCount, 3)
        XCTAssertNil(chunks[0].colors)
    }

    func testEmptyMeshGivesNoChunks() {
        XCTAssertEqual(MeshChunker.split(MeshBuilder.worldMesh(from: []), cellSize: 2).count, 0)
    }
}
