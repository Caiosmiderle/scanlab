import XCTest
import simd
@testable import ScanCore

final class FloorPlanTests: XCTestCase {

    private func segment(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> PlanSegment {
        return PlanSegment(start: SIMD2<Float>(x1, y1), end: SIMD2<Float>(x2, y2))
    }

    /// Cômodo retangular de 4 m x 3 m, com as paredes fora de ordem e duas invertidas,
    /// como o sensor costuma entregar.
    private func rectangularRoom() -> PlanRoom {
        let walls = [
            segment(0, 0, 4, 0),
            segment(0, 3, 0, 0), // invertida e fora de ordem
            segment(4, 0, 4, 3),
            segment(0, 3, 4, 3)  // invertida
        ]
        let door = PlanOpening(kind: .door, segment: segment(1, 0, 1.8, 0))
        let window = PlanOpening(kind: .window, segment: segment(4, 1, 4, 2))
        return PlanRoom(name: "Sala", walls: walls, openings: [door, window], ceilingHeight: 2.6)
    }

    func testPolygonArea() {
        let square = [SIMD2<Float>(0, 0), SIMD2<Float>(2, 0), SIMD2<Float>(2, 2), SIMD2<Float>(0, 2)]
        XCTAssertEqual(PlanGeometry.polygonArea(square), 4, accuracy: 1e-6)
        // O sentido dos pontos não muda a área.
        XCTAssertEqual(PlanGeometry.polygonArea(Array(square.reversed())), 4, accuracy: 1e-6)
        XCTAssertEqual(PlanGeometry.polygonArea([SIMD2<Float>(0, 0), SIMD2<Float>(1, 1)]), 0)
    }

    func testRoomAreaAndPerimeterFromWalls() throws {
        let room = rectangularRoom()
        XCTAssertEqual(room.perimeter, 14, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(room.area), 12, accuracy: 1e-4)
        let label = try XCTUnwrap(room.labelPoint)
        XCTAssertEqual(label.x, 2, accuracy: 1e-4)
        XCTAssertEqual(label.y, 1.5, accuracy: 1e-4)
    }

    func testFloorPolygonHasPriorityOverWalls() throws {
        var room = rectangularRoom()
        // Piso em "L" com 10 m².
        room.floorPolygon = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 2),
                             SIMD2<Float>(2, 2), SIMD2<Float>(2, 3), SIMD2<Float>(0, 3)]
        XCTAssertEqual(try XCTUnwrap(room.area), 10, accuracy: 1e-4)
    }

    func testOpenRoomHasNoArea() {
        // Falta uma parede: não fecha o contorno.
        let room = PlanRoom(name: "Aberto", walls: [segment(0, 0, 4, 0), segment(4, 0, 4, 3), segment(4, 3, 0, 3)])
        XCTAssertNil(room.area)
        XCTAssertEqual(room.perimeter, 11, accuracy: 1e-5)
        XCTAssertNotNil(room.labelPoint)
    }

    func testCornersWithSmallGapsStillClose() throws {
        // Pontas que não se tocam por alguns centímetros.
        let walls = [
            segment(0.05, 0, 3.95, 0.02),
            segment(4, 0.05, 4, 2.95),
            segment(3.96, 3, 0.03, 3),
            segment(0, 2.97, 0, 0.04)
        ]
        let polygon = try XCTUnwrap(PlanGeometry.orderedPolygon(from: walls))
        XCTAssertEqual(polygon.count, 4)
        // As pontas ficam alguns centímetros para dentro, então a área sai um pouco menor.
        XCTAssertEqual(PlanGeometry.polygonArea(polygon), 12, accuracy: 0.5)
    }

    func testSegmentFromSurfaceTransform() {
        // Parede de 4 m centrada em (2, 1.3, -5), com a largura ao longo de X.
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(2, 1.3, -5, 1)
        let along = PlanGeometry.segment(transform: transform, width: 4)
        XCTAssertEqual(along.start, SIMD2<Float>(0, -5))
        XCTAssertEqual(along.end, SIMD2<Float>(4, -5))
        XCTAssertEqual(along.length, 4, accuracy: 1e-6)

        // Mesma parede girada 90 graus em Y: a largura passa a correr ao longo de Z.
        let rotated = PlanGeometry.segment(transform: TestMeshes.rotationY90(translation: SIMD3<Float>(2, 1.3, -5)), width: 4)
        XCTAssertEqual(rotated.start.x, 2, accuracy: 1e-6)
        XCTAssertEqual(rotated.end.x, 2, accuracy: 1e-6)
        XCTAssertEqual(abs(rotated.end.y - rotated.start.y), 4, accuracy: 1e-6)
        XCTAssertEqual(rotated.midpoint.y, -5, accuracy: 1e-6)
    }

    func testNumbersUseCommaAndTwoDecimals() {
        XCTAssertEqual(FloorPlanSVG.formatMeters(4), "4,00")
        XCTAssertEqual(FloorPlanSVG.formatMeters(3.456), "3,46")
        XCTAssertEqual(FloorPlanSVG.formatMeters(12), "12,00")
    }

    func testSVGContainsWallsOpeningsAndLabels() {
        let svg = FloorPlanSVG.render(rooms: [rectangularRoom()], options: FloorPlanOptions(title: "Apto <teste>"))

        XCTAssertTrue(svg.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg "))
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))
        XCTAssertEqual(svg.components(separatedBy: "class=\"wall\"").count - 1, 4)
        XCTAssertEqual(svg.components(separatedBy: "class=\"door\"").count - 1, 1)
        XCTAssertEqual(svg.components(separatedBy: "class=\"window\"").count - 1, 1)
        XCTAssertEqual(svg.components(separatedBy: "class=\"floor\"").count - 1, 1)
        // Cotas: duas paredes de 4 m e duas de 3 m.
        XCTAssertEqual(svg.components(separatedBy: ">4,00 m</text>").count - 1, 2)
        XCTAssertEqual(svg.components(separatedBy: ">3,00 m</text>").count - 1, 2)
        // Nome, área e aviso.
        XCTAssertTrue(svg.contains(">Sala</text>"))
        XCTAssertTrue(svg.contains(">12,00 m²</text>"))
        XCTAssertTrue(svg.contains("Medidas aproximadas"))
        // O título é escapado.
        XCTAssertTrue(svg.contains("Apto &lt;teste&gt;"))
        XCTAssertFalse(svg.contains("<teste>"))
        // Nenhum número inválido nas coordenadas (um float inválido seria escrito "nan").
        XCTAssertFalse(svg.contains("nan\""))
        XCTAssertFalse(svg.contains("nan,"))
        XCTAssertFalse(svg.contains("nan "))
    }

    func testSVGSizeFollowsScale() {
        // 4 m x 3 m a 100 px/m, margem 90, sem título, rodapé de 70:
        // largura = 400 + 180 = 580; altura = 300 + 180 + 70 = 550.
        let svg = FloorPlanSVG.render(rooms: [rectangularRoom()])
        XCTAssertTrue(svg.contains("width=\"580.0\" height=\"550.0\""))
    }

    func testDimensionsCanBeHidden() {
        let svg = FloorPlanSVG.render(rooms: [rectangularRoom()], options: FloorPlanOptions(showDimensions: false))
        XCTAssertFalse(svg.contains("class=\"dimension\""))
        XCTAssertTrue(svg.contains("class=\"wall\""))
    }

    func testEmptyPlanIsStillValidSVG() {
        let svg = FloorPlanSVG.render(rooms: [])
        XCTAssertTrue(svg.contains("<svg "))
        XCTAssertTrue(svg.contains("</svg>"))
        XCTAssertTrue(svg.contains("Planta vazia"))
    }

    /// Gera uma planta de exemplo em arquivo quando a variável SCANLAB_SAMPLE_DIR está
    /// definida. O CI publica esse arquivo como artifact, para dar para ver a planta
    /// desenhada sem precisar de um aparelho.
    func testWritesSampleFloorPlan() throws {
        let living = rectangularRoom()
        // Quarto de 3 m x 3 m encostado na parede direita da sala, com um vão entre os dois.
        let bedroom = PlanRoom(name: "Quarto",
                               walls: [segment(4, 0, 7, 0), segment(7, 0, 7, 3), segment(7, 3, 4, 3), segment(4, 3, 4, 0)],
                               openings: [PlanOpening(kind: .opening, segment: segment(4, 2.1, 4, 2.9)),
                                          PlanOpening(kind: .window, segment: segment(5, 3, 6.2, 3))],
                               ceilingHeight: 2.6)
        // Banheiro inclinado, para conferir as cotas em paredes que não são retas na folha.
        let bath = PlanRoom(name: "Banheiro",
                            walls: [segment(0, 3.4, 1.8, 4.2), segment(1.8, 4.2, 1.2, 5.6), segment(1.2, 5.6, -0.6, 4.8), segment(-0.6, 4.8, 0, 3.4)],
                            openings: [PlanOpening(kind: .door, segment: segment(0.5, 3.62, 1.2, 3.93))])
        let svg = FloorPlanSVG.render(rooms: [living, bedroom, bath], options: FloorPlanOptions(title: "Planta de exemplo"))
        XCTAssertTrue(svg.contains(">Quarto</text>"))
        XCTAssertTrue(svg.contains(">9,00 m²</text>"))

        guard let directory = ProcessInfo.processInfo.environment["SCANLAB_SAMPLE_DIR"], !directory.isEmpty else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(svg.utf8).write(to: folder.appendingPathComponent("planta-exemplo.svg"))
    }

    func testRoomIsCodable() throws {
        let room = rectangularRoom()
        let data = try JSONEncoder().encode(room)
        XCTAssertEqual(try JSONDecoder().decode(PlanRoom.self, from: data), room)
    }
}
