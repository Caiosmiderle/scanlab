import XCTest
import simd
import CoreGraphics
import ImageIO
@testable import ScanCore

/// Malhas e imagens sintéticas para os testes de processamento (M7).
enum ProcessingFixtures {
    /// Plano horizontal (normal +Y) com `cells` x `cells` quadrados de lado `spacing`.
    static func grid(cells: Int, spacing: Float) -> WorldMesh {
        let side = cells + 1
        var positions: [Float] = []
        var normals: [Float] = []
        for j in 0..<side {
            for i in 0..<side {
                positions.append(contentsOf: [Float(i) * spacing, 0, Float(j) * spacing])
                normals.append(contentsOf: [0, 1, 0])
            }
        }
        var indices: [UInt32] = []
        for j in 0..<cells {
            for i in 0..<cells {
                let a = UInt32(j * side + i)
                let b = a + 1
                let d = UInt32((j + 1) * side + i)
                let c = d + 1
                // Mesmo sentido do quadrado de teste: normal para cima.
                indices.append(contentsOf: [a, c, b, a, d, c])
            }
        }
        return WorldMesh(positions: positions,
                         normals: normals,
                         indices: indices,
                         classifications: [UInt8](repeating: 2, count: cells * cells * 2))
    }

    /// Imagem 64 x 48 em degradê: vermelho cresce com a coluna, verde com a linha.
    static func gradientImage() -> RGBAImage? {
        let width = 64
        let height = 48
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 4)
                pixels[offset + 1] = UInt8(y * 5)
                pixels[offset + 2] = 50
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func cameraAbove(x: Float, z: Float, height: Float) -> CameraModel {
        return TestCameras.camera(transform: TestCameras.lookingDown(from: SIMD3<Float>(x, height, z)))
    }

    /// Codifica uma imagem RGBA em JPEG (só nos testes, que rodam no macOS).
    static func jpegData(_ image: RGBAImage) -> Data? {
        let data = Data(image.pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: image.width,
                                    height: image.height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

final class MeshProcessingTests: XCTestCase {

    func testClusterKeepsVerticesInDifferentCells() {
        let mesh = MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
        let result = MeshProcessing.cluster(mesh, cellSize: 0.3)
        XCTAssertEqual(result.vertexCount, 4)
        XCTAssertEqual(result.faceCount, 2)
        XCTAssertTrue(result.isConsistent)
    }

    func testClusterMergesVerticesInTheSameCell() {
        // Plano de 1 m com vértices a cada 5 cm, agrupado em células de 20 cm.
        let mesh = ProcessingFixtures.grid(cells: 20, spacing: 0.05)
        XCTAssertEqual(mesh.vertexCount, 441)
        XCTAssertEqual(mesh.faceCount, 800)

        let result = MeshProcessing.cluster(mesh, cellSize: 0.2)

        XCTAssertTrue(result.isConsistent)
        XCTAssertLessThan(result.vertexCount, 60)
        XCTAssertLessThan(result.faceCount, 120)
        XCTAssertGreaterThan(result.faceCount, 10)
        // A redução não tira o plano do lugar nem vira as normais.
        for vertex in 0..<result.vertexCount {
            XCTAssertEqual(result.positions[vertex * 3 + 1], 0, accuracy: 1e-6)
            XCTAssertEqual(result.normals[vertex * 3 + 1], 1, accuracy: 1e-5)
        }
        XCTAssertEqual(result.classifications.count, result.faceCount)
    }

    func testAverageEdgeLength() {
        // Cada quadrado de 5 cm tem dois lados de 5 cm e uma diagonal de 7,07 cm por triângulo.
        let mesh = ProcessingFixtures.grid(cells: 10, spacing: 0.05)
        XCTAssertEqual(MeshProcessing.averageEdgeLength(mesh), (0.05 + 0.05 + 0.0707107) / 3, accuracy: 1e-4)
        XCTAssertEqual(MeshProcessing.averageEdgeLength(MeshBuilder.worldMesh(from: [])), 0)
    }

    func testReduceGetsCloseToHalf() {
        let mesh = ProcessingFixtures.grid(cells: 40, spacing: 0.05)
        XCTAssertEqual(mesh.faceCount, 3200)

        let reduced = MeshProcessing.reduce(mesh, targetRatio: 0.5)

        XCTAssertTrue(reduced.isConsistent)
        // O agrupamento em grade não acerta o número exato: aceita de 25% a 75%.
        XCTAssertGreaterThan(reduced.faceCount, 800)
        XCTAssertLessThan(reduced.faceCount, 2400)
        XCTAssertLessThan(reduced.vertexCount, mesh.vertexCount)
        // O tamanho total do plano fica quase igual.
        let original = mesh.bounds()
        let after = reduced.bounds()
        XCTAssertEqual(after?.max.x ?? 0, original?.max.x ?? 1, accuracy: 0.1)
        XCTAssertEqual(after?.max.z ?? 0, original?.max.z ?? 1, accuracy: 0.1)
    }

    func testReduceWithInvalidRatioChangesNothing() {
        let mesh = ProcessingFixtures.grid(cells: 4, spacing: 0.1)
        XCTAssertEqual(MeshProcessing.reduce(mesh, targetRatio: 1.5).faceCount, mesh.faceCount)
        XCTAssertEqual(MeshProcessing.reduce(mesh, targetRatio: 0).faceCount, mesh.faceCount)
    }

    func testSmoothLowersASpikeAndKeepsTheBorder() {
        var mesh = ProcessingFixtures.grid(cells: 6, spacing: 0.1)
        // Vértice do meio (linha 3, coluna 3) levantado 10 cm: um "espinho" de ruído.
        let spike = 3 * 7 + 3
        mesh.positions[spike * 3 + 1] = 0.1

        let smoothed = MeshProcessing.smooth(mesh, iterations: 3, factor: 0.5)

        XCTAssertTrue(smoothed.isConsistent)
        XCTAssertLessThan(smoothed.positions[spike * 3 + 1], 0.05)
        XCTAssertGreaterThan(smoothed.positions[spike * 3 + 1], 0)
        // A borda não se mexe: o primeiro vértice continua em (0, 0, 0) e o último no canto.
        XCTAssertEqual(Array(smoothed.positions[0..<3]), [0, 0, 0])
        let last = smoothed.vertexCount - 1
        XCTAssertEqual(smoothed.positions[last * 3], 0.6, accuracy: 1e-6)
        XCTAssertEqual(smoothed.positions[last * 3 + 2], 0.6, accuracy: 1e-6)
        // Normais refeitas e unitárias.
        for vertex in 0..<smoothed.vertexCount {
            let normal = SIMD3<Float>(smoothed.normals[vertex * 3], smoothed.normals[vertex * 3 + 1], smoothed.normals[vertex * 3 + 2])
            XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-4)
        }
    }

    func testSmoothKeepsAFlatPlaneFlat() {
        let mesh = ProcessingFixtures.grid(cells: 5, spacing: 0.1)
        let smoothed = MeshProcessing.smooth(mesh)
        for vertex in 0..<smoothed.vertexCount {
            XCTAssertEqual(smoothed.positions[vertex * 3 + 1], 0, accuracy: 1e-6)
            XCTAssertEqual(smoothed.normals[vertex * 3 + 1], 1, accuracy: 1e-5)
        }
    }
}

final class TextureAtlasTests: XCTestCase {

    private func floorMesh() -> WorldMesh {
        return MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()])
    }

    func testShelfPacking() throws {
        let sizes: [(width: Int, height: Int)] = [(40, 20), (30, 50), (60, 10), (20, 20)]
        let positions = try XCTUnwrap(ShelfPacker.pack(sizes: sizes, atlasSize: 100))

        for index in 0..<sizes.count {
            XCTAssertGreaterThanOrEqual(positions[index].x, 0)
            XCTAssertGreaterThanOrEqual(positions[index].y, 0)
            XCTAssertLessThanOrEqual(positions[index].x + sizes[index].width, 100)
            XCTAssertLessThanOrEqual(positions[index].y + sizes[index].height, 100)
        }
        // Nenhum par de retângulos se sobrepõe.
        for first in 0..<sizes.count {
            for second in (first + 1)..<sizes.count {
                let separated = positions[first].x + sizes[first].width <= positions[second].x
                    || positions[second].x + sizes[second].width <= positions[first].x
                    || positions[first].y + sizes[first].height <= positions[second].y
                    || positions[second].y + sizes[second].height <= positions[first].y
                XCTAssertTrue(separated, "retângulos \(first) e \(second) se sobrepõem")
            }
        }

        XCTAssertNil(ShelfPacker.pack(sizes: [(200, 10)], atlasSize: 100))
        XCTAssertNil(ShelfPacker.pack(sizes: [(80, 80), (80, 80)], atlasSize: 100))
    }

    /// Confere, para cada vértice, que a cor do atlas no UV dele é a cor da foto no
    /// ponto onde o vértice aparece. É o teste de ponta a ponta do atlas.
    private func assertAtlasMatchesImage(_ result: TextureAtlasResult,
                                         camera: CameraModel,
                                         image: RGBAImage,
                                         tolerance: Int,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let size = Float(result.atlas.width)
        for vertex in 0..<result.mesh.vertexCount {
            let position = SIMD3<Float>(result.mesh.positions[vertex * 3], result.mesh.positions[vertex * 3 + 1], result.mesh.positions[vertex * 3 + 2])
            guard let projected = camera.project(position) else {
                XCTFail("vértice \(vertex) fora da foto", file: file, line: line)
                continue
            }
            let expected = image.sample(x: projected.u, y: projected.v)
            let actual = result.atlas.sample(x: result.mesh.uvs[vertex * 2] * size, y: result.mesh.uvs[vertex * 2 + 1] * size)
            XCTAssertLessThanOrEqual(abs(Int(actual.r) - Int(expected.r)), tolerance, "vermelho do vértice \(vertex)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(Int(actual.g) - Int(expected.g)), tolerance, "verde do vértice \(vertex)", file: file, line: line)
        }
    }

    func testAtlasCopiesThePhotoUnderEachVertex() throws {
        let image = try XCTUnwrap(ProcessingFixtures.gradientImage())
        let camera = ProcessingFixtures.cameraAbove(x: 0.5, z: 0.5, height: 2)

        let result = TextureAtlasBuilder.build(mesh: floorMesh(),
                                               cameras: [camera],
                                               options: TextureAtlasOptions(atlasSize: 64, padding: 2)) { _ in
            return image
        }

        XCTAssertEqual(result.report, TextureAtlasReport(chartCount: 1, texturedFaces: 2, untexturedFaces: 0, camerasUsed: 1, scale: 1))
        XCTAssertTrue(result.mesh.isConsistent)
        XCTAssertEqual(result.mesh.vertexCount, 4)
        XCTAssertEqual(result.mesh.faceCount, 2)
        XCTAssertEqual(result.atlas.width, 64)
        for value in result.mesh.uvs {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
        assertAtlasMatchesImage(result, camera: camera, image: image, tolerance: 3)
    }

    func testAtlasShrinksThePhotoWhenItDoesNotFit() throws {
        let image = try XCTUnwrap(ProcessingFixtures.gradientImage())
        let camera = ProcessingFixtures.cameraAbove(x: 0.5, z: 0.5, height: 2)

        // O recorte tem 28 px mais a margem; num atlas de 32 px ele precisa ser reduzido.
        let result = TextureAtlasBuilder.build(mesh: floorMesh(),
                                               cameras: [camera],
                                               options: TextureAtlasOptions(atlasSize: 32, padding: 2)) { _ in
            return image
        }

        XCTAssertEqual(result.report.texturedFaces, 2)
        XCTAssertLessThan(result.report.scale, 1)
        XCTAssertGreaterThan(result.report.scale, 0.3)
        // Reduzido, o degradê continua no lugar, com um pouco mais de erro.
        assertAtlasMatchesImage(result, camera: camera, image: image, tolerance: 12)
    }

    func testFacesWithoutPhotoUseTheGrayBlock() {
        let result = TextureAtlasBuilder.build(mesh: floorMesh(), cameras: [], options: TextureAtlasOptions(atlasSize: 32)) { _ in
            return nil
        }

        XCTAssertEqual(result.report, TextureAtlasReport(chartCount: 0, texturedFaces: 0, untexturedFaces: 2, camerasUsed: 0, scale: 1))
        XCTAssertEqual(result.mesh.faceCount, 2)
        XCTAssertEqual(result.mesh.vertexCount, 4)
        let color = result.atlas.sample(x: result.mesh.uvs[0] * 32, y: result.mesh.uvs[1] * 32)
        XCTAssertEqual(color.r, 128)
        XCTAssertEqual(color.g, 128)
    }

    func testEachRegionUsesItsOwnPhoto() throws {
        // Dois quadrados a 10 m um do outro, cada um com uma câmera em cima.
        let mesh = MeshBuilder.worldMesh(from: [
            TestMeshes.quadAnchor(),
            TestMeshes.quadAnchor(transform: TestMeshes.translation(10, 0, 0))
        ])
        let cameras = [ProcessingFixtures.cameraAbove(x: 0.5, z: 0.5, height: 2),
                       ProcessingFixtures.cameraAbove(x: 10.5, z: 0.5, height: 2)]
        let images = [TestCameras.solidImage(r: 220, g: 20, b: 20), TestCameras.solidImage(r: 20, g: 20, b: 220)]

        let result = TextureAtlasBuilder.build(mesh: mesh, cameras: cameras, options: TextureAtlasOptions(atlasSize: 128, padding: 2)) { index in
            return images[index]
        }

        XCTAssertEqual(result.report.chartCount, 2)
        XCTAssertEqual(result.report.texturedFaces, 4)
        XCTAssertEqual(result.report.camerasUsed, 2)
        XCTAssertEqual(result.mesh.vertexCount, 8)
        for vertex in 0..<result.mesh.vertexCount {
            let color = result.atlas.sample(x: result.mesh.uvs[vertex * 2] * 128, y: result.mesh.uvs[vertex * 2 + 1] * 128)
            if result.mesh.positions[vertex * 3] < 5 {
                XCTAssertEqual(color.r, 220)
                XCTAssertEqual(color.b, 20)
            } else {
                XCTAssertEqual(color.r, 20)
                XCTAssertEqual(color.b, 220)
            }
        }
    }

    func testMissingImageLeavesThoseFacesGray() {
        let camera = ProcessingFixtures.cameraAbove(x: 0.5, z: 0.5, height: 2)
        let result = TextureAtlasBuilder.build(mesh: floorMesh(), cameras: [camera], options: TextureAtlasOptions(atlasSize: 64)) { _ in
            return nil
        }
        XCTAssertEqual(result.report.texturedFaces, 0)
        XCTAssertEqual(result.report.untexturedFaces, 2)
        XCTAssertEqual(result.report.camerasUsed, 0)
    }

    func testTexturedMeshAxisConversion() {
        var mesh = TexturedMesh(positions: [1, 2, 3], normals: [0, 1, 0], uvs: [0.25, 0.75], indices: [])
        mesh.applyAxis(.zUp)
        XCTAssertEqual(mesh.positions, [1, -3, 2])
        XCTAssertEqual(mesh.normals, [0, 0, 1])
        XCTAssertEqual(mesh.uvs, [0.25, 0.75])
    }
}

final class TexturedWriterTests: XCTestCase {

    private func texturedQuad() throws -> (mesh: TexturedMesh, atlas: RGBAImage) {
        let image = try XCTUnwrap(ProcessingFixtures.gradientImage())
        let camera = ProcessingFixtures.cameraAbove(x: 0.5, z: 0.5, height: 2)
        let result = TextureAtlasBuilder.build(mesh: MeshBuilder.worldMesh(from: [TestMeshes.quadAnchor()]),
                                               cameras: [camera],
                                               options: TextureAtlasOptions(atlasSize: 64, padding: 2)) { _ in
            return image
        }
        return (result.mesh, result.atlas)
    }

    func testTexturedOBJ() throws {
        let textured = try texturedQuad()
        let sink = MemorySink()
        try TexturedWriters.writeOBJ(textured.mesh, to: sink, materialLibraryName: "scan.mtl")
        let lines = String(decoding: sink.data, as: UTF8.self).split(separator: "\n").map { String($0) }

        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, 4)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vt ") }.count, 4)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vn ") }.count, 4)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, 2)
        XCTAssertTrue(lines.contains("mtllib scan.mtl"))
        XCTAssertTrue(lines.contains("f 1/1/1 2/2/2 3/3/3"))

        let material = TexturedWriters.materialFileContents(textureFileName: "scan.jpg")
        XCTAssertTrue(material.contains("map_Kd scan.jpg\n"))
        XCTAssertTrue(material.contains("newmtl scanlab\n"))
    }

    func testOBJFlipsTheVCoordinate() throws {
        let mesh = TexturedMesh(positions: [0, 0, 0], normals: [0, 1, 0], uvs: [0.25, 0.2], indices: [])
        let sink = MemorySink()
        try TexturedWriters.writeOBJ(mesh, to: sink, materialLibraryName: "a.mtl")
        // V do glTF 0,2 (a partir do topo) vira 0,8 no OBJ (a partir de baixo).
        XCTAssertTrue(String(decoding: sink.data, as: UTF8.self).contains("vt 0.25000 0.80000\n"))
    }

    func testTexturedGLBStructure() throws {
        let textured = try texturedQuad()
        // Qualquer sequência de bytes serve para conferir a estrutura; 5 bytes testam o alinhamento.
        let fakeImage = Data([1, 2, 3, 4, 5])
        let sink = MemorySink()
        try TexturedWriters.writeGLB(textured.mesh, imageData: fakeImage, to: sink)
        let data = sink.data

        XCTAssertEqual(Array(data.prefix(4)), Array("glTF".utf8))
        XCTAssertEqual(data.count % 4, 0)
        let jsonLength = Int(UInt32(bitPattern: TestMeshes.int32(in: data, at: 12)))
        let jsonData = data.subdata(in: (data.startIndex + 20)..<(data.startIndex + 20 + jsonLength))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        // 4 vértices: posições 48 + normais 48 + UVs 32 + 6 índices 24 = 152; imagem 5 + 3 de alinhamento.
        let buffers = try XCTUnwrap(object["buffers"] as? [[String: Any]])
        XCTAssertEqual(buffers[0]["byteLength"] as? Int, 160)
        let views = try XCTUnwrap(object["bufferViews"] as? [[String: Any]])
        XCTAssertEqual(views.count, 5)
        XCTAssertEqual(views[4]["byteOffset"] as? Int, 152)
        XCTAssertEqual(views[4]["byteLength"] as? Int, 5)
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])
        XCTAssertEqual(images[0]["mimeType"] as? String, "image/jpeg")
        let meshes = try XCTUnwrap(object["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes[0]["primitives"] as? [[String: Any]])
        let attributes = try XCTUnwrap(primitives[0]["attributes"] as? [String: Int])
        XCTAssertEqual(attributes, ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2])

        // Os bytes da imagem estão no lugar indicado.
        let binStart = 20 + jsonLength + 8
        XCTAssertEqual(Array(data[(data.startIndex + binStart + 152)..<(data.startIndex + binStart + 157)]), [1, 2, 3, 4, 5])
        XCTAssertEqual(data.count, binStart + 160)
    }

    /// Grava um GLB texturizado de verdade (com JPEG) para o validador da Khronos no CI.
    func testWritesSampleTexturedGLB() throws {
        let textured = try texturedQuad()
        let jpeg = try XCTUnwrap(ProcessingFixtures.jpegData(textured.atlas))
        XCTAssertGreaterThan(jpeg.count, 100)

        let memory = MemorySink()
        try TexturedWriters.writeGLB(textured.mesh, imageData: jpeg, to: memory)
        XCTAssertGreaterThan(memory.data.count, jpeg.count)

        guard let directory = ProcessInfo.processInfo.environment["SCANLAB_SAMPLE_DIR"], !directory.isEmpty else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try memory.data.write(to: folder.appendingPathComponent("amostra-texturizada.glb"))
        try jpeg.write(to: folder.appendingPathComponent("amostra-atlas.jpg"))
    }
}
