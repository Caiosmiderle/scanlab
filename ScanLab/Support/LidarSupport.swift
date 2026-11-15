import ARKit

/// Resultado da verificação de suporte à reconstrução de cena (malha do LiDAR).
enum LidarStatus {
    /// Malha com classificação por face (parede, piso, teto, mesa...). É o modo que o M1 usa.
    case meshWithClassification
    /// Só a malha, sem classificação. O M1 cai para este modo se o primeiro não existir.
    case meshOnly
    /// O ARKit não oferece reconstrução de cena neste aparelho (sem LiDAR).
    case unavailable

    var isAvailable: Bool {
        switch self {
        case .meshWithClassification, .meshOnly:
            return true
        case .unavailable:
            return false
        }
    }

    var title: String {
        return isAvailable ? "LiDAR disponível" : "LiDAR indisponível"
    }

    var detail: String {
        switch self {
        case .meshWithClassification:
            return "Reconstrução de malha com classificação suportada."
        case .meshOnly:
            return "Reconstrução de malha suportada, mas sem classificação de superfícies."
        case .unavailable:
            return "Este aparelho não oferece reconstrução de cena pelo ARKit. O ScanLab precisa de um iPad ou iPhone com sensor LiDAR."
        }
    }
}

enum LidarSupport {
    /// A reconstrução de cena do ARKit só existe em aparelhos com LiDAR, então esta
    /// consulta serve como teste de presença do sensor. Não abre a câmera nem pede
    /// permissão: apenas pergunta ao ARKit o que o hardware suporta.
    static func check() -> LidarStatus {
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            return .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            return .meshOnly
        }
        return .unavailable
    }
}
