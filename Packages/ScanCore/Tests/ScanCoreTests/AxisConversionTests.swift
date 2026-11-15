import XCTest
import simd
@testable import ScanCore

final class AxisConversionTests: XCTestCase {

    func testVersionIsNotEmpty() {
        XCTAssertFalse(ScanCoreInfo.version.isEmpty)
    }

    func testYUpToZUpMapsAxes() {
        // O "para cima" do ARKit (+Y) tem de virar o "para cima" do CAD (+Z).
        XCTAssertEqual(AxisConversion.yUpToZUp(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 0, 1))
        // X não muda.
        XCTAssertEqual(AxisConversion.yUpToZUp(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(1, 0, 0))
        // +Z do ARKit (para trás da câmera inicial) vira -Y.
        XCTAssertEqual(AxisConversion.yUpToZUp(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(0, -1, 0))
        // Caso geral da especificação: (x, y, z) → (x, -z, y).
        XCTAssertEqual(AxisConversion.yUpToZUp(SIMD3<Float>(1, 2, 3)), SIMD3<Float>(1, -3, 2))
    }

    func testRoundTrip() {
        let p = SIMD3<Float>(1.5, -2.25, 3.75)
        XCTAssertEqual(AxisConversion.zUpToYUp(AxisConversion.yUpToZUp(p)), p)
    }

    func testConversionKeepsHandedness() {
        // Rotação pura: o produto vetorial dos eixos convertidos continua sendo o
        // terceiro eixo convertido. Se a conversão espelhasse a cena, os triângulos
        // exportados sairiam com a face virada para dentro.
        let x = AxisConversion.yUpToZUp(SIMD3<Float>(1, 0, 0))
        let y = AxisConversion.yUpToZUp(SIMD3<Float>(0, 1, 0))
        let z = AxisConversion.yUpToZUp(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(simd_cross(x, y), z)
    }

    func testConvertRespectsRequestedAxis() {
        let p = SIMD3<Float>(1, 2, 3)
        XCTAssertEqual(AxisConversion.convert(p, to: .yUp), p)
        XCTAssertEqual(AxisConversion.convert(p, to: .zUp), SIMD3<Float>(1, -3, 2))
    }
}
