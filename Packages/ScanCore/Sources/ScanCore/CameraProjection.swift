import Foundation
import simd

/// Resultado da projeção de um ponto do mundo na imagem de um keyframe.
public struct ProjectedPoint: Equatable {
    /// Coluna do pixel (origem no canto superior esquerdo, cresce para a direita).
    public var u: Float
    /// Linha do pixel (cresce para baixo).
    public var v: Float
    /// Distância ao longo do eixo óptico, em metros.
    public var depth: Float
}

/// Câmera de um keyframe, pronta para projetar pontos.
///
/// Convenção do ARKit (documentação de `ARCamera.transform` e `ARCamera.intrinsics`):
/// o espaço da câmera é fixo em relação ao aparelho. +X corre ao longo do lado
/// comprido, da câmera frontal em direção ao botão Home; +Y aponta para cima com o
/// aparelho deitado nessa posição; +Z sai do aparelho pelo lado da tela, então a
/// câmera traseira olha para -Z. (A documentação chama essa posição de
/// `UIDeviceOrientation.landscapeLeft`, que é a interface em landscape-right.)
/// A imagem (`capturedImage`) está nessa mesma orientação nativa do sensor, e as
/// intrínsecas são em pixels a partir do canto superior esquerdo. Por isso o sinal
/// de Y se inverte ao ir para a linha do pixel.
public struct CameraModel {
    public let worldToCamera: simd_float4x4
    /// Posição da câmera no mundo.
    public let position: SIMD3<Float>
    public let fx: Float
    public let fy: Float
    public let cx: Float
    public let cy: Float
    public let width: Float
    public let height: Float

    public init(transform: simd_float4x4, intrinsics: simd_float3x3, imageWidth: Int, imageHeight: Int) {
        worldToCamera = transform.inverse
        position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        fx = intrinsics.columns.0.x
        fy = intrinsics.columns.1.y
        cx = intrinsics.columns.2.x
        cy = intrinsics.columns.2.y
        width = Float(imageWidth)
        height = Float(imageHeight)
    }

    /// Monta a câmera a partir de um registro do `frames.json`.
    /// Devolve `nil` se o registro estiver malformado.
    public init?(record: KeyframeRecord) {
        guard record.transform.count == 16, record.intrinsics.count == 9,
              record.imageWidth > 0, record.imageHeight > 0 else {
            return nil
        }
        let k = record.intrinsics
        let intrinsics = simd_float3x3(columns: (SIMD3<Float>(k[0], k[1], k[2]),
                                                 SIMD3<Float>(k[3], k[4], k[5]),
                                                 SIMD3<Float>(k[6], k[7], k[8])))
        self.init(transform: RawMeshFile.transformFromArray(record.transform),
                  intrinsics: intrinsics,
                  imageWidth: record.imageWidth,
                  imageHeight: record.imageHeight)
    }

    /// Projeta um ponto do mundo. Devolve `nil` se o ponto estiver atrás da câmera
    /// ou cair fora da imagem.
    public func project(_ point: SIMD3<Float>) -> ProjectedPoint? {
        let pc = worldToCamera * SIMD4<Float>(point.x, point.y, point.z, 1)
        // A câmera olha para -Z: profundidade positiva significa "na frente".
        let depth = -pc.z
        if !(depth > 0) {
            return nil
        }
        let u = fx * pc.x / depth + cx
        let v = cy - fy * pc.y / depth
        if !(u >= 0 && u < width && v >= 0 && v < height) {
            return nil
        }
        return ProjectedPoint(u: u, v: v, depth: depth)
    }
}
