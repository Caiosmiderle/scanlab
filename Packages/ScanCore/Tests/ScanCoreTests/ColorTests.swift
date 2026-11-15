import XCTest
import simd
@testable import ScanCore

/// Câmeras e imagens conhecidas para os testes de projeção e coloração.
enum TestCameras {
    /// Intrínsecas simples: imagem 64 x 48, focal 50 px, centro óptico no meio.
    static let intrinsics = simd_float3x3(columns: (SIMD3<Float>(50, 0, 0),
                                                    SIMD3<Float>(0, 50, 0),
                                                    SIMD3<Float>(32, 24, 1)))

    static func camera(transform: simd_float4x4) -> CameraModel {
        return CameraModel(transform: transform, intrinsics: intrinsics, imageWidth: 64, imageHeight: 48)
    }

    /// Câmera em `position` olhando para baixo (-Y do mundo).
    /// Rotação de -90 graus em torno de X: o +Y da câmera (topo da imagem) vira -Z do
    /// mundo e o -Z da câmera (para onde ela olha) vira -Y do mundo.
    static func lookingDown(from position: SIMD3<Float>) -> simd_float4x4 {
        let c0 = SIMD4<Float>(1, 0, 0, 0)
        let c1 = SIMD4<Float>(0, 0, -1, 0)
        let c2 = SIMD4<Float>(0, 1, 0, 0)
        let c3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    /// Câmera em `position` olhando para cima (+Y do mundo): rotação de +90 graus em X.
    static func lookingUp(from position: SIMD3<Float>) -> simd_float4x4 {
        let c0 = SIMD4<Float>(1, 0, 0, 0)
        let c1 = SIMD4<Float>(0, 0, 1, 0)
        let c2 = SIMD4<Float>(0, -1, 0, 0)
        let c3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    static func solidImage(r: UInt8, g: UInt8, b: UInt8, width: Int = 64, height: Int = 48) -> RGBAImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = r
            pixels[pixel * 4 + 1] = g
            pixels[pixel * 4 + 2] = b
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}

final class CameraProjectionTests: XCTestCase {

    func testPointStraightAheadHitsPrincipalPoint() throws {
        // Câmera na origem, sem rotação: olha para -Z.
        let camera = TestCameras.camera(transform: matrix_identity_float4x4)
        let projected = try XCTUnwrap(camera.project(SIMD3<Float>(0, 0, -2)))
        XCTAssertEqual(projected.u, 32, accuracy: 1e-4)
        XCTAssertEqual(projected.v, 24, accuracy: 1e-4)
        XCTAssertEqual(projected.depth, 2, accuracy: 1e-5)
    }

    func testRightIsRightAndUpIsUp() throws {
        let camera = TestCameras.camera(transform: matrix_identity_float4x4)

        // 1 m à direita, a 2 m de profundidade: u = 50 * 1/2 + 32.
        let right = try XCTUnwrap(camera.project(SIMD3<Float>(1, 0, -2)))
        XCTAssertEqual(right.u, 57, accuracy: 1e-4)
        XCTAssertEqual(right.v, 24, accuracy: 1e-4)

        // 0,5 m acima: a linha DIMINUI (a origem da imagem é no topo). v = 24 - 50 * 0.5/2.
        let up = try XCTUnwrap(camera.project(SIMD3<Float>(0, 0.5, -2)))
        XCTAssertEqual(up.u, 32, accuracy: 1e-4)
        XCTAssertEqual(up.v, 11.5, accuracy: 1e-4)
    }

    func testPointBehindCameraIsRejected() {
        let camera = TestCameras.camera(transform: matrix_identity_float4x4)
        XCTAssertNil(camera.project(SIMD3<Float>(0, 0, 2)))
        XCTAssertNil(camera.project(SIMD3<Float>(0, 0, 0)))
    }

    func testPointOutsideImageIsRejected() {
        let camera = TestCameras.camera(transform: matrix_identity_float4x4)
        // 5 m à direita a 2 m de profundidade: u = 157, fora dos 64 px.
        XCTAssertNil(camera.project(SIMD3<Float>(5, 0, -2)))
        XCTAssertNil(camera.project(SIMD3<Float>(0, -5, -2)))
    }

    func testCameraPoseIsApplied() throws {
        // Câmera 2 m acima do ponto (0.5, 0, 0.5), olhando para baixo.
        let camera = TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(0.5, 2, 0.5)))
        XCTAssertEqual(camera.position, SIMD3<Float>(0.5, 2, 0.5))

        let center = try XCTUnwrap(camera.project(SIMD3<Float>(0.5, 0, 0.5)))
        XCTAssertEqual(center.u, 32, accuracy: 1e-4)
        XCTAssertEqual(center.v, 24, accuracy: 1e-4)
        XCTAssertEqual(center.depth, 2, accuracy: 1e-5)

        // +X do mundo continua sendo a direita da imagem.
        let right = try XCTUnwrap(camera.project(SIMD3<Float>(1.5, 0, 0.5)))
        XCTAssertEqual(right.u, 57, accuracy: 1e-4)
        // O topo da imagem aponta para -Z do mundo: um ponto em -Z sobe (v menor).
        let top = try XCTUnwrap(camera.project(SIMD3<Float>(0.5, 0, 0.0)))
        XCTAssertEqual(top.v, 11.5, accuracy: 1e-4)
    }

    func testRecordRoundTrip() throws {
        let transform = TestCameras.lookingDown(from: SIMD3<Float>(1, 2, 3))
        let record = KeyframeRecord(index: 7,
                                    timestamp: 12.5,
                                    transform: KeyframeRecord.array(from: transform),
                                    intrinsics: KeyframeRecord.array(from: TestCameras.intrinsics),
                                    imageWidth: 64,
                                    imageHeight: 48,
                                    imageFile: "frames/000007.jpg",
                                    depthFile: nil)
        let file = FramesFile(frames: [record])
        let decoded = try FramesFile.decode(try file.encoded())
        XCTAssertEqual(decoded, file)

        let camera = try XCTUnwrap(CameraModel(record: decoded.frames[0]))
        XCTAssertEqual(camera.fx, 50)
        XCTAssertEqual(camera.cy, 24)
        XCTAssertEqual(camera.position, SIMD3<Float>(1, 2, 3))

        var broken = record
        broken.intrinsics = [1, 2, 3]
        XCTAssertNil(CameraModel(record: broken))
    }
}

final class KeyframePolicyTests: XCTestCase {

    func testFirstFrameIsAlwaysCaptured() {
        let policy = KeyframePolicy(settings: KeyframeSettings())
        XCTAssertTrue(policy.shouldCapture(timestamp: 0, transform: matrix_identity_float4x4))
    }

    func testNeedsTimeAndMovement() {
        var policy = KeyframePolicy(settings: KeyframeSettings())
        policy.markCaptured(timestamp: 10, transform: matrix_identity_float4x4)

        let moved = TestMeshes.translation(0.2, 0, 0)
        // Andou 20 cm, mas só passaram 0,1 s.
        XCTAssertFalse(policy.shouldCapture(timestamp: 10.1, transform: moved))
        // Passou 1 s, mas não saiu do lugar.
        XCTAssertFalse(policy.shouldCapture(timestamp: 11, transform: matrix_identity_float4x4))
        // Passou 1 s e andou só 10 cm (limiar é 15 cm).
        XCTAssertFalse(policy.shouldCapture(timestamp: 11, transform: TestMeshes.translation(0.1, 0, 0)))
        // Tempo e deslocamento suficientes.
        XCTAssertTrue(policy.shouldCapture(timestamp: 11, transform: moved))
    }

    func testRotationAloneIsEnough() {
        var policy = KeyframePolicy(settings: KeyframeSettings())
        policy.markCaptured(timestamp: 0, transform: matrix_identity_float4x4)

        // Giro de 90 graus em Y sem sair do lugar.
        let rotated = TestMeshes.rotationY90(translation: SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(KeyframePolicy.angleDegrees(matrix_identity_float4x4, rotated), 90, accuracy: 1e-3)
        XCTAssertTrue(policy.shouldCapture(timestamp: 1, transform: rotated))
    }

    func testRelaxDoublesThresholds() {
        var policy = KeyframePolicy(settings: KeyframeSettings())
        policy.markCaptured(timestamp: 0, transform: matrix_identity_float4x4)
        policy.relax()

        XCTAssertEqual(policy.settings.minDistance, 0.30, accuracy: 1e-6)
        XCTAssertEqual(policy.settings.minAngleDegrees, 30, accuracy: 1e-6)
        // 20 cm bastava antes; depois de relaxar não basta mais.
        XCTAssertFalse(policy.shouldCapture(timestamp: 5, transform: TestMeshes.translation(0.2, 0, 0)))
        XCTAssertTrue(policy.shouldCapture(timestamp: 5, transform: TestMeshes.translation(0.35, 0, 0)))
    }
}

final class DepthMapFileTests: XCTestCase {

    func testRoundTripWithConfidence() throws {
        let meters: [Float] = [0.5, 1.234, 0, Float.nan, 4.9996, 100]
        let map = DepthMap(width: 3, height: 2,
                           depthMillimeters: DepthMap.millimeters(fromMeters: meters),
                           confidence: [0, 1, 2, 2, 1, 0])
        XCTAssertEqual(map.depthMillimeters, [500, 1234, 0, 0, 5000, 65535])

        let data = try DepthMapFile.encode(map)
        // magic (8) + largura e altura (4) + flag (1) + 6 * 2 + 6
        XCTAssertEqual(data.count, 8 + 4 + 1 + 12 + 6)
        XCTAssertEqual(try DepthMapFile.decode(data), map)

        XCTAssertEqual(map.meters(column: 1, row: 0), 1.234)
        XCTAssertNil(map.meters(column: 2, row: 0)) // zero = sem medida
        XCTAssertNil(map.meters(column: 3, row: 0)) // fora do mapa
    }

    func testRoundTripWithoutConfidence() throws {
        let map = DepthMap(width: 2, height: 1, depthMillimeters: [10, 20], confidence: [])
        let data = try DepthMapFile.encode(map)
        XCTAssertEqual(data.count, 8 + 4 + 1 + 4)
        XCTAssertEqual(try DepthMapFile.decode(data), map)
    }

    func testWrongSizeIsRejected() {
        let map = DepthMap(width: 2, height: 2, depthMillimeters: [1, 2, 3], confidence: [])
        XCTAssertThrowsError(try DepthMapFile.encode(map))
    }
}

final class VertexColorizerTests: XCTestCase {

    /// Quadrado de 1 m no chão (normal +Y), entre (0,0,0) e (1,0,1).
    private func floorMesh() -> WorldMesh {
        return MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
    }

    func testImageSampling() throws {
        // 2 x 1: pixel esquerdo preto, direito branco.
        let image = try XCTUnwrap(RGBAImage(width: 2, height: 1, pixels: [0, 0, 0, 255, 255, 255, 255, 255]))
        XCTAssertEqual(image.sample(x: 0.5, y: 0.5).r, 0)
        XCTAssertEqual(image.sample(x: 1.5, y: 0.5).r, 255)
        // No meio dos dois centros: metade do caminho.
        XCTAssertEqual(image.sample(x: 1.0, y: 0.5).r, 128)
        // Fora da imagem: usa a borda.
        XCTAssertEqual(image.sample(x: -10, y: 0.5).r, 0)
        XCTAssertEqual(image.sample(x: 99, y: 7).r, 255)
        XCTAssertNil(RGBAImage(width: 2, height: 2, pixels: [1, 2, 3]))
    }

    func testVerticesTakeColorFromCameraThatFacesThem() throws {
        var mesh = floorMesh()
        // Câmera 0: acima do piso, olhando para baixo (vê a face de frente). Imagem vermelha.
        // Câmera 1: abaixo do piso, olhando para cima (vê o lado de trás). Imagem verde.
        let cameras = [
            TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(0.5, 2, 0.5))),
            TestCameras.camera(transform: TestCameras.lookingUp(from: SIMD3<Float>(0.5, -1, 0.5)))
        ]
        let images = [TestCameras.solidImage(r: 200, g: 10, b: 10), TestCameras.solidImage(r: 10, g: 200, b: 10)]

        let assignment = VertexColorizer.assignKeyframes(mesh: mesh, cameras: cameras)
        // A câmera de baixo está mais perto, mas vê a superfície por trás: não pode ganhar.
        XCTAssertEqual(assignment, [0, 0, 0, 0])

        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras) { index in
            return images[index]
        }

        XCTAssertEqual(report, ColorizeReport(coloredDirectly: 4, filledFromNeighbors: 0, uncolored: 0, framesUsed: 1))
        let colors = try XCTUnwrap(mesh.colors)
        XCTAssertEqual(colors, [200, 10, 10, 200, 10, 10, 200, 10, 10, 200, 10, 10])
        XCTAssertTrue(mesh.isConsistent)
    }

    func testVertexOutOfRangeIsFilledFromNeighbors() throws {
        var mesh = floorMesh()
        // Leva o vértice 3 para 30 m de distância: nenhum keyframe alcança.
        mesh.positions[9] = 30
        let cameras = [TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(0.5, 2, 0.5)))]

        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras) { _ in
            return TestCameras.solidImage(r: 50, g: 60, b: 70)
        }

        XCTAssertEqual(report.coloredDirectly, 3)
        XCTAssertEqual(report.filledFromNeighbors, 1)
        XCTAssertEqual(report.uncolored, 0)
        let colors = try XCTUnwrap(mesh.colors)
        XCTAssertEqual(Array(colors[9..<12]), [50, 60, 70])
    }

    func testWithoutImagesVerticesStayGray() throws {
        var mesh = floorMesh()
        let cameras = [TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(0.5, 2, 0.5)))]

        let report = VertexColorizer.colorize(mesh: &mesh, cameras: cameras) { _ in
            return nil
        }

        XCTAssertEqual(report, ColorizeReport(coloredDirectly: 0, filledFromNeighbors: 0, uncolored: 4, framesUsed: 0))
        XCTAssertEqual(try XCTUnwrap(mesh.colors), [UInt8](repeating: 128, count: 12))
    }

    func testNoCamerasLeavesEverythingUnassigned() {
        let assignment = VertexColorizer.assignKeyframes(mesh: floorMesh(), cameras: [])
        XCTAssertEqual(assignment, [-1, -1, -1, -1])
    }

    func testGrazingAngleIsRejected() {
        // Câmera quase rente ao piso: o cosseno com a normal fica abaixo do mínimo.
        let camera = TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(5.5, 0.1, 0.5)))
        let value = VertexColorizer.score(camera: camera,
                                          point: SIMD3<Float>(0.5, 0, 0.5),
                                          normal: SIMD3<Float>(0, 1, 0),
                                          options: ColorizeOptions())
        XCTAssertNil(value)
    }
}
