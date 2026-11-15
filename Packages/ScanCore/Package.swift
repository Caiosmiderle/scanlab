// swift-tools-version:5.9
import PackageDescription

// ScanCore: toda a lógica testável do ScanLab (escritores de arquivo, conversão de
// eixos, projeção de câmera, planta SVG). Só Foundation e simd, SEM ARKit, para que
// os testes rodem com `swift test` no runner macOS do CI.
let package = Package(
    name: "ScanCore",
    // Manter a versão do iOS igual ao deploymentTarget do project.yml.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"])
    ],
    targets: [
        .target(name: "ScanCore"),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"])
    ]
)
