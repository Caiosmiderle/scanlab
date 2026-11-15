import Foundation
import simd

/// Convenção de eixos usada na exportação.
public enum UpAxis: String, Codable, CaseIterable {
    /// Mundo do ARKit: Y para cima, alinhado à gravidade.
    case yUp
    /// Convenção de CAD (CloudCompare, Revit, SketchUp): Z para cima.
    case zUp
}

public enum AxisConversion {
    /// Converte um ponto ou vetor de Y-up (ARKit) para Z-up (CAD): (x, y, z) → (x, -z, y).
    ///
    /// É uma rotação de +90 graus em torno do eixo X, então preserva distâncias e a
    /// orientação dos triângulos (não espelha a cena). Por ser rotação pura, vale tanto
    /// para posições quanto para normais.
    public static func yUpToZUp(_ v: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(v.x, -v.z, v.y)
    }

    /// Inversa de `yUpToZUp`: (x, y, z) → (x, z, -y).
    public static func zUpToYUp(_ v: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(v.x, v.z, -v.y)
    }

    /// Aplica a convenção pedida a um vetor que está em Y-up.
    public static func convert(_ v: SIMD3<Float>, to axis: UpAxis) -> SIMD3<Float> {
        switch axis {
        case .yUp:
            return v
        case .zUp:
            return yUpToZUp(v)
        }
    }
}
