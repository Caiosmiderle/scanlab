import Foundation
import ScanCore

/// Formatos que o ScanLab sabe gerar (seção 5.1 da especificação).
enum ExportFormat: String, CaseIterable, Identifiable {
    // Malha
    case plyMesh
    case obj
    case glb
    case gltf
    case usdz
    case stl
    case dae
    // Nuvem de pontos
    case plyCloud
    case las
    case pts
    case xyz
    case pcdBinary
    case pcdAscii

    var id: String {
        return rawValue
    }

    var isCloud: Bool {
        switch self {
        case .plyCloud, .las, .pts, .xyz, .pcdBinary, .pcdAscii:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .plyMesh: return "PLY (malha)"
        case .obj: return "OBJ + MTL"
        case .glb: return "GLB"
        case .gltf: return "glTF + BIN"
        case .usdz: return "USDZ"
        case .stl: return "STL"
        case .dae: return "DAE (Collada)"
        case .plyCloud: return "PLY (nuvem)"
        case .las: return "LAS 1.2"
        case .pts: return "PTS"
        case .xyz: return "XYZ"
        case .pcdBinary: return "PCD binário"
        case .pcdAscii: return "PCD texto"
        }
    }

    var detail: String {
        switch self {
        case .plyMesh: return "CloudCompare, MeshLab. Cor e classificação por face."
        case .obj: return "Blender, MeshLab, quase tudo. Cor por vértice."
        case .glb: return "Um arquivo só. Blender, viewers web, Windows."
        case .gltf: return "Mesmo conteúdo do GLB, em dois arquivos."
        case .usdz: return "iPhone, iPad e Mac: abre em AR pelo app Arquivos."
        case .stl: return "Impressão 3D. Sem cor."
        case .dae: return "SketchUp. Cor por vértice."
        case .plyCloud: return "Nuvem para CloudCompare e MeshLab."
        case .las: return "CloudCompare, ReCap, Revit (via ReCap)."
        case .pts: return "Texto: x y z intensidade r g b."
        case .xyz: return "Texto: x y z r g b."
        case .pcdBinary: return "PCL e CloudCompare."
        case .pcdAscii: return "PCL e CloudCompare, legível."
        }
    }

    /// Formatos em que o eixo "para cima" é fixado pelo padrão (sempre Y) e a escolha
    /// de eixo do usuário não se aplica.
    var isAlwaysYUp: Bool {
        return self == .glb || self == .gltf || self == .usdz
    }

    static var meshFormats: [ExportFormat] {
        return allCases.filter { !$0.isCloud }
    }

    static var cloudFormats: [ExportFormat] {
        return allCases.filter { $0.isCloud }
    }
}

/// Densidade da nuvem de pontos.
enum CloudDensity: String, CaseIterable, Identifiable {
    /// Um ponto por vértice da malha.
    case vertices
    case dense5cm
    case dense2cm
    case dense1cm

    var id: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .vertices: return "Vértices da malha"
        case .dense5cm: return "Densa, 5 cm"
        case .dense2cm: return "Densa, 2 cm"
        case .dense1cm: return "Densa, 1 cm"
        }
    }

    /// Espaçamento em metros; `nil` para usar só os vértices.
    var spacing: Float? {
        switch self {
        case .vertices: return nil
        case .dense5cm: return 0.05
        case .dense2cm: return 0.02
        case .dense1cm: return 0.01
        }
    }
}

/// Tudo o que define uma exportação. Fica registrado no `meta.json` do scan.
struct ExportOptions {
    var formats: Set<ExportFormat>
    var axis: UpAxis
    var colorize: Bool
    var useOcclusion: Bool
    /// Soldar vértices duplicados na divisa dos blocos do ARKit.
    var weld: Bool
    /// Remover pedaços soltos com poucos triângulos.
    var removeSmallComponents: Bool
    var cloudDensity: CloudDensity
    /// Atlas de textura para OBJ, GLB e USDZ.
    var texture: TextureProfile
    /// Reduzir a malha para cerca de metade dos triângulos.
    var reduce: Bool
    /// Suavizar o ruído do sensor.
    var smooth: Bool

    /// Componentes com menos triângulos que isto são removidos.
    static let smallComponentFaces = 40

    /// Formatos que recebem a versão texturizada quando a textura está ligada.
    static let texturedFormats: [ExportFormat] = [.obj, .glb, .usdz]

    /// Se a textura vai mesmo ser gerada: precisa estar ligada e ter um formato que a use.
    var wantsTexture: Bool {
        if texture == .off {
            return false
        }
        for format in ExportOptions.texturedFormats where formats.contains(format) {
            return true
        }
        return false
    }

    /// Resumo curto para o log e para o `meta.json`.
    var summary: String {
        let names = ExportFormat.allCases.filter { formats.contains($0) }.map { $0.rawValue }.joined(separator: ",")
        return "formatos=\(names) eixo=\(axis.rawValue) cor=\(colorize) oclusão=\(useOcclusion) soldar=\(weld) limpar=\(removeSmallComponents) reduzir=\(reduce) suavizar=\(smooth) textura=\(texture.rawValue) nuvem=\(cloudDensity.rawValue)"
    }

    /// Estimativa grosseira do tempo de processamento, em segundos.
    /// Os fatores vêm de uma medição no iPad Pro M2 (cor por vértice: 72 mil vértices
    /// com 142 fotos em 3 s) e servem só para dar ordem de grandeza.
    func estimatedSeconds(vertexCount: Int, faceCount: Int, keyframeCount: Int) -> Double {
        var vertices = Double(vertexCount)
        var faces = Double(faceCount)
        if reduce {
            vertices *= 0.5
            faces *= 0.5
        }
        let photos = Double(max(0, keyframeCount))
        var seconds = 1.0 + faces * 0.000004
        if smooth {
            seconds += faces * 0.000003
        }
        if reduce {
            seconds += Double(faceCount) * 0.00001
        }
        if colorize && photos > 0 {
            seconds += vertices * photos * 0.0000003
        }
        if wantsTexture && photos > 0 {
            seconds += faces * photos * 0.0000004
            seconds += Double(texture.atlasSize * texture.atlasSize) * 0.00000025
        }
        seconds += Double(formats.count) * faces * 0.000004
        if let spacing = cloudDensity.spacing, formats.contains(where: { $0.isCloud }) {
            // Mais pontos quanto menor o espaçamento.
            seconds += faces * 0.00002 * Double(0.02 / spacing)
        }
        return seconds
    }
}

extension AppSettings {
    static let defaultExportFormats = "plyMesh,obj"

    /// Lê as opções de exportação escolhidas em Ajustes e na tela de exportar.
    static var exportOptions: ExportOptions {
        let defaults = UserDefaults.standard
        let formatsText = defaults.string(forKey: SettingsKeys.exportFormats) ?? defaultExportFormats
        var formats: Set<ExportFormat> = []
        for name in formatsText.split(separator: ",") {
            if let format = ExportFormat(rawValue: String(name)) {
                formats.insert(format)
            }
        }
        let axis = UpAxis(rawValue: defaults.string(forKey: SettingsKeys.exportUpAxis) ?? "") ?? .zUp
        let density = CloudDensity(rawValue: defaults.string(forKey: SettingsKeys.cloudDensity) ?? "") ?? .vertices
        let texture = TextureProfile(rawValue: defaults.string(forKey: SettingsKeys.textureProfile) ?? "") ?? .off
        return ExportOptions(formats: formats,
                             axis: axis,
                             colorize: colorizeOnExport,
                             useOcclusion: useOcclusion,
                             weld: boolSetting(SettingsKeys.weldVertices, true),
                             removeSmallComponents: boolSetting(SettingsKeys.removeSmallComponents, true),
                             cloudDensity: density,
                             texture: texture,
                             reduce: boolSetting(SettingsKeys.reduceMesh, false),
                             smooth: boolSetting(SettingsKeys.smoothMesh, false))
    }

    static func boolSetting(_ key: String, _ fallback: Bool) -> Bool {
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return fallback
    }
}
