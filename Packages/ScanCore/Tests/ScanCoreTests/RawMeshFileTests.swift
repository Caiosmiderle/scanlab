import XCTest
import simd
@testable import ScanCore

final class RawMeshFileTests: XCTestCase {

    func testRoundTripKeepsEverything() throws {
        let anchors = [
            TestMeshes.triangleAnchor(transform: TestMeshes.translation(1, 2, 3), classification: 5),
            TestMeshes.quadAnchor(transform: TestMeshes.rotationY90(translation: SIMD3<Float>(-4, 0.5, 2)))
        ]

        let sink = MemorySink()
        try RawMeshFile.write(anchors: anchors, to: sink)
        let decoded = try RawMeshFile.read(from: sink.data)

        XCTAssertEqual(decoded, anchors)
    }

    func testFileSizeMatchesSpecification() throws {
        let anchor = TestMeshes.quadAnchor()
        let sink = MemorySink()
        try RawMeshFile.write(anchors: [anchor], to: sink)

        // magic (8) + contagem (4) + uuid (16) + transform (64) + contagens (8)
        // + vértices (4*3*4) + normais (4*3*4) + faces (2*3*4) + classificação (2)
        let expected = 8 + 4 + 16 + 64 + 8 + 48 + 48 + 24 + 2
        XCTAssertEqual(sink.data.count, expected)
        XCTAssertEqual(Array(sink.data.prefix(8)), Array("SLMESH01".utf8))
    }

    func testEmptyListRoundTrip() throws {
        let sink = MemorySink()
        try RawMeshFile.write(anchors: [], to: sink)
        XCTAssertEqual(sink.data.count, 12)
        XCTAssertEqual(try RawMeshFile.read(from: sink.data), [])
    }

    func testWrongMagicIsRejected() {
        var data = Data("XXMESH01".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try RawMeshFile.read(from: data)) { error in
            XCTAssertEqual(error as? ScanCoreError, ScanCoreError.invalidMagic)
        }
    }

    func testTruncatedFileIsRejected() throws {
        let sink = MemorySink()
        try RawMeshFile.write(anchors: [TestMeshes.quadAnchor()], to: sink)
        let truncated = sink.data.prefix(sink.data.count - 10)

        XCTAssertThrowsError(try RawMeshFile.read(from: Data(truncated))) { error in
            XCTAssertEqual(error as? ScanCoreError, ScanCoreError.truncatedFile)
        }
    }

    func testInconsistentAnchorIsNotWritten() {
        var anchor = TestMeshes.triangleAnchor()
        anchor.indices = [0, 1, 7] // índice fora da lista de vértices
        XCTAssertFalse(anchor.isConsistent)
        XCTAssertThrowsError(try RawMeshFile.write(anchors: [anchor], to: MemorySink()))
    }

    func testFileSinkWritesToDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scancore-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let anchors = [TestMeshes.triangleAnchor(), TestMeshes.quadAnchor()]
        let sink = try FileSink(url: url)
        try RawMeshFile.write(anchors: anchors, to: sink)
        try sink.close()

        XCTAssertEqual(try RawMeshFile.read(contentsOf: url), anchors)
    }
}
