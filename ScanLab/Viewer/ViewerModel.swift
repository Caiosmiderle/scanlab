import Foundation
import SceneKit
import ScanCore

/// Modo de visualização da malha (marco M5).
enum ViewerMode: String, CaseIterable, Identifiable {
    /// Cinza, com iluminação.
    case flat
    /// Cor por vértice vinda das fotos.
    case textured
    /// A normal de cada ponto mostrada como cor.
    case normals
    /// Só as arestas dos triângulos.
    case wireframe

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .flat: return "Liso"
        case .textured: return "Cor"
        case .normals: return "Normais"
        case .wireframe: return "Arame"
        }
    }
}

/// Projeção da câmera do visualizador.
enum ViewerProjection: String, CaseIterable, Identifiable {
    case perspective
    case orthographic
    /// Vista de cima travada, com corte de altura para esconder o teto.
    case plan

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .perspective: return "Perspectiva"
        case .orthographic: return "Ortográfica"
        case .plan: return "Planta"
        }
    }
}

enum ViewerStandardView {
    case isometric
    case top
    case front
    case side
}

/// Um pedaço da malha, já como dados do SceneKit.
/// As fontes de posição, normal e índices são compartilhadas entre os modos de
/// visualização; trocar de modo só troca a fonte de cor e o material.
final class ViewerChunk {
    let positionSource: SCNGeometrySource
    let normalSource: SCNGeometrySource
    /// Cor das fotos; `nil` se o scan não tem cor.
    let colorSource: SCNGeometrySource?
    let normalColorSource: SCNGeometrySource
    let element: SCNGeometryElement
    let node = SCNNode()

    init(mesh: WorldMesh) {
        positionSource = SceneGeometry.vectorSource(mesh.positions, semantic: .vertex)
        normalSource = SceneGeometry.vectorSource(mesh.normals, semantic: .normal)
        if let colors = mesh.colors, colors.count == mesh.positions.count {
            colorSource = SceneGeometry.colorSource(colors)
        } else {
            colorSource = nil
        }
        normalColorSource = SceneGeometry.normalColorSource(mesh.normals)
        element = SceneGeometry.triangleElement(mesh.indices)
    }

    func geometry(for mode: ViewerMode) -> SCNGeometry {
        var sources = [positionSource, normalSource]
        let material = SCNMaterial()
        material.isDoubleSided = true

        switch mode {
        case .flat:
            material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            material.lightingModel = .blinn
        case .textured:
            if let colorSource = colorSource {
                sources.append(colorSource)
                // Sem iluminação: a cor da foto já tem a luz do ambiente real.
                material.diffuse.contents = UIColor.white
                material.lightingModel = .constant
            } else {
                material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
                material.lightingModel = .blinn
            }
        case .normals:
            sources.append(normalColorSource)
            material.diffuse.contents = UIColor.white
            material.lightingModel = .constant
        case .wireframe:
            material.diffuse.contents = UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1)
            material.lightingModel = .constant
            material.fillMode = .lines
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material]
        return geometry
    }
}

/// Tudo o que o visualizador precisa de um scan.
struct ViewerModel {
    var chunks: [ViewerChunk]
    /// A malha inteira (Y-up), guardada para o AR e para as próximas ferramentas.
    var mesh: WorldMesh
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var hasColors: Bool

    var center: SIMD3<Float> {
        return (boundsMin + boundsMax) / 2
    }

    var extent: SIMD3<Float> {
        return boundsMax - boundsMin
    }

    /// Meia diagonal da caixa: serve de "tamanho" do modelo para posicionar a câmera.
    var radius: Float {
        return max(0.5, simd_length(extent) / 2)
    }
}

enum ViewerError: Error, LocalizedError {
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .emptyMesh:
            return "A malha deste scan está vazia."
        }
    }
}

/// Carrega o scan para o visualizador. Síncrono e pesado: chamar fora da thread principal.
enum ViewerModelLoader {
    /// Lado da célula usada para dividir a malha em pedaços.
    private static let chunkSize: Float = 2.5

    static func load(scanID: String, progress: @escaping (Double, String) -> Void) throws -> ViewerModel {
        let started = Date()
        let store = ScanStore.shared

        progress(0.03, "Lendo o scan...")
        let anchors = try RawMeshFile.read(contentsOf: store.rawMeshURL(for: scanID))
        progress(0.10, "Montando a malha...")
        var mesh = MeshBuilder.worldMesh(from: anchors)
        mesh.removeUnusedAndInvalid()
        guard mesh.faceCount > 0, let limits = mesh.bounds() else {
            throw ViewerError.emptyMesh
        }

        // A cor é recalculada a cada abertura (alguns segundos). Fica assim de propósito
        // por enquanto: evita guardar um segundo arquivo que pode ficar desatualizado.
        progress(0.15, "Colorindo...")
        let report = ColorProcessor.colorize(mesh: &mesh, scanID: scanID, useOcclusion: AppSettings.useOcclusion) { fraction in
            progress(0.15 + 0.60 * fraction, "Colorindo...")
        }

        progress(0.78, "Preparando a cena...")
        let pieces = MeshChunker.split(mesh, cellSize: chunkSize)
        var chunks: [ViewerChunk] = []
        chunks.reserveCapacity(pieces.count)
        for position in 0..<pieces.count {
            chunks.append(ViewerChunk(mesh: pieces[position]))
            progress(0.78 + 0.20 * Double(position + 1) / Double(max(1, pieces.count)), "Preparando a cena...")
        }

        let seconds = Date().timeIntervalSince(started)
        AppLog.info(.processing, "Visualizador do scan \(scanID): vértices=\(mesh.vertexCount) faces=\(mesh.faceCount) pedaços=\(chunks.count) cor=\(report != nil ? "sim" : "não") tempo=\(String(format: "%.1f", seconds))s")
        progress(1.0, "Pronto")
        return ViewerModel(chunks: chunks,
                           mesh: mesh,
                           boundsMin: limits.min,
                           boundsMax: limits.max,
                           hasColors: report != nil)
    }
}
