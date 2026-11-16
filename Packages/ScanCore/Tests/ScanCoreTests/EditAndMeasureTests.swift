import XCTest
import simd
@testable import ScanCore

final class MeshCropperTests: XCTestCase {

    /// Um quadrado na origem e outro a 10 m.
    private func twoQuads() -> [MeshAnchorData] {
        return [TestMeshes.quadAnchor(), TestMeshes.quadAnchor(transform: TestMeshes.translation(10, 0, 0))]
    }

    func testRemoveInsideDeletesWhatIsInTheBox() {
        let anchors = twoQuads()
        let result = MeshCropper.crop(anchors: anchors,
                                      boxMin: SIMD3<Float>(-1, -1, -1),
                                      boxMax: SIMD3<Float>(2, 1, 2),
                                      removeInside: true)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, anchors[1].id)
        XCTAssertEqual(MeshCropper.faceCount(result), 2)
        XCTAssertEqual(MeshCropper.vertexCount(result), 4)
        XCTAssertTrue(result[0].isConsistent)
    }

    func testRemoveOutsideKeepsOnlyTheBox() {
        let anchors = twoQuads()
        let result = MeshCropper.crop(anchors: anchors,
                                      boxMin: SIMD3<Float>(-1, -1, -1),
                                      boxMax: SIMD3<Float>(2, 1, 2),
                                      removeInside: false)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, anchors[0].id)
        XCTAssertEqual(result[0], anchors[0])
    }

    func testBoxIsTestedInWorldSpace() {
        // A caixa cobre só a região perto de x = 10: o que decide é a posição no mundo,
        // não a posição local do bloco (os dois blocos têm os mesmos números locais).
        let result = MeshCropper.crop(anchors: twoQuads(),
                                      boxMin: SIMD3<Float>(9, -1, -1),
                                      boxMax: SIMD3<Float>(12, 1, 2),
                                      removeInside: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].transform.columns.3.x, 0)
    }

    func testPartialCutKeepsTheBlockConsistent() {
        // A caixa pega só a metade direita do quadrado da origem (x de 0,5 a 2).
        // Centros das duas faces: x = 0,667 (dentro) e x = 0,333 (fora).
        let result = MeshCropper.crop(anchors: [TestMeshes.quadAnchor()],
                                      boxMin: SIMD3<Float>(0.5, -1, -1),
                                      boxMax: SIMD3<Float>(2, 1, 2),
                                      removeInside: true)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].faceCount, 1)
        XCTAssertEqual(result[0].vertexCount, 3)
        XCTAssertEqual(result[0].classifications, [2])
        XCTAssertTrue(result[0].isConsistent)
        // A face que sobrou é a segunda (vértices 0, 3 e 2 do quadrado). Na ordem original
        // os vértices usados são 0, 2 e 3, que viram 0, 1 e 2: a face fica [0, 2, 1].
        XCTAssertEqual(result[0].indices, [0, 2, 1])
        XCTAssertEqual(Array(result[0].positions[3..<6]), [1, 0, 1])
        XCTAssertEqual(Array(result[0].positions[6..<9]), [0, 0, 1])
    }

    func testCuttingEverythingGivesNoBlocks() {
        let result = MeshCropper.crop(anchors: twoQuads(),
                                      boxMin: SIMD3<Float>(-100, -100, -100),
                                      boxMax: SIMD3<Float>(100, 100, 100),
                                      removeInside: true)
        XCTAssertEqual(result.count, 0)
    }

    func testCroppedBlocksSurviveTheRawFile() throws {
        let cropped = MeshCropper.crop(anchors: twoQuads(),
                                       boxMin: SIMD3<Float>(0.5, -1, -1),
                                       boxMax: SIMD3<Float>(2, 1, 2),
                                       removeInside: true)
        let sink = MemorySink()
        try RawMeshFile.write(anchors: cropped, to: sink)
        XCTAssertEqual(try RawMeshFile.read(from: sink.data), cropped)
    }
}

final class MeasurementTests: XCTestCase {

    func testDistanceAndPath() {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(3, 0, 4)
        XCTAssertEqual(MeasureMath.pathLength([a, b]), 5, accuracy: 1e-6)
        XCTAssertEqual(MeasureMath.pathLength([a, b, SIMD3<Float>(3, 2, 4)]), 7, accuracy: 1e-6)
        XCTAssertEqual(MeasureMath.pathLength([a]), 0)
    }

    func testHorizontalAreaIgnoresHeight() {
        // Retângulo de 4 m x 3 m no piso, com os cantos em alturas diferentes.
        let points = [SIMD3<Float>(0, 0.0, 0), SIMD3<Float>(4, 0.1, 0), SIMD3<Float>(4, -0.05, 3), SIMD3<Float>(0, 0.02, 3)]
        XCTAssertEqual(MeasureMath.horizontalArea(points), 12, accuracy: 1e-5)
        XCTAssertEqual(MeasureMath.horizontalArea([points[0], points[1]]), 0)
    }

    func testRecordValuesAndFormatting() {
        let distance = MeasurementRecord(name: "Parede", kind: .distance, points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(3.25, 0, 0)])
        XCTAssertEqual(distance.value, 3.25, accuracy: 1e-6)
        XCTAssertEqual(distance.formattedValue, "3,25 m")
        XCTAssertEqual(distance.labelPoint, SIMD3<Float>(1.625, 0, 0))

        let area = MeasurementRecord(name: "Sala", kind: .area,
                                     points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, 3), SIMD3<Float>(0, 0, 3)])
        XCTAssertEqual(area.formattedValue, "12,00 m²")
    }

    func testRecordIsCodable() throws {
        let record = MeasurementRecord(name: "Porta", kind: .distance, points: [SIMD3<Float>(1, 2, 3), SIMD3<Float>(1, 2, 3.8)])
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([MeasurementRecord].self, from: data), [record])
    }

    func testNearestVertexSnapsOnlyWhenClose() {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 1, 0, 1]
        // A 2 cm do segundo vértice: gruda nele.
        XCTAssertEqual(MeasureMath.nearestVertex(to: SIMD3<Float>(1.02, 0, 0), positions: positions, maxDistance: 0.05),
                       SIMD3<Float>(1, 0, 0))
        // A 30 cm de qualquer vértice: não gruda.
        XCTAssertNil(MeasureMath.nearestVertex(to: SIMD3<Float>(0.5, 0.3, 0.5), positions: positions, maxDistance: 0.05))
        XCTAssertNil(MeasureMath.nearestVertex(to: SIMD3<Float>(0, 0, 0), positions: [], maxDistance: 1))
    }

    func testCSV() {
        let records = [
            MeasurementRecord(name: "Parede; norte", kind: .distance, points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(3.25, 0, 0)]),
            MeasurementRecord(name: "Sala", kind: .area,
                              points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, 3), SIMD3<Float>(0, 0, 3)])
        ]
        let lines = MeasureMath.csv(records).split(separator: "\n").map { String($0) }

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "nome;tipo;valor;unidade;pontos (x y z em metros)")
        // O ponto e vírgula do nome vira vírgula, para não quebrar as colunas.
        XCTAssertEqual(lines[1], "Parede, norte;distância;3,25;m;0,000 0,000 0,000 | 3,250 0,000 0,000")
        XCTAssertTrue(lines[2].hasPrefix("Sala;área;12,00;m²;"))
        XCTAssertEqual(lines[2].components(separatedBy: ";").count, 5)
        XCTAssertTrue(lines[3].contains("Medidas aproximadas"))
    }
}
