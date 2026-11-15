import Foundation

/// Textos do estado térmico do aparelho (seção 6.4).
/// Escanear com LiDAR esquenta: em `.serious` o app avisa e em `.critical` ele
/// finaliza o scan sozinho para não perder o que já foi capturado.
enum ThermalMonitor {
    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "Normal"
        case .fair:
            return "Morno"
        case .serious:
            return "Quente"
        case .critical:
            return "Crítico"
        default:
            return "Desconhecido"
        }
    }

    static func isWarning(_ state: ProcessInfo.ThermalState) -> Bool {
        return state == .serious || state == .critical
    }
}
