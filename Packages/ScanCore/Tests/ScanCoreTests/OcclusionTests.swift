import XCTest
import simd
@testable import ScanCore

final class OcclusionTests: XCTestCase {

    /// Quadrado de 1 m no chão (normal +Y), entre (0,0,0) e (1,0,1).
    private func floorMesh() -> WorldMesh {
        return MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
    }

    /// Mapa de profundidade 8 x 6 com o mesmo valor em todos os pixels.
    private func flatDepth(millimeters: UInt16, confidence: UInt8 = 2) -> DepthMap {
        return DepthMap(width: 8, height: 6,
                        depthMillimeters: [UInt16](repeating: millimeters, count: 48),
                        confidence: [UInt8](repeating: confidence, count: 48))
    }

    private func cameraAbove(height: Float) -> CameraModel {
        return TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(0.5, height, 0.5)))
    }

    func testNearestSurfaceTakesMinimumOfNeighborhood() {
        // 3 x 3 a 2 m, com um pixel (canto) a 0,5 m.
        var depth = [UInt16](repeating: 2000, count: 9)
        depth[0] = 500
        let map = DepthMap(width: 3, height: 3, depthMillimeters: depth, confidence: [])
        // No centro, a janela 3 x 3 alcança o canto.
        XCTAssertEqual(map.nearestSurface(columnFraction: 0.5, rowFraction: 0.5, minConfidence: 1), 0.5)
        XCTAssertEqual(map.validFraction, 1)
    }

    func testNearestSurfaceIgnoresLowConfidenceAndEmptyPixels() {
        var depth = [UInt16](repeating: 0, count: 9)
        depth[4] = 1500
        var confidence = [UInt8](repeating: 2, count: 9)
        let withGoodPixel = DepthMap(width: 3, height: 3, depthMillimeters: depth, confidence: confidence)
        XCTAssertEqual(withGoodPixel.nearestSurface(columnFraction: 0.5, rowFraction: 0.5, minConfidence: 1), 1.5)
        XCTAssertEqual(withGoodPixel.validFraction, 1.0 / 9.0, accuracy: 1e-6)

        confidence[4] = 0
        let lowConfidence = DepthMap(width: 3, height: 3, depthMillimeters: depth, confidence: confidence)
        XCTAssertNil(lowConfidence.nearestSurface(columnFraction: 0.5, rowFraction: 0.5, minConfidence: 1))
    }

    func testSurfaceInFrontHidesTheVertex() {
        // O piso está a 2 m da câmera, mas o LiDAR mediu algo a 1 m: há um objeto na frente.
        let assignment = VertexColorizer.assignKeyframes(mesh: floorMesh(),
                                                         cameras: [cameraAbove(height: 2)],
                                                         depthMaps: [flatDepth(millimeters: 1000)])
        XCTAssertEqual(assignment.bestCameras, [-1, -1, -1, -1])
    }

    func testMatchingDepthKeepsTheVertex() {
        // O LiDAR mediu os mesmos 2 m: o piso está visível.
        let assignment = VertexColorizer.assignKeyframes(mesh: floorMesh(),
                                                         cameras: [cameraAbove(height: 2)],
                                                         depthMaps: [flatDepth(millimeters: 2000)])
        XCTAssertEqual(assignment.bestCameras, [0, 0, 0, 0])
    }

    func testUnknownDepthStillAllowsTheKeyframeWithPenalty() throws {
        let camera = cameraAbove(height: 2)
        let point = SIMD3<Float>(0.5, 0, 0.5)
        let normal = SIMD3<Float>(0, 1, 0)
        let options = ColorizeOptions()

        let confirmed = try XCTUnwrap(VertexColorizer.score(camera: camera, depthMap: flatDepth(millimeters: 2000),
                                                            point: point, normal: normal, options: options))
        let unknown = try XCTUnwrap(VertexColorizer.score(camera: camera, depthMap: flatDepth(millimeters: 0),
                                                          point: point, normal: normal, options: options))
        let withoutMap = try XCTUnwrap(VertexColorizer.score(camera: camera, depthMap: nil,
                                                             point: point, normal: normal, options: options))

        XCTAssertEqual(unknown, confirmed * 0.5, accuracy: 1e-6)
        XCTAssertEqual(withoutMap, confirmed, accuracy: 1e-6)
    }

    func testOccludedCameraLosesToVisibleOne() throws {
        var mesh = floorMesh()
        // Câmera 0: mais perto (nota maior), mas com um objeto na frente. Imagem vermelha.
        // Câmera 1: mais longe, vê o piso de verdade. Imagem azul.
        let cameras = [cameraAbove(height: 2), cameraAbove(height: 3)]
        let depthMaps: [DepthMap?] = [flatDepth(millimeters: 1000), flatDepth(millimeters: 3000)]
        let images = [TestCameras.solidImage(r: 200, g: 10, b: 10), TestCameras.solidImage(r: 10, g: 10, b: 200)]

        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras, depthMaps: depthMaps) { index in
            return images[index]
        }

        XCTAssertEqual(report, ColorizeReport(coloredDirectly: 4, filledFromNeighbors: 0, uncolored: 0, framesUsed: 1))
        XCTAssertEqual(try XCTUnwrap(mesh.colors), [10, 10, 200, 10, 10, 200, 10, 10, 200, 10, 10, 200])
    }

    func testEquallyGoodCamerasAreBlended() throws {
        var mesh = floorMesh()
        // Duas câmeras na mesma pose: mesma nota, cada uma entra com metade do peso.
        let cameras = [cameraAbove(height: 2), cameraAbove(height: 2)]
        let images = [TestCameras.solidImage(r: 200, g: 10, b: 10), TestCameras.solidImage(r: 10, g: 10, b: 200)]

        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras) { index in
            return images[index]
        }

        XCTAssertEqual(report.framesUsed, 2)
        XCTAssertEqual(report.coloredDirectly, 4)
        XCTAssertEqual(try XCTUnwrap(mesh.colors), [105, 10, 105, 105, 10, 105, 105, 10, 105, 105, 10, 105])
    }

    func testBlendCountOneUsesOnlyTheBest() throws {
        var mesh = floorMesh()
        // A câmera a 2 m tem nota maior que a de 3 m; com blendCount 1 só ela conta.
        let cameras = [cameraAbove(height: 3), cameraAbove(height: 2)]
        let images = [TestCameras.solidImage(r: 200, g: 10, b: 10), TestCameras.solidImage(r: 10, g: 10, b: 200)]
        var options = ColorizeOptions()
        options.blendCount = 1

        VertexColorizer.colorize(mesh: &mesh, cameras: cameras, options: options) { index in
            return images[index]
        }

        XCTAssertEqual(try XCTUnwrap(mesh.colors), [10, 10, 200, 10, 10, 200, 10, 10, 200, 10, 10, 200])
    }

    func testMuchWorseCameraIsLeftOutOfTheBlend() {
        // A 2 m a nota é cerca de 1/3 da distância... a de 5,5 m fica abaixo de 60% da melhor.
        let assignment = VertexColorizer.assignKeyframes(mesh: floorMesh(),
                                                         cameras: [cameraAbove(height: 2), cameraAbove(height: 5.5)])
        XCTAssertEqual(assignment.slots, 3)
        // Primeiro vértice: só a câmera 0 entra; os outros dois lugares ficam vazios.
        XCTAssertEqual(Array(assignment.cameras[0..<3]), [0, -1, -1])
    }
}
